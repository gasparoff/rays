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

/// Ableton Link is always active. Auto/xdj adds the bundled Beat Link master follower;
/// midiClock follows MIDI beat clock from any MIDI input (off unless chosen).
public enum BeatSource: String, Codable, CaseIterable, Sendable {
    case auto, link, xdj, midiClock

    /// Sources that run the Pro DJ Link (Beat Link) listener.
    public var usesProDJLink: Bool { self == .auto || self == .xdj }
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

/// Atomic JSON persistence in Application Support/RAYS.
public struct ConfigStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Folder name inside Application Support.
    public static let directoryName = "RAYS"
    /// Folder name used before the project was called RAYS. Moved once by `resolveDirectory(in:)`.
    public static let legacyDirectoryName = "Light System"

    /// `Application Support/RAYS`, after moving an existing `Application Support/Light System` there.
    /// Resolved once per launch.
    public static let defaultDirectory: URL = {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return resolveDirectory(in: base)
    }()

    /// Returns `base/RAYS`. When only the legacy `base/Light System` folder exists, it is moved to
    /// `base/RAYS` and a symbolic link is left at the old path, so an older build still finds the same
    /// files. If the move fails the legacy folder is used as it is: saved data is never left behind.
    public static func resolveDirectory(in base: URL, fileManager: FileManager = .default) -> URL {
        let current = base.appendingPathComponent(directoryName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: current.path) { return current }
        // A link at the legacy path is the one left by an earlier migration, never data to move.
        let legacyIsLink = (try? fileManager.destinationOfSymbolicLink(atPath: legacy.path)) != nil
        var isDirectory: ObjCBool = false
        guard !legacyIsLink, fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return current }
        do {
            try fileManager.moveItem(at: legacy, to: current)
        } catch {
            return legacy
        }
        try? fileManager.createSymbolicLink(atPath: legacy.path, withDestinationPath: directoryName)
        return current
    }

    public var patchURL: URL { directory.appendingPathComponent("patch.json") }
    public var preferencesURL: URL { directory.appendingPathComponent("preferences.json") }
    public var profilesDirectory: URL { directory.appendingPathComponent("Profiles", isDirectory: true) }
    public var controllersDirectory: URL { directory.appendingPathComponent("Controllers", isDirectory: true) }
    public var midiURL: URL { directory.appendingPathComponent("midi.json") }

    /// False on a fresh machine: the app then shows the unconfirmed TRI 180 test preset without saving it.
    public var hasSavedPatch: Bool { FileManager.default.fileExists(atPath: patchURL.path) }

    public func loadMIDIMap() -> MIDIMap {
        var issue: String?
        return loadMIDIMap(issue: &issue)
    }

    /// Like `loadMIDIMap()`, but a `midi.json` that exists and cannot be decoded is first copied aside
    /// (see `preserveUnreadable(_:)`), so the next save cannot silently destroy the learned mappings.
    /// `issue` receives a user-facing message in that case.
    public func loadMIDIMap(issue: inout String?) -> MIDIMap {
        decodeKeepingUnreadable(MIDIMap.self, from: midiURL, issue: &issue) ?? MIDIMap()
    }

    public func saveMIDIMap(_ map: MIDIMap) throws { try write(map, to: midiURL) }

    public func loadPatch() throws -> Patch {
        guard FileManager.default.fileExists(atPath: patchURL.path) else { return .empty }
        return try JSONDecoder().decode(Patch.self, from: Data(contentsOf: patchURL))
    }

    public func savePatch(_ patch: Patch) throws { try write(patch, to: patchURL) }

    public func loadPreferences() -> Preferences {
        var issue: String?
        return loadPreferences(issue: &issue)
    }

    /// Like `loadPreferences()`, but an undecodable `preferences.json` is copied aside first and
    /// reported through `issue`.
    public func loadPreferences(issue: inout String?) -> Preferences {
        decodeKeepingUnreadable(Preferences.self, from: preferencesURL, issue: &issue) ?? Preferences()
    }

    public func savePreferences(_ prefs: Preferences) throws { try write(prefs, to: preferencesURL) }

    /// Decodes `url`. A missing file returns nil quietly; a file that exists but does not decode is
    /// preserved with `preserveUnreadable(_:)` and described in `issue`, then nil is returned.
    private func decodeKeepingUnreadable<T: Decodable>(_ type: T.Type, from url: URL, issue: inout String?) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let name = url.lastPathComponent
            if let copy = preserveUnreadable(url) {
                issue = String(
                    localized:
                        "\(String(describing: name)) could not be read. RAYS kept a copy as \(String(describing: copy.lastPathComponent)) and started with defaults."
                )
            } else {
                issue = String(localized: "\(String(describing: name)) could not be read and RAYS started with defaults.")
            }
            return nil
        }
    }

    /// Copies an unreadable file next to itself as `<name>.unreadable[-n].json` and returns the copy.
    /// An existing copy is never overwritten, so the first damaged version always survives.
    @discardableResult
    public func preserveUnreadable(_ url: URL) -> URL? {
        let base = url.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        for n in 0..<100 {
            let suffix = n == 0 ? "" : "-\(n)"
            let copy = directory.appendingPathComponent("\(base).unreadable\(suffix).json")
            if fm.fileExists(atPath: copy.path) { continue }
            return (try? fm.copyItem(at: url, to: copy)) != nil ? copy : nil
        }
        return nil
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
