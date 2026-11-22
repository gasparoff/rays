import Foundation
import RaysOutput
import RaysTempo
import RaysCore

/// Whether DMX can be sent, or the first reason why not.
public enum OutputReadiness: Equatable, Sendable {
    case ready
    case noPatch
    case invalidPatch(String)
    case notConfirmed
    case socketUnavailable(String)
    case noDevice
    case noMatchingUniverse

    public var message: String {
        switch self {
        case .ready: return "Pronto"
        case .noPatch: return "Configura le luci (patch vuoto)"
        case .invalidPatch(let m): return "Patch non valido: \(m)"
        case .notConfirmed: return "Conferma modello, modalità e indirizzi nella configurazione"
        case .socketUnavailable(let m): return m
        case .noDevice: return "Nessun ENTTEC selezionato"
        case .noMatchingUniverse: return "Il nodo non ha in uscita gli universi del patch"
        }
    }
}

/// One fixture as the preview shows it, decoded from the very bytes composed for DMX.
public struct FixtureVisual: Equatable, Identifiable, Sendable {
    /// Whether this fixture is live, preview-only or off.
    public enum Status: Equatable, Sendable {
        /// Patched and DMX is being sent.
        case live
        /// Patched, output off (preview of what would be sent).
        case off
        /// Not in the patch: drawn from a never-transmitted shadow buffer to show the full rig.
        case previewOnly
    }

    public var id: String
    public var label: String
    public var profileID: String?
    public var role: FixtureRole
    public var universe: Int
    public var address: Int
    /// Per RGB pixel group, fixture dimmer and master already applied (TRI 380 25CH: 6, TRI 180 8CH: 1).
    public var rgb: [LightColor]
    /// Per warm COB (TRI 380 25CH: 3, TRI 180: 1; empty if the profile has no white channel).
    public var cob: [Double]
    public var status: Status

    public init(id: String, label: String, profileID: String?, role: FixtureRole, universe: Int, address: Int,
                rgb: [LightColor], cob: [Double], status: Status) {
        self.id = id; self.label = label; self.profileID = profileID; self.role = role
        self.universe = universe; self.address = address; self.rgb = rgb; self.cob = cob; self.status = status
    }

    /// Average RGB (convenience for simple views and tests).
    public var r: Double { rgb.isEmpty ? 0 : rgb.map(\.r).reduce(0, +) / Double(rgb.count) }
    public var g: Double { rgb.isEmpty ? 0 : rgb.map(\.g).reduce(0, +) / Double(rgb.count) }
    public var b: Double { rgb.isEmpty ? 0 : rgb.map(\.b).reduce(0, +) / Double(rgb.count) }
    public var isDark: Bool { rgb.allSatisfy { $0.peak < 1e-9 } && cob.allSatisfy { $0 < 1e-9 } }
}

/// Output driver state shown in Setup (nodes, target, errors, diagnosis).
public struct NetworkStatus: Equatable, Sendable {
    public var nodes: [DiscoveredNode] = []
    public var selectedID: String?
    public var manualIP: IPv4Address?
    public var target: OutputTarget?
    public var interfaces: [NetworkInterface] = []
    public var socketError: String?
    public var pollError: String?
    public var sendError: String?
    public var diagnosis: [String] = []
}

/// Everything the UI shows about one engine frame, published at up to 30 Hz.
public struct EngineSnapshot: Equatable, Sendable {
    public var tempo = TempoSnapshot(bpm: 120, beat: 0, phase: 0)
    public var scene: SceneID = .ambra
    /// Immutable source of the currently playing layer, not a queued scene or the visible bank.
    public var sceneLook: CustomScene?
    public var sceneBeatAnchor: Double?
    public var pendingScene: SceneID?
    public var pendingSceneBank: SceneBank?
    public var fixtures: [FixtureVisual] = []
    public var isDemo = true
    public var master = 0.8
    public var energy = 0.5
    public var subdivision: Subdivision = .one
    public var blackout = false
    public var armed = false
    /// User requested output; stays true while waiting for the selected node to return.
    public var outputRequested = false
    public var sending = false
    public var readiness: OutputReadiness = .noPatch
    public var network = NetworkStatus()
    public var framesSent: UInt64 = 0
    public var suspended = false
    public var isTesting = false
    /// Stop pressed: scene cleared, fading or faded to black.
    public var stopped = false
    public var stopFading = false
    public var accentActive = false
    public var accentLevel = 0.5
    public var levels = ShowSettings()
    /// Scene changes are quantised (Link peers or external beat grid present).
    public var gridTrusted = false
    public var pendingIsDownbeat = false
    public var movementLocked = false
    /// Pattern time of the running scene in scene beats (program step position); nil after Stop.
    public var patternBeat: Double?

    public init() {}

    /// Change key for controls and static rig overlays. Keep fixture identity/geometry/status,
    /// but ignore clock frames, brightness and discovery timestamps. The full snapshot still goes
    /// to the renderer and MIDI; this key is only used to avoid relaying out static controls.
    public var controlState: EngineSnapshot {
        var key = self
        key.fixtures = fixtures.map { fixture in
            var fixture = fixture
            fixture.rgb = []
            fixture.cob = []
            return fixture
        }
        key.framesSent = 0
        key.tempo.beat = 0
        key.tempo.phase = 0
        key.patternBeat = nil
        key.network.nodes = network.nodes.map { node in
            var node = node
            node.lastSeen = 0
            return node
        }
        return key
    }

    /// At least one real patched fixture is receiving DMX right now.
    public var isLive: Bool { armed && sending && fixtures.contains { $0.status == .live } }
}

/// Short engine diagnostics (setup tests). Always ignore role levels, use the current master.
public enum DiagnosticTarget: Equatable, Sendable {
    case all
    /// One RGB segment of every multi-segment (centre) fixture, everything else dark.
    case segment(Int)
    /// One COB of every multi-COB (centre) fixture, everything else dark.
    case cob(Int)
}

/// 30 Hz lighting engine on its own serial queue, independent from the UI.
/// The same composed DMX bytes feed both the preview snapshot and the Art-Net frames.
