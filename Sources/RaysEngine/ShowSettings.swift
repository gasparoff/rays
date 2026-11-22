import Foundation
import RaysCore

/// Performance levels that are not beat-source preferences: role faders and the accent level.
/// Stored separately in show.json so preferences.json keeps its existing schema.
public struct ShowSettings: Codable, Equatable, Sendable {
    public var levelLeft = 1.0
    public var levelCenter = 1.0
    public var levelRight = 1.0
    /// Warm COB level of the momentary accent (blinder hit).
    public var accentLevel = 1.0
    /// Global COB brightness, independent of RGB and applied before master/role dimming.
    public var whiteLevel = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShowSettings()
        func value(_ key: CodingKeys, _ fallback: Double) -> Double {
            let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
            return v.isFinite ? min(1, max(0, v)) : fallback
        }
        levelLeft = value(.levelLeft, d.levelLeft)
        levelCenter = value(.levelCenter, d.levelCenter)
        levelRight = value(.levelRight, d.levelRight)
        accentLevel = value(.accentLevel, d.accentLevel)
        whiteLevel = value(.whiteLevel, d.whiteLevel)
    }

    public func level(_ role: FixtureRole) -> Double {
        switch role {
        case .left: return levelLeft
        case .center: return levelCenter
        case .right: return levelRight
        }
    }

    public mutating func setLevel(_ role: FixtureRole, _ v: Double) {
        let v = v.isFinite ? min(1, max(0, v)) : 1
        switch role {
        case .left: levelLeft = v
        case .center: levelCenter = v
        case .right: levelRight = v
        }
    }
}

extension ConfigStore {
    public var showURL: URL { directory.appendingPathComponent("show.json") }

    public func loadShowSettings() -> ShowSettings {
        guard let data = try? Data(contentsOf: showURL),
              let show = try? JSONDecoder().decode(ShowSettings.self, from: data) else { return ShowSettings() }
        return show
    }

    public func saveShowSettings(_ show: ShowSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(show).write(to: showURL, options: .atomic)
    }
}
