import Foundation

// Scene banks ("categories" in the UI): named sets of scenes for the six performance slots.
//
// Every pad of every bank is described by the same `CustomScene` model. House and Club are built in;
// the user can add banks of their own. A user bank starts from the factory scenes of a built-in bank
// (its `origin`) and keeps its own edits of each pad, so "Restore original" always has somewhere to go.

/// Identifier of a scene bank. Persisted as a plain string (`"house"`, `"club"`, `"user-…"`) in the
/// scenes file and in the preferences: raw values never change.
public struct SceneBank: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public static let maxRawLength = 64

    public let rawValue: String

    /// nil for an empty or malformed id: lowercase ASCII letters, digits and `-` only.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= Self.maxRawLength,
            rawValue.unicodeScalars.allSatisfy({ (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "-" })
        else { return nil }
        self.rawValue = rawValue
    }

    private init(trusted rawValue: String) { self.rawValue = rawValue }

    public static let house = SceneBank(trusted: "house")
    public static let club = SceneBank(trusted: "club")
    /// The banks that ship with RAYS, in on-screen order.
    public static let builtIn: [SceneBank] = [.house, .club]

    /// A new identifier for a user bank.
    public static func user(_ id: UUID = UUID()) -> SceneBank { SceneBank(trusted: "user-" + id.uuidString.lowercased()) }

    public var id: String { rawValue }
    public var isBuiltIn: Bool { Self.builtIn.contains(self) }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let bank = SceneBank(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid scene bank id"))
        }
        self = bank
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// A bank as the user sees it: name and the built-in bank its pads start from.
public struct SceneBankInfo: Codable, Equatable, Identifiable, Sendable {
    public static let maxNameLength = 24
    /// User banks a library keeps at most.
    public static let maxUserBanks = 16

    public var id: SceneBank
    public var name: String
    /// Built-in bank whose factory scenes fill the pads until they are edited.
    public var origin: SceneBank

    public init(id: SceneBank, name: String, origin: SceneBank) {
        self.id = id
        self.name = name
        self.origin = origin
    }

    public static let house = SceneBankInfo(id: .house, name: "House", origin: .house)
    public static let club = SceneBankInfo(id: .club, name: "Club 130–138", origin: .club)
    public static let builtIn: [SceneBankInfo] = [.house, .club]

    /// Trimmed single-line name, at most `maxNameLength` characters; `fallback` when nothing is left.
    public static func cleanName(_ raw: String, fallback: String = String(localized: "My bank")) -> String {
        let scalars = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let joined = String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let short = String(joined.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? fallback : short
    }

    /// Clean name; an origin that is not built in falls back to House.
    public var sanitized: SceneBankInfo {
        var s = self
        s.name = SceneBankInfo.cleanName(name)
        if !s.origin.isBuiltIn { s.origin = .house }
        return s
    }

    // Tolerant decoding: only the id is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SceneBank.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        origin = (try? c.decodeIfPresent(SceneBank.self, forKey: .origin)) ?? .house
        self = sanitized
    }

    private enum CodingKeys: String, CodingKey { case id, name, origin }
}

// MARK: - Factory scenes

/// The six House scenes as scene models: the built-in choreography as written (`program` nil), its own
/// palette and stable ids. Played untouched, a House pad behaves as it always has: it keeps the live
/// Energy, speed and group levels instead of setting its own.
public enum HouseSceneBank {
    /// Built once: stable ids, identical on every lookup and every launch.
    public static let scenes: [CustomScene] = SceneID.allCases.enumerated().map { make($1, number: $0 + 1) }

    public static func scene(for slot: SceneID) -> CustomScene {
        scenes[SceneID.allCases.firstIndex(of: slot) ?? 0]
    }

    private static func make(_ slot: SceneID, number: Int) -> CustomScene {
        CustomScene(
            id: UUID(uuidString: String(format: "40053e00-0000-4000-8000-%012d", number))!,
            name: slot.title, presetSlot: slot, presetBank: .house, base: slot
        ).sanitized
    }
}

/// Factory content of every bank, built-in or user.
public enum FactoryScenes {
    /// The pad's original scene in `bank`. A user bank plays its origin's scenes under ids of its own,
    /// so its pads never share an identity with the bank they came from.
    public static func scene(for slot: SceneID, in bank: SceneBankInfo) -> CustomScene {
        var scene = bank.origin == .club ? ClubSceneBank.scene(for: slot) : HouseSceneBank.scene(for: slot)
        guard bank.id != bank.origin else { return scene }
        scene.id = derivedID(bank.id, slot)
        scene.presetBank = bank.id
        return scene
    }

    /// Short card line of a factory pad.
    public static func subtitle(for slot: SceneID, in bank: SceneBankInfo) -> String {
        bank.origin == .club ? ClubSceneBank.subtitle(for: slot) : slot.subtitle
    }

    /// A factory scene of any of `banks` by id.
    public static func scene(id: UUID, banks: [SceneBankInfo]) -> CustomScene? {
        for bank in banks {
            for slot in SceneID.allCases {
                let candidate = scene(for: slot, in: bank)
                if candidate.id == id { return candidate }
            }
        }
        return nil
    }

    /// Stable UUID (version 8, RFC 9562) from the bank id and the slot: the same on every launch.
    static func derivedID(_ bank: SceneBank, _ slot: SceneID) -> UUID {
        let bytes = Array("rays.bank/\(bank.rawValue)/\(slot.rawValue)".utf8)
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            return h
        }
        var out = [UInt8](repeating: 0, count: 16)
        for (k, word) in [fnv(0xcbf2_9ce4_8422_2325), fnv(0x84222325_cbf29ce4)].enumerated() {
            for i in 0..<8 { out[k * 8 + i] = UInt8(truncatingIfNeeded: word >> (8 * UInt64(i))) }
        }
        out[6] = (out[6] & 0x0f) | 0x80
        out[8] = (out[8] & 0x3f) | 0x80
        return UUID(
            uuid: (
                out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7],
                out[8], out[9], out[10], out[11], out[12], out[13], out[14], out[15]
            ))
    }
}

// MARK: - Library

/// Everything `custom-scenes.json` holds: personal scenes, pad edits of every bank and the user banks.
/// Pure value type: the app store and the tests share these rules.
public struct SceneLibrary: Equatable, Sendable {
    public var scenes: [CustomScene]
    /// User banks only, in on-screen order; the built-in banks are always present before them.
    public var banks: [SceneBankInfo]

    public init(scenes: [CustomScene] = [], banks: [SceneBankInfo] = []) {
        self.scenes = scenes
        self.banks = SceneLibrary.cleanBanks(banks)
    }

    /// Built-in banks first, then the user's.
    public var allBanks: [SceneBankInfo] { SceneBankInfo.builtIn + banks }

    public func bank(_ id: SceneBank) -> SceneBankInfo? { allBanks.first { $0.id == id } }

    public var canAddBank: Bool { banks.count < SceneBankInfo.maxUserBanks }

    /// The user's edit of a pad in `bank`, if any.
    public func preset(_ slot: SceneID, bank: SceneBank) -> CustomScene? {
        scenes.first { $0.presetSlot == slot && $0.presetBank == bank }
    }

    /// Adds a bank whose pads start from `origin`'s factory scenes. nil when the limit is reached.
    @discardableResult
    public mutating func addBank(name: String, origin: SceneBank) -> SceneBankInfo? {
        guard canAddBank else { return nil }
        let info = SceneBankInfo(id: .user(), name: name, origin: origin.isBuiltIn ? origin : .house).sanitized
        banks.append(info)
        return info
    }

    /// Built-in banks keep their names.
    public mutating func renameBank(_ id: SceneBank, to name: String) {
        guard let i = banks.firstIndex(where: { $0.id == id }) else { return }
        banks[i].name = SceneBankInfo.cleanName(name, fallback: banks[i].name)
    }

    /// Removes a user bank and its pad edits. Built-in banks cannot be removed.
    public mutating func deleteBank(_ id: SceneBank) {
        guard banks.contains(where: { $0.id == id }) else { return }
        banks.removeAll { $0.id == id }
        scenes.removeAll { $0.presetSlot != nil && $0.presetBank == id }
    }

    /// Sanitized user banks: no built-in ids, no duplicates, at most `maxUserBanks`.
    static func cleanBanks(_ raw: [SceneBankInfo]) -> [SceneBankInfo] {
        var seen = Set(SceneBank.builtIn)
        return Array(raw.map(\.sanitized).filter { seen.insert($0.id).inserted }.prefix(SceneBankInfo.maxUserBanks))
    }
}
