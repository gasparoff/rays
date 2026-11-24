import Foundation
import RaysCore

// Faders of the Live performance panel (ADR 0005, step 8): generated from the rig, then arranged by the
// user. Pure values: the app builds `LiveFaderSetup` when the patch changes and saves `LiveFaderLayout`
// as JSON in UserDefaults, like `LiveLayout`.

/// One fader of the performance panel.
public enum LiveFader: Hashable, Sendable, Identifiable {
    /// Master brightness (preferences).
    case master
    /// Global COB/warm-white level (`ShowSettings.whiteLevel`).
    case warmLight
    /// Energy (preferences).
    case energy
    /// Master of one rig group (`ShowSettings.masters`).
    case group(RigGroupID)

    /// Stored in the saved layout: never change these strings.
    public var key: String {
        switch self {
        case .master: return "master"
        case .warmLight: return "warmLight"
        case .energy: return "energy"
        case .group(let id): return "group:" + id.rawValue
        }
    }

    public init?(key: String) {
        switch key {
        case "master": self = .master
        case "warmLight": self = .warmLight
        case "energy": self = .energy
        default:
            guard key.hasPrefix("group:"), key.count > 6 else { return nil }
            self = .group(RigGroupID(String(key.dropFirst(6))))
        }
    }

    public var id: String { key }

    /// Master brightness stays on screen: without it nothing dims the whole rig.
    public var canHide: Bool { self != .master }
}

/// The faders a rig offers, in their default order: master brightness, warm light (only when some
/// light has a white/COB emitter), energy, then one master per group in layout order.
public struct LiveFaderSetup: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        public var id: RigGroupID
        public var name: String
    }

    public let hasWarmLight: Bool
    public let groups: [Group]

    public init(hasWarmLight: Bool, groups: [Group]) {
        self.hasWarmLight = hasWarmLight
        self.groups = groups
    }

    /// From the patch: its layout groups (as the engine renders them, `PatchRig`) and its profiles.
    /// An empty patch previews the classic rig, which has warm light.
    public init(patch: Patch, library: ProfileLibrary) {
        let rig = PatchRig(patch: patch, library: library)
        let lib = patch.library(base: library)
        hasWarmLight =
            patch.fixtures.isEmpty || patch.fixtures.contains { (lib.profile(id: $0.profileID)?.cobCount ?? 0) > 0 }
        groups = rig.layout.groups.map { group in
            let trimmed = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = FixtureRole(groupID: group.id)?.label ?? group.id.rawValue
            return Group(id: group.id, name: trimmed.isEmpty ? fallback : trimmed)
        }
    }

    /// The classic three-position rig.
    public static let classic = LiveFaderSetup(patch: .empty, library: ProfileLibrary())

    public var available: [LiveFader] {
        [.master] + (hasWarmLight ? [.warmLight] : []) + [.energy] + groups.map { .group($0.id) }
    }

    /// Display name of a group fader's group, nil when the rig has no such group.
    public func name(of id: RigGroupID) -> String? { groups.first { $0.id == id }?.name }
}

/// The user's arrangement of the faders: an order and the hidden ones, by key.
///
/// Keys of faders the current rig lacks are kept in place, so switching between two setups keeps both
/// arrangements. A fader the saved order doesn't name (a new group) goes right after the fader before it
/// in the default order. The automatic layout (nothing saved) shows every fader in the default order.
public struct LiveFaderLayout: Codable, Equatable, Sendable {
    public private(set) var order: [String]
    public private(set) var hidden: Set<String>

    public init(order: [String] = [], hidden: Set<String> = []) {
        var seen = Set<String>()
        self.order = order.filter { LiveFader(key: $0) != nil && seen.insert($0).inserted }
        self.hidden = hidden.filter { LiveFader(key: $0)?.canHide ?? false }
    }

    public static let automatic = LiveFaderLayout()

    public var isAutomatic: Bool { order.isEmpty && hidden.isEmpty }

    /// Every fader of `setup`, hidden ones included, in the user's order.
    public func all(in setup: LiveFaderSetup) -> [LiveFader] {
        let keys = Set(setup.available.map(\.key))
        return merged(in: setup).filter { keys.contains($0) }.compactMap(LiveFader.init(key:))
    }

    /// The faders shown on the panel, in order.
    public func visible(in setup: LiveFaderSetup) -> [LiveFader] {
        all(in: setup).filter { !isHidden($0) }
    }

    /// The saved order with every fader of `setup` it doesn't name inserted right after the fader
    /// before it in the default order (so the automatic layout is the default order, and a new group
    /// lands next to the group before it). Keys of absent faders keep their place.
    private func merged(in setup: LiveFaderSetup) -> [String] {
        var result = order
        let available = setup.available
        for (i, fader) in available.enumerated() where !result.contains(fader.key) {
            let anchor = available[..<i].reversed().lazy.compactMap { result.firstIndex(of: $0.key) }.first
            result.insert(fader.key, at: anchor.map { $0 + 1 } ?? 0)
        }
        return result
    }

    public func isHidden(_ fader: LiveFader) -> Bool { fader.canHide && hidden.contains(fader.key) }

    public mutating func setHidden(_ fader: LiveFader, _ hide: Bool) {
        guard fader.canHide else { return }
        if hide { hidden.insert(fader.key) } else { hidden.remove(fader.key) }
    }

    public func canMove(_ fader: LiveFader, by offset: Int, in setup: LiveFaderSetup) -> Bool {
        let list = all(in: setup)
        guard let i = list.firstIndex(of: fader) else { return false }
        return list.indices.contains(i + offset)
    }

    /// Moves `fader` `offset` places among `setup`'s faders. Faders of other setups keep their place.
    public mutating func move(_ fader: LiveFader, by offset: Int, in setup: LiveFaderSetup) {
        let list = all(in: setup)
        guard offset != 0, let i = list.firstIndex(of: fader), list.indices.contains(i + offset) else { return }
        let target = list[i + offset].key
        var keys = merged(in: setup)
        keys.removeAll { $0 == fader.key }
        guard let t = keys.firstIndex(of: target) else { return }
        keys.insert(fader.key, at: offset < 0 ? t : t + 1)
        order = keys
    }

    /// Columns of the fader grid for `count` faders: up to six in rows of three (the classic panel is
    /// two rows of three), four as two pairs, more in two rows of at most five.
    public static func columns(for count: Int) -> Int {
        switch count {
        case ...3: return max(1, count)
        case 4: return 2
        case 5...6: return 3
        default: return min(5, (count + 1) / 2)
        }
    }

    // MARK: Saving

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let order = (try? c.decodeIfPresent([String].self, forKey: .order)) ?? nil
        let hidden = (try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? nil
        self.init(order: order ?? [], hidden: Set(hidden ?? []))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order, forKey: .order)
        try c.encode(hidden.sorted(), forKey: .hidden)
    }

    private enum CodingKeys: String, CodingKey { case order, hidden }

    /// Reads a saved layout; anything unreadable is the automatic layout.
    public static func decodeSaved(_ data: Data?) -> LiveFaderLayout {
        guard let data, let layout = try? JSONDecoder().decode(LiveFaderLayout.self, from: data) else { return .automatic }
        return layout
    }
}
