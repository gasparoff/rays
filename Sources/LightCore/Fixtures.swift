import Foundation

public enum ChannelKind: String, Codable, CaseIterable, Sendable {
    case dimmer, red, green, blue, white, blinder, amber, constant, ignore

    public var label: String {
        switch self {
        case .dimmer: return "Dimmer"
        case .red: return "Rosso"
        case .green: return "Verde"
        case .blue: return "Blu"
        case .white: return "Bianco"
        case .blinder: return "Blinder bianco indipendente"
        case .amber: return "Ambra"
        case .constant: return "Valore fisso"
        case .ignore: return "Non usato (0)"
        }
    }
}

public struct ChannelDefinition: Codable, Hashable, Sendable {
    public var kind: ChannelKind
    /// Only used by `.constant` (e.g. shutter open). Everything else is computed.
    public var value: UInt8
    /// Optional explicit pixel/COB index. When nil (the default, omitted from JSON so existing
    /// fingerprints stay identical) the index is the channel's occurrence order for its kind:
    /// the 2nd red channel belongs to RGB segment 1, the 3rd blinder channel is COB 2.
    public var segment: Int?

    public init(_ kind: ChannelKind, value: UInt8 = 0, segment: Int? = nil) {
        self.kind = kind
        self.value = value
        self.segment = segment
    }
}

/// Where a fixture stands in the choreography. Not part of the confirmation fingerprint:
/// changing a role never changes which DMX channel means what.
public enum FixtureRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, center, right
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .left: return "Sinistra"
        case .center: return "Centro"
        case .right: return "Destra"
        }
    }
}

/// Extensible fixture description. Verified manufacturer profiles can be added as JSON files
/// in Application Support/Light System/Profiles or via `ProfileLibrary.builtIn`.
public struct FixtureProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var manufacturer: String
    public var mode: String
    public var isGeneric: Bool
    public var isVerified: Bool
    public var notes: String
    public var channels: [ChannelDefinition]

    public init(id: String, name: String, manufacturer: String = "Generico", mode: String = "", isGeneric: Bool = true,
                isVerified: Bool = false, notes: String = "", channels: [ChannelDefinition]) {
        self.id = id; self.name = name; self.manufacturer = manufacturer; self.mode = mode
        self.isGeneric = isGeneric; self.isVerified = isVerified; self.notes = notes; self.channels = channels
    }

    public var footprint: Int { channels.count }

    public var problems: [String] {
        var p: [String] = []
        if channels.isEmpty { p.append("Il profilo «\(name)» non ha canali.") }
        if channels.count > 512 { p.append("Il profilo «\(name)» supera 512 canali.") }
        let light: Set<ChannelKind> = [.dimmer, .red, .green, .blue, .white, .blinder, .amber]
        if !channels.contains(where: { light.contains($0.kind) }) { p.append("Il profilo «\(name)» non ha canali luce.") }
        return p
    }

    public var displayName: String { mode.isEmpty ? name : "\(name) · \(mode)" }

    /// Segment index of every channel (nil for channels that are not RGB or white/COB).
    public var channelSegments: [Int?] {
        var counters: [ChannelKind: Int] = [:]
        return channels.map { ch in
            let group: ChannelKind
            switch ch.kind {
            case .red, .green, .blue, .amber: group = ch.kind
            case .white, .blinder: group = .blinder
            default: return nil
            }
            let implicit = counters[group, default: 0]
            counters[group] = implicit + 1
            return min(63, max(0, ch.segment ?? implicit))
        }
    }

    /// Independent RGB pixel groups (TRI 380 25CH: 6; TRI 180 8CH: 1; none: 0).
    public var rgbSegmentCount: Int {
        let colorKinds: Set<ChannelKind> = [.red, .green, .blue, .amber]
        return zip(channels, channelSegments).filter { colorKinds.contains($0.0.kind) }
            .compactMap(\.1).max().map { $0 + 1 } ?? 0
    }

    /// Independent white/COB emitters (TRI 380 25CH: 3; TRI 180 8CH: 1; none: 0).
    public var cobCount: Int {
        zip(channels, channelSegments).filter { $0.0.kind == .white || $0.0.kind == .blinder }
            .compactMap(\.1).max().map { $0 + 1 } ?? 0
    }
}

public struct ProfileLibrary: Sendable {
    public static let builtIn: [FixtureProfile] = [
        FixtureProfile(id: "generic.rgb3", name: "Generico RGB", mode: "3 canali",
                       notes: "R, G, B", channels: [.init(.red), .init(.green), .init(.blue)]),
        FixtureProfile(id: "generic.rgbw4", name: "Generico RGBW", mode: "4 canali",
                       notes: "R, G, B, W", channels: [.init(.red), .init(.green), .init(.blue), .init(.white)]),
        FixtureProfile(id: "generic.drgb4", name: "Generico Dimmer+RGB", mode: "4 canali",
                       notes: "Dimmer, R, G, B", channels: [.init(.dimmer), .init(.red), .init(.green), .init(.blue)]),
        FixtureProfile(id: "generic.drgbw5", name: "Generico Dimmer+RGBW", mode: "5 canali",
                       notes: "Dimmer, R, G, B, W",
                       channels: [.init(.dimmer), .init(.red), .init(.green), .init(.blue), .init(.white)]),
    ] + VarytecRig.profiles

    public private(set) var profiles: [FixtureProfile]

    public init(extra: [FixtureProfile] = []) {
        var seen = Set<String>()
        profiles = (Self.builtIn + extra).filter { seen.insert($0.id).inserted }
    }

    public func profile(id: String) -> FixtureProfile? { profiles.first { $0.id == id } }

    public func adding(_ more: [FixtureProfile]) -> ProfileLibrary { ProfileLibrary(extra: Array(profiles.dropFirst(Self.builtIn.count)) + more) }

    /// Loads every `*.json` FixtureProfile in `directory`; invalid files are reported, not fatal.
    public static func loadProfiles(in directory: URL) -> (profiles: [FixtureProfile], errors: [String]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var result: [FixtureProfile] = []
        var errors: [String] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: file)
                if let list = try? JSONDecoder().decode([FixtureProfile].self, from: data) { result += list }
                else { result.append(try JSONDecoder().decode(FixtureProfile.self, from: data)) }
            } catch {
                errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (result, errors)
    }
}

// MARK: - Patch

public struct PatchedFixture: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var profileID: String
    /// Zero-based Art-Net Port-Address. The tested ODE sends wire universe 1 on both physical outputs.
    public var universe: Int
    /// DMX start address 1...512.
    public var address: Int
    /// Stage position for the choreography; nil = automatic (see `Patch.roles`).
    public var role: FixtureRole?

    public init(id: UUID = UUID(), label: String, profileID: String, universe: Int, address: Int, role: FixtureRole? = nil) {
        self.id = id; self.label = label; self.profileID = profileID; self.universe = universe; self.address = address
        self.role = role
    }
}

public struct PatchIssue: Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

public struct Patch: Codable, Equatable, Sendable {
    public var fixtures: [PatchedFixture]
    public var customProfiles: [FixtureProfile]
    /// Fingerprint of the patch the user confirmed on the real lights. Any edit invalidates it.
    public var confirmedFingerprint: String?

    public init(fixtures: [PatchedFixture] = [], customProfiles: [FixtureProfile] = [], confirmedFingerprint: String? = nil) {
        self.fixtures = fixtures; self.customProfiles = customProfiles; self.confirmedFingerprint = confirmedFingerprint
    }

    public static let empty = Patch()

    public func library(base: ProfileLibrary) -> ProfileLibrary { base.adding(customProfiles) }

    /// Stable FNV-1a hash of fixtures + the profiles they use (channel maps included).
    public func fingerprint(library base: ProfileLibrary) -> String {
        let lib = library(base: base)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Same keys as PatchedFixture minus `role`, so fingerprints confirmed before roles existed stay valid.
        struct CanonFixture: Encodable { var id: UUID; var label: String; var profileID: String; var universe: Int; var address: Int }
        struct Canon: Encodable { var fixtures: [CanonFixture]; var profiles: [FixtureProfile?] }
        let canon = Canon(fixtures: fixtures.map { CanonFixture(id: $0.id, label: $0.label, profileID: $0.profileID,
                                                                universe: $0.universe, address: $0.address) },
                          profiles: fixtures.map { lib.profile(id: $0.profileID) })
        let data = (try? encoder.encode(canon)) ?? Data()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }

    public func isConfirmed(library: ProfileLibrary) -> Bool {
        confirmedFingerprint != nil && confirmedFingerprint == fingerprint(library: library)
    }

    public mutating func setConfirmed(_ confirmed: Bool, library: ProfileLibrary) {
        confirmedFingerprint = confirmed ? fingerprint(library: library) : nil
    }

    /// Choreography role of every fixture. Explicit roles win. Otherwise a fixture with six or
    /// more RGB segments (TRI 380) is the centre, a lone fixture is the left side light, and the
    /// rest follow their position in the list (first third left, middle centre, last third right).
    public func roles(library base: ProfileLibrary) -> [FixtureRole] {
        let lib = library(base: base)
        let n = fixtures.count
        return fixtures.enumerated().map { i, f in
            if let role = f.role { return role }
            if let p = lib.profile(id: f.profileID), p.rgbSegmentCount >= 6 { return .center }
            guard n > 1 else { return .left }
            let x = Double(i) / Double(n - 1)
            return x < 0.34 ? .left : (x > 0.66 ? .right : .center)
        }
    }

    public var universes: [PortAddress] {
        Array(Set(fixtures.compactMap { PortAddress($0.universe) })).sorted()
    }

    public func validate(library base: ProfileLibrary, allowedUniverses: ClosedRange<Int> = 0...1) -> [PatchIssue] {
        let lib = library(base: base)
        var issues: [PatchIssue] = []
        var ranges: [(fixture: PatchedFixture, range: ClosedRange<Int>)] = []
        for profile in customProfiles { issues += profile.problems.map(PatchIssue.init) }
        for f in fixtures {
            guard let profile = lib.profile(id: f.profileID) else {
                issues.append(PatchIssue(message: "\(f.label): profilo sconosciuto «\(f.profileID)». Nessun dato verrà inviato."))
                continue
            }
            if !allowedUniverses.contains(f.universe) {
                issues.append(PatchIssue(message: "\(f.label): universo \(f.universe) non disponibile (ammessi \(allowedUniverses.lowerBound)–\(allowedUniverses.upperBound))."))
            }
            guard (1...512).contains(f.address) else {
                issues.append(PatchIssue(message: "\(f.label): indirizzo \(f.address) fuori da 1–512."))
                continue
            }
            let end = f.address + profile.footprint - 1
            if profile.footprint < 1 || end > 512 {
                issues.append(PatchIssue(message: "\(f.label): canali \(f.address)–\(end) oltre il limite di 512."))
                continue
            }
            let range = f.address...end
            for other in ranges where other.fixture.universe == f.universe && other.range.overlaps(range) {
                issues.append(PatchIssue(message: "\(f.label) (\(range.lowerBound)–\(range.upperBound)) si sovrappone a \(other.fixture.label) (\(other.range.lowerBound)–\(other.range.upperBound)) nell'universo \(f.universe)."))
            }
            ranges.append((f, range))
        }
        return issues
    }

    /// Adds `count` fixtures at consecutive addresses starting at `startAddress`.
    public mutating func addGroup(profile: FixtureProfile, count: Int, startAddress: Int, universe: Int) {
        let base = fixtures.count
        for i in 0..<max(0, count) {
            fixtures.append(PatchedFixture(label: "Luce \(base + i + 1)", profileID: profile.id, universe: universe,
                                           address: startAddress + i * profile.footprint))
        }
    }
}
