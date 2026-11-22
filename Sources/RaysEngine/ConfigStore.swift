import Foundation
import RaysOutput
import RaysCore
import RaysControl

/// Which output driver the engine uses and each driver's settings. Old preferences
/// (no `output` key) keep Art-Net.
public struct OutputSettings: Codable, Equatable, Sendable {
    public var driverID = OutputDriverRegistry.defaultDriverID
    public var sacn = SACNDriver.Configuration()
    public var dmxUSBPro = DMXUSBProDriver.Configuration()

    public init() {}

    enum CodingKeys: String, CodingKey { case driverID, sacn, dmxUSBPro }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OutputSettings()
        driverID = (try? c.decodeIfPresent(String.self, forKey: .driverID)) ?? d.driverID
        sacn = (try? c.decodeIfPresent(SACNDriver.Configuration.self, forKey: .sacn)) ?? d.sacn
        dmxUSBPro = (try? c.decodeIfPresent(DMXUSBProDriver.Configuration.self, forKey: .dmxUSBPro)) ?? d.dmxUSBPro
    }

    /// Registry with every driver the app offers, configured from these settings.
    public var registry: OutputDriverRegistry {
        var r = OutputDriverRegistry.builtIn
        let sacn = self.sacn, usb = self.dmxUSBPro
        r.register(.init(id: SACNDriver.driverID, name: "sACN (E1.31)") { SACNDriver(transport: $0, interfaces: $1, configuration: sacn) })
        r.register(.init(id: DMXUSBProDriver.driverID, name: "ENTTEC DMX USB Pro") { _, _ in DMXUSBProDriver(configuration: usb) })
        return r
    }
}

/// Ableton Link is always active. Auto/xdj adds the bundled Beat Link master follower.
public enum BeatSource: String, Codable, CaseIterable, Sendable {
    case auto, link, xdj
}

/// User preferences. Persist the user's output intent, never transient connection/diagnostic state.
public struct Preferences: Codable, Equatable, Sendable {
    public var scene: SceneID = .ambra
    /// Fresh installs start low; existing saved values are kept.
    public var master: Double = 0.25
    public var energy: Double = 0.5
    public var subdivision: Subdivision = .one
    public var preferredNodeIdentity: String?
    public var manualIP: String?
    public var startStopSync = false
    public var beatSource: BeatSource = .auto
    public var xdjDeck = 0
    /// Restore output after discovery on launch. Old preferences remain preview-only until enabled.
    public var outputEnabled = false
    public var blackout = false
    public var output = OutputSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        scene = (try? c.decodeIfPresent(SceneID.self, forKey: .scene)) ?? d.scene
        master = (try? c.decodeIfPresent(Double.self, forKey: .master)) ?? d.master
        energy = (try? c.decodeIfPresent(Double.self, forKey: .energy)) ?? d.energy
        subdivision = (try? c.decodeIfPresent(Subdivision.self, forKey: .subdivision)) ?? d.subdivision
        preferredNodeIdentity = try? c.decodeIfPresent(String.self, forKey: .preferredNodeIdentity)
        manualIP = try? c.decodeIfPresent(String.self, forKey: .manualIP)
        startStopSync = (try? c.decodeIfPresent(Bool.self, forKey: .startStopSync)) ?? d.startStopSync
        beatSource = (try? c.decodeIfPresent(BeatSource.self, forKey: .beatSource)) ?? d.beatSource
        let deck = (try? c.decodeIfPresent(Int.self, forKey: .xdjDeck)) ?? d.xdjDeck
        xdjDeck = (0...4).contains(deck) ? deck : d.xdjDeck
        outputEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .outputEnabled)) ?? d.outputEnabled
        blackout = (try? c.decodeIfPresent(Bool.self, forKey: .blackout)) ?? d.blackout
        output = (try? c.decodeIfPresent(OutputSettings.self, forKey: .output)) ?? d.output
    }
}

/// Atomic JSON persistence in Application Support/Light System.
public struct ConfigStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Light System", isDirectory: true)
    }

    public var patchURL: URL { directory.appendingPathComponent("patch.json") }
    public var preferencesURL: URL { directory.appendingPathComponent("preferences.json") }
    public var profilesDirectory: URL { directory.appendingPathComponent("Profiles", isDirectory: true) }
    public var controllersDirectory: URL { directory.appendingPathComponent("Controllers", isDirectory: true) }
    public var midiURL: URL { directory.appendingPathComponent("midi.json") }

    /// False on a fresh machine: the app then shows the unconfirmed TRI 180 test preset without saving it.
    public var hasSavedPatch: Bool { FileManager.default.fileExists(atPath: patchURL.path) }

    public func loadMIDIMap() -> MIDIMap {
        guard let data = try? Data(contentsOf: midiURL),
              let map = try? JSONDecoder().decode(MIDIMap.self, from: data) else { return MIDIMap() }
        return map
    }

    public func saveMIDIMap(_ map: MIDIMap) throws { try write(map, to: midiURL) }

    public func loadPatch() throws -> Patch {
        guard FileManager.default.fileExists(atPath: patchURL.path) else { return .empty }
        return try JSONDecoder().decode(Patch.self, from: Data(contentsOf: patchURL))
    }

    public func savePatch(_ patch: Patch) throws { try write(patch, to: patchURL) }

    public func loadPreferences() -> Preferences {
        guard let data = try? Data(contentsOf: preferencesURL),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    public func savePreferences(_ prefs: Preferences) throws { try write(prefs, to: preferencesURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
