import Foundation
import RaysCore

/// Performance levels that are not beat-source preferences: group masters and the accent level.
/// Stored separately in show.json so preferences.json keeps its existing schema.
public struct ShowSettings: Codable, Equatable, Sendable {
    /// Per-group intensity masters, 0…1 (ADR 0005). The classic groups are always present; a group
    /// without an entry plays at 1.
    public var masters: [RigGroupID: Double] = [.left: 1, .center: 1, .right: 1]
    /// Warm COB level of the momentary accent (blinder hit).
    public var accentLevel = 1.0
    /// Global COB brightness, independent of RGB and applied before master/role dimming.
    public var whiteLevel = 1.0

    /// The classic groups' masters, kept as views over `masters` (and as their own keys on disk).
    public var levelLeft: Double {
        get { level(group: .left) }
        set { masters[.left] = newValue }
    }
    public var levelCenter: Double {
        get { level(group: .center) }
        set { masters[.center] = newValue }
    }
    public var levelRight: Double {
        get { level(group: .right) }
        set { masters[.right] = newValue }
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShowSettings()
        func clean(_ v: Double?, _ fallback: Double) -> Double {
            guard let v, v.isFinite else { return fallback }
            return min(1, max(0, v))
        }
        func value(_ key: CodingKeys, _ fallback: Double) -> Double {
            clean(try? c.decodeIfPresent(Double.self, forKey: key), fallback)
        }
        // Old files carry the classic keys only; the `masters` map, when present, wins over them.
        masters[.left] = value(.levelLeft, d.levelLeft)
        masters[.center] = value(.levelCenter, d.levelCenter)
        masters[.right] = value(.levelRight, d.levelRight)
        if let saved = try? c.decodeIfPresent([String: Double].self, forKey: .masters) {
            for (id, v) in saved { masters[RigGroupID(id)] = clean(v, 1) }
        }
        accentLevel = value(.accentLevel, d.accentLevel)
        whiteLevel = value(.whiteLevel, d.whiteLevel)
    }

    /// Writes the keys every earlier version wrote, `levelLeft/Center/Right` included, so an older
    /// build still opens the file. `masters` is added only when it holds a group beyond the classic
    /// three, so a classic show is saved exactly as before.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(levelLeft, forKey: .levelLeft)
        try c.encode(levelCenter, forKey: .levelCenter)
        try c.encode(levelRight, forKey: .levelRight)
        if masters.keys.contains(where: { FixtureRole(groupID: $0) == nil }) {
            var map: [String: Double] = [:]
            for (id, v) in masters { map[id.rawValue] = v }
            try c.encode(map, forKey: .masters)
        }
        try c.encode(accentLevel, forKey: .accentLevel)
        try c.encode(whiteLevel, forKey: .whiteLevel)
    }

    private enum CodingKeys: String, CodingKey {
        case levelLeft, levelCenter, levelRight, masters, accentLevel, whiteLevel
    }

    /// Master of group `id`; 1 for a group without one.
    public func level(group id: RigGroupID) -> Double { masters[id] ?? 1 }

    /// Sets the master of group `id`, clamped to 0…1 (non-finite values become 1).
    public mutating func setLevel(group id: RigGroupID, _ v: Double) {
        masters[id] = v.isFinite ? min(1, max(0, v)) : 1
    }

    public func level(_ role: FixtureRole) -> Double { level(group: role.groupID) }

    public mutating func setLevel(_ role: FixtureRole, _ v: Double) { setLevel(group: role.groupID, v) }
}

extension ConfigStore {
    public var showURL: URL { directory.appendingPathComponent("show.json") }

    public func loadShowSettings() -> ShowSettings {
        guard let data = try? Data(contentsOf: showURL) else { return ShowSettings() }
        return (try? JSONDecoder().decode(ShowSettings.self, from: data)) ?? ShowSettings()
    }

    public func saveShowSettings(_ show: ShowSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(show).write(to: showURL, options: .atomic)
    }
}
