import Foundation
import RaysOutput
import RaysTempo
import RaysCore

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
public final class LightEngine: @unchecked Sendable {
    public static let frameRate = 30.0
    /// Light is rendered this far ahead of the Link beat to cover Art-Net + fixture processing.
    public static let outputLatency: TimeInterval = 0.040
    /// Energy changes are smoothed with this time constant (no jumps from a fader flick).
    public static let energySmoothing: TimeInterval = 0.4
    /// The momentary accent auto-releases after this long; it needs a fresh press to fire again.
    public static let accentMaxHold: TimeInterval = 2
    public static let accentRelease: TimeInterval = 0.08

    public let queue = DispatchQueue(label: "io.github.gasparoff.rays.engine", qos: .userInteractive)
    public var onSnapshot: ((EngineSnapshot) -> Void)?
    public var onPreferredNodeChanged: ((String?) -> Void)?

    private let tempo: TempoSource
    private var artnet: OutputDriver
    private let transport: DatagramTransport
    private let interfaces: () -> [NetworkInterface]
    private let clock: () -> TimeInterval
    private var baseLibrary: ProfileLibrary
    private var timer: DispatchSourceTimer?
    private var running = false
    private var suspended = false
    private let outputActivity = OutputActivity()

    private var sequencer = SceneSequencer()
    private var lastScene: SceneID = .ambra
    private var params = SceneParameters()
    private var smoothedEnergy = 0.5
    private var lastTick: TimeInterval?
    private var master = 0.8
    private var levels = ShowSettings()
    private var blackout = false
    private var armed = false
    private var outputRequested = false
    private var lastSocketAttempt: TimeInterval = -.infinity
    private var patch = Patch.empty
    private var patchIssues: [PatchIssue] = []
    private var patchConfirmed = false
    private var roles: [FixtureRole] = []
    /// Default-rig fixtures missing from the real patch; composed into a buffer that is never sent.
    private var shadow = VarytecRig.referenceRig()
    private var framesSent: UInt64 = 0
    private var diagnosticColor: LightColor?
    private var diagnosticTarget = DiagnosticTarget.all
    private var diagnosticEnd: TimeInterval = 0
    private var armedBeforeDiagnostic = false
    private var accentOn = false
    private var accentStart: TimeInterval = 0
    private var accentReleaseFrom: TimeInterval?
    private struct PreviewState {
        var sequencer: SceneSequencer
        var params: SceneParameters
        var energy: Double
        var levels: ShowSettings
        var scene: SceneID
    }
    private var previewState: PreviewState?
    private var restoreFrom: RigFrame?
    private var restoreStart: TimeInterval = 0
    private var previewBlendActive = false
    private var externalGrid = false
    private let runsTimer: Bool

    /// `runsTimer: false` lets tests drive frames manually with `stepForTesting()`.
    public init(tempo: TempoSource, transport: DatagramTransport,
                interfaces: @escaping () -> [NetworkInterface] = NetworkInterface.current,
                library: ProfileLibrary = ProfileLibrary(),
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                runsTimer: Bool = true,
                outputDrivers: OutputDriverRegistry = .builtIn,
                outputDriverID: String = OutputDriverRegistry.defaultDriverID) {
        self.runsTimer = runsTimer
        self.tempo = tempo
        self.transport = transport
        self.interfaces = interfaces
        self.artnet = outputDrivers.make(id: outputDriverID, transport: transport, interfaces: interfaces)
        self.baseLibrary = library
        self.clock = clock
        artnet.onPreferredIdentityChanged = { [weak self] id in self?.onPreferredNodeChanged?(id) }
    }

    // MARK: Lifecycle

    public func start() { queue.async { self.startLocked() } }

    private func startLocked() {
        guard !running else { return }
        running = true
        suspended = false
        outputActivity.update(active: outputRequested || armed)
        lastSocketAttempt = clock()
        artnet.open(queue: queue, now: clock)
        artnet.forcePoll(now: clock())
        guard runsTimer else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: 1 / Self.frameRate, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stopLocked() {
        sendBlackFramesLocked()
        timer?.cancel()
        timer = nil
        artnet.close()
        running = false
        outputActivity.stop()
    }

    /// System sleep: zero frames, stop timer and socket. Armed state is kept for wake.
    public func suspend() {
        queue.async {
            guard self.running else { return }
            self.stopLocked()
            self.suspended = true
            self.publish(self.snapshotLocked(visuals: [], now: self.clock(), beat: self.musicalBeat(self.tempo.capture()),
                                             sending: false))
        }
    }

    /// Wake: rebind socket (interfaces may have changed) and rediscover immediately.
    public func resume() {
        queue.async {
            guard self.suspended else { return }
            self.startLocked()
        }
    }

    /// App termination: synchronously send zero frames, disarm and close.
    public func shutdown() {
        queue.sync {
            stopLocked()
            armed = false
            outputRequested = false
        }
    }

    // MARK: Controls (thread-safe, applied on the engine queue)

    /// Requests a scene on the grid (see `SceneTransition`). `immediate` replaces the scene with
    /// no fade (launch restore).
    public func setScene(_ s: SceneID, immediate: Bool = false) {
        queue.async {
            if immediate {
                let look = self.sequencer.look
                self.sequencer = SceneSequencer(scene: s, rate: self.params.subdivision.rate)
                self.sequencer.setLook(look)
                self.lastScene = s
                return
            }
            let t = self.tempo.capture()
            self.sequencer.request(s, beat: self.musicalBeat(t), now: self.clock(), gridTrusted: self.gridTrusted(t))
        }
    }

    /// Requests a scene with its custom look (nil = plain preset). Another bank's scene launches on
    /// the grid even in the same slot. Edits within a bank update its running look without restarting.
    /// The look (program included) is compiled here, off the 30 Hz path.
    public func setScene(_ s: SceneID, look scene: CustomScene?, immediate: Bool = false) {
        let look = scene.map(SceneLook.init)
        queue.async {
            if immediate {
                self.sequencer = SceneSequencer(scene: s, rate: self.params.subdivision.rate)
                self.sequencer.setLook(look)
                self.lastScene = s
                return
            }
            let t = self.tempo.capture()
            self.sequencer.request(s, look: look, beat: self.musicalBeat(t), now: self.clock(), gridTrusted: self.gridTrusted(t))
        }
    }

    /// The local tempo owner captured the press and made it a downbeat. Reconcile that local
    /// grid correction before setting the running scene's origin, so the following tick cannot
    /// mistake the user command for an unrelated timeline jump. Output latency remains unchanged.
    public func restartScene(at beat: Double) {
        guard beat.isFinite else { return }
        queue.async {
            let t = self.tempo.capture(), now = self.clock()
            self.sequencer.advance(beat: self.musicalBeat(t), bpm: t.bpm, now: now, gridTrusted: self.gridTrusted(t))
            self.sequencer.restartCurrentScene(at: beat)
        }
    }

    /// Resolve cancellation on the engine queue; a launch which already started is left alone.
    public func cancelPendingScene(onCancel: @escaping @MainActor @Sendable (SceneID, CustomScene?) -> Void) {
        queue.async {
            guard self.sequencer.cancelPendingScene() else { return }
            let scene = self.sequencer.targetScene ?? self.lastScene
            let look = self.sequencer.currentSceneLook
            DispatchQueue.main.async { onCancel(scene, look) }
        }
    }

    /// Dedicated DJ gesture follows real Link beats even if the other scenes
    /// have been slowed down. The user's movement-rate setting is preserved.
    public func setBuildDropGesture(_ held: Bool, look: CustomScene? = nil) {
        let compiled = look.map(SceneLook.init)
        queue.async {
            let t = self.tempo.capture()
            self.sequencer.request(held ? .aurora : .respiro, look: compiled, beat: self.musicalBeat(t), now: self.clock(),
                                   gridTrusted: self.gridTrusted(t), rateOverride: 1, forceRestart: true)
        }
    }

    /// Fades to black over one beat and clears the scene until a scene is chosen again.
    public func stop() {
        queue.async {
            let t = self.tempo.capture()
            self.sequencer.stop(beat: self.musicalBeat(t), now: self.clock(), gridTrusted: self.gridTrusted(t))
        }
    }

    public func beginScenePreview() {
        queue.async {
            guard self.previewState == nil else { return }
            self.previewState = PreviewState(sequencer: self.sequencer, params: self.params,
                                              energy: self.smoothedEnergy, levels: self.levels,
                                              scene: self.lastScene)
            self.restoreFrom = nil
        }
    }

    public func finishScenePreview(restore: Bool) {
        queue.async {
            guard let before = self.previewState else { return }
            self.previewState = nil
            guard restore else { return }
            let now = self.clock(), tempo = self.tempo.capture()
            var from = self.rigFrame(now: now, beat: self.musicalBeat(tempo), tempo: tempo)
            if !self.previewBlendActive {
                for role in FixtureRole.allCases { from[role] = from[role].scaled(self.levels.level(role)) }
            }
            self.sequencer = before.sequencer
            self.params = before.params
            self.smoothedEnergy = before.energy
            self.levels = before.levels
            self.lastScene = before.scene
            self.restoreFrom = from
            self.restoreStart = now
        }
    }

    /// Changes the look of the running scene (live editing). Stop stays black; fading-out scenes keep theirs.
    public func setCustomScene(_ scene: CustomScene?) {
        let look = scene.map(SceneLook.init)
        queue.async { self.sequencer.setLook(look) }
    }

    /// Live edit of the running custom scene: updates its look, or launches `s` with it if the show is
    /// stopped. Decided on the engine queue from the sequencer itself: a UI snapshot that still says
    /// "stopped" just after a launch must never request the scene again (that re-arms a phrase scene).
    public func setCustomScene(_ scene: CustomScene, relaunchingIfStoppedAs s: SceneID) {
        let look = SceneLook(scene)
        queue.async {
            guard self.sequencer.isStopped else { self.sequencer.setLook(look); return }
            let t = self.tempo.capture()
            self.sequencer.request(s, look: look, beat: self.musicalBeat(t), now: self.clock(), gridTrusted: self.gridTrusted(t))
        }
    }

    public func setMaster(_ v: Double) { queue.async { self.master = clamp01(v) } }
    public func setEnergy(_ v: Double) { queue.async { self.params.energy = clamp01(v) } }

    public func setSubdivision(_ s: Subdivision, immediate: Bool = false) {
        queue.async {
            self.params.subdivision = s
            if immediate {
                let look = self.sequencer.look
                self.sequencer = SceneSequencer(scene: self.sequencer.targetScene ?? self.lastScene, rate: s.rate)
                self.sequencer.setLook(look)
            } else {
                self.sequencer.setRate(s.rate, beat: self.musicalBeat(self.tempo.capture()), now: self.clock())
            }
        }
    }

    public func setLevel(_ role: FixtureRole, _ v: Double) { queue.async { self.levels.setLevel(role, v) } }
    public func setShowSettings(_ show: ShowSettings) { queue.async { self.levels = show } }
    public func setWhiteLevel(_ v: Double) { queue.async { self.levels.whiteLevel = clamp01(v) } }

    public func setAccentLevel(_ v: Double) { queue.async { self.levels.accentLevel = clamp01(v) } }

    /// Momentary warm COB hit on every fixture: `true` on press, `false` on release. Ignored
    /// during blackout; auto-releases after `accentMaxHold`.
    public func setAccent(_ on: Bool) {
        queue.async {
            let now = self.clock()
            if on {
                guard !self.blackout else { return }
                self.accentOn = true
                self.accentStart = now
                self.accentReleaseFrom = nil
            } else if self.accentOn {
                self.accentOn = false
                self.accentReleaseFrom = now
            }
        }
    }

    /// Set by the beat-source owner while an external grid (XDJ / Beat Link) drives the Link
    /// timeline. With it, or with Link peers, scene changes are quantised.
    public func setExternalBeatGrid(_ on: Bool) { queue.async { self.externalGrid = on } }

    public func setBlackout(_ on: Bool) { queue.async {
        self.blackout = on
        if on {
            if self.diagnosticColor != nil { self.endDiagnosticLocked() }
            self.accentOn = false
            self.accentReleaseFrom = nil
            self.tick()
        }
    } }

    /// Brief static check using the same validated patch and socket as the show. If output was
    /// off it is armed for the test and black frames + disarm follow; if it was on, the show resumes.
    public func runDiagnostic(_ color: LightColor, duration: TimeInterval = 5, target: DiagnosticTarget = .all) {
        queue.async {
            guard color.isFinite, self.readinessLocked(now: self.clock()).0 == .ready else { return }
            if self.diagnosticColor == nil { self.armedBeforeDiagnostic = self.armed }
            self.diagnosticColor = color.clamped
            self.diagnosticTarget = target
            self.diagnosticEnd = self.clock() + min(10, max(0.5, duration.isFinite ? duration : 5))
            self.blackout = false
            self.armed = true
            self.tick()
        }
    }

    public func cancelDiagnostic() {
        queue.async {
            guard self.diagnosticColor != nil else { return }
            self.endDiagnosticLocked()
        }
    }

    private func endDiagnosticLocked() {
        diagnosticColor = nil
        if !armedBeforeDiagnostic {
            sendBlackFramesLocked()
            armed = false
        }
        armedBeforeDiagnostic = false
    }

    public func setTempo(_ bpm: Double) { queue.async { self.tempo.setTempo(bpm) } }
    public func setStartStopSync(_ on: Bool) { queue.async { self.tempo.setStartStopSync(on) } }

    public func setArmed(_ on: Bool) {
        queue.async {
            if on {
                if self.readinessLocked(now: self.clock()).0 == .ready {
                    self.outputRequested = true
                    self.armed = true
                }
            } else {
                self.outputRequested = false
                self.sendBlackFramesLocked()
                self.diagnosticColor = nil
                self.armedBeforeDiagnostic = false
                self.armed = false
            }
        }
    }

    /// Restore a saved output request even before the node is discovered. Validation is
    /// still checked on every frame. Explicit off cancels both active and pending output.
    public func setOutputRequested(_ on: Bool) {
        if !on { setArmed(false); return }
        queue.async { self.outputRequested = true }
    }

    public func setPatch(_ newPatch: Patch, library: ProfileLibrary? = nil) {
        queue.async {
            self.outputRequested = false
            if self.armed { self.sendBlackFramesLocked(); self.armed = false }
            self.diagnosticColor = nil
            self.armedBeforeDiagnostic = false
            if let library { self.baseLibrary = library }
            self.patch = newPatch
            self.patchIssues = newPatch.validate(library: self.baseLibrary)
            self.patchConfirmed = newPatch.isConfirmed(library: self.baseLibrary)
            self.roles = newPatch.roles(library: self.baseLibrary)
            let present: Set<FixtureRole> = self.showsRealPatch ? Set(self.roles) : []
            var rig = VarytecRig.referenceRig(universe: 1)
            rig.fixtures.removeAll { present.contains($0.role ?? .center) }
            self.shadow = rig
        }
    }

    public func selectNode(_ identity: String?) {
        queue.async {
            self.outputRequested = false
            if self.armed { self.sendBlackFramesLocked(); self.armed = false }
            self.artnet.select(identity: identity)
        }
    }

    public func setManualIP(_ ip: IPv4Address?) {
        queue.async {
            self.outputRequested = false
            if self.armed { self.sendBlackFramesLocked(); self.armed = false }
            self.artnet.manualIP = ip
            if ip != nil { self.artnet.preferredIdentity = nil }
            self.artnet.forcePoll(now: self.clock())
        }
    }

    /// Switches the output driver. Output is disarmed first (black frames on the old driver),
    /// so changing the driver never turns lights on.
    public func useOutputDriver(_ id: String, registry: OutputDriverRegistry) {
        queue.async {
            self.outputRequested = false
            if self.armed { self.sendBlackFramesLocked(); self.armed = false }
            self.outputActivity.update(active: false)
            self.artnet.close()
            self.artnet = registry.make(id: id, transport: self.transport, interfaces: self.interfaces)
            self.artnet.onPreferredIdentityChanged = { [weak self] id in self?.onPreferredNodeChanged?(id) }
            self.lastSocketAttempt = -.infinity
            if self.running, !self.suspended {
                self.lastSocketAttempt = self.clock()
                self.artnet.open(queue: self.queue, now: self.clock)
                self.artnet.forcePoll(now: self.clock())
            }
        }
    }

    public var outputDriverID: String { sync { artnet.driverID } }

    public func setPreferredIdentity(_ identity: String?) { queue.async { self.artnet.preferredIdentity = identity } }

    public func rediscover() { queue.async {
        self.reopenSocketIfNeeded(now: self.clock(), force: true)
        self.artnet.forcePoll(now: self.clock())
    } }

    private func reopenSocketIfNeeded(now: TimeInterval, force: Bool = false) {
        guard running, !suspended, !artnet.isOpen,
              force || now - lastSocketAttempt >= artnet.reopenInterval else { return }
        lastSocketAttempt = now
        artnet.open(queue: queue, now: clock)
        if artnet.isOpen { artnet.forcePoll(now: now) }
    }

    /// Runs one frame synchronously (tests).
    public func stepForTesting() { queue.sync { tick() } }

    public func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    // MARK: Frame

    private func readinessLocked(now: TimeInterval) -> (OutputReadiness, OutputTarget?) {
        if patch.fixtures.isEmpty { return (.noPatch, nil) }
        if let issue = patchIssues.first { return (.invalidPatch(issue.message), nil) }
        if !patchConfirmed { return (.notConfirmed, nil) }
        if !artnet.isOpen { return (.socketUnavailable(artnet.socketError ?? "Socket Art-Net chiuso"), nil) }
        guard let target = artnet.target(now: now, patchUniverses: patch.universes) else { return (.noDevice, nil) }
        if target.verified && !target.fresh { return (.noDevice, target) }
        if !Set(patch.universes).isSubset(of: Set(target.universes)) { return (.noMatchingUniverse, target) }
        return (.ready, target)
    }

    private var showsRealPatch: Bool { !patch.fixtures.isEmpty && patchIssues.isEmpty }

    private func gridTrusted(_ t: TempoSnapshot) -> Bool { t.peers > 0 || t.externalClock || externalGrid }

    /// Link beat plus the output lead; non-finite values are ignored by the sequencer.
    private func musicalBeat(_ t: TempoSnapshot) -> Double {
        let bpm = t.bpm.isFinite && t.bpm > 0 ? t.bpm : 120
        return t.beat + Self.outputLatency * bpm / 60
    }

    private func accentEnvelope(now: TimeInterval) -> Double {
        if accentOn {
            if now - accentStart < Self.accentMaxHold { return 1 }
            accentOn = false
            accentReleaseFrom = accentStart + Self.accentMaxHold
        }
        guard let from = accentReleaseFrom else { return 0 }
        let k = 1 - (now - from) / Self.accentRelease
        if k <= 0 || !k.isFinite { accentReleaseFrom = nil; return 0 }
        return min(1, k)
    }

    private func diagnosticFrame(_ c: LightColor, _ target: DiagnosticTarget) -> RigFrame {
        let rgb = LightColor(c.r, c.g, c.b)
        switch target {
        case .all:
            func role(_ n: Int, _ k: Int) -> RoleFrame { RoleFrame(rgb: Array(repeating: rgb, count: n), cob: Array(repeating: c.w, count: k)) }
            return RigFrame(left: role(1, 1), center: role(RigFrame.centerSegments, RigFrame.centerCOBs), right: role(1, 1))
        case .segment(let i):
            var f = RigFrame.black
            if f.center.rgb.indices.contains(i) { f.center.rgb[i] = rgb }
            return f
        case .cob(let k):
            var f = RigFrame.black
            if f.center.cob.indices.contains(k) { f.center.cob[k] = c.w }
            return f
        }
    }

    /// Scene/diagnostic frame for this tick, accent applied (blackout is applied by the composer).
    private func rigFrame(now: TimeInterval, beat: Double, tempo t: TempoSnapshot) -> RigFrame {
        let dt = lastTick.map { now - $0 } ?? 0
        lastTick = now
        if dt > 0 { smoothedEnergy += (params.energy - smoothedEnergy) * (1 - exp(-dt / Self.energySmoothing)) }
        if !smoothedEnergy.isFinite { smoothedEnergy = params.energy }
        sequencer.advance(beat: beat, bpm: t.bpm, now: now, gridTrusted: gridTrusted(t))
        if let s = sequencer.targetScene { lastScene = s }
        previewBlendActive = false
        if let color = diagnosticColor { return diagnosticFrame(color, diagnosticTarget) }
        // Custom looks and program tracks are rendered inside the sequencer layers (fades, Stop).
        var rig = sequencer.render(beat: beat, energy: smoothedEnergy, now: now)
        let accent = accentEnvelope(now: now) * levels.accentLevel
        if accent > 0 {
            // Deliberately above Stop: a blinder hit out of a stopped, dark room is a classic move.
            for role in FixtureRole.allCases { rig[role].cob = rig[role].cob.map { max($0, accent) } }
        }
        if let from = restoreFrom {
            for role in FixtureRole.allCases { rig[role] = rig[role].scaled(levels.level(role)) }
            let progress = min(1, max(0, (now - restoreStart) / 0.3))
            rig = from.mixed(with: rig, progress * progress * (3 - 2 * progress))
            previewBlendActive = true
            if progress >= 1 { restoreFrom = nil }
        }
        return rig
    }

    private func compose(_ p: Patch, roles: [FixtureRole], rig: RigFrame, diagnostic: Bool) -> [PortAddress: [UInt8]] {
        // Apply white brightness after crossfades too, so zero always silences COBs immediately.
        let lv = roles.map { role in
            FixtureLevels(rgb: rig[role].rgb, cob: rig[role].cob.map { $0 * levels.whiteLevel })
        }
        let scales = roles.map { diagnostic || previewBlendActive ? master : master * levels.level($0) }
        return DMXComposer.compose(patch: p, library: baseLibrary, levels: lv, scales: scales, blackout: blackout)
    }

    private func tick() {
        let now = clock()
        reopenSocketIfNeeded(now: now)
        if diagnosticColor != nil && now >= diagnosticEnd { endDiagnosticLocked() }
        artnet.pollIfDue(now: now)
        let t = tempo.capture()
        let beat = musicalBeat(t)
        let rig = rigFrame(now: now, beat: beat, tempo: t)
        let diagnostic = diagnosticColor != nil

        var sending = false
        let (readiness, target) = readinessLocked(now: now)
        if armed, readiness != .ready {
            // Stop transmitting until validation passes again, but retain the user's request.
            sendBlackFramesLocked()
            armed = false
            diagnosticColor = nil
            armedBeforeDiagnostic = false
        }
        if outputRequested, readiness == .ready { armed = true }
        let real = showsRealPatch ? compose(patch, roles: roles, rig: rig, diagnostic: diagnostic) : [:]
        if armed, let target {
            sending = artnet.sendDMX(real, to: target)
            if sending { framesSent &+= 1 }
        }
        let shadowRoles = shadow.roles(library: baseLibrary)
        let shadowFrames = compose(shadow, roles: shadowRoles, rig: rig, diagnostic: diagnostic)
        var visuals = showsRealPatch ? visualsLocked(patch, roles: roles, frames: real, status: armed && sending ? .live : .off) : []
        visuals += visualsLocked(shadow, roles: shadowRoles, frames: shadowFrames, status: .previewOnly)
        let order: [FixtureRole: Int] = [.left: 0, .center: 1, .right: 2]
        visuals = visuals.enumerated().sorted {
            (order[$0.element.role]!, $0.offset) < (order[$1.element.role]!, $1.offset)
        }.map(\.element)

        var snap = snapshotLocked(visuals: visuals, now: now, beat: beat, sending: sending)
        snap.tempo = t
        snap.readiness = readiness
        publish(snap)
    }

    private func visualsLocked(_ p: Patch, roles: [FixtureRole], frames: [PortAddress: [UInt8]],
                               status: FixtureVisual.Status) -> [FixtureVisual] {
        let lib = p.library(base: baseLibrary)
        return p.fixtures.enumerated().map { i, f in
            let profile = lib.profile(id: f.profileID)
            let levels = profile.flatMap { pr in
                PortAddress(f.universe).flatMap { frames[$0] }.map { DMXComposer.decode(profile: pr, universe: $0, address: f.address) }
            } ?? .off
            return FixtureVisual(id: status == .previewOnly ? "preview-\(roles[i].rawValue)" : f.id.uuidString,
                                 label: f.label, profileID: f.profileID, role: roles[i], universe: f.universe,
                                 address: f.address, rgb: levels.rgb, cob: levels.cob, status: status)
        }
    }

    private func sendBlackFramesLocked() {
        guard armed else { return }  // never emit DMX unless output was armed with a confirmed patch
        guard let target = readinessLocked(now: clock()).1 else { return }
        let zeros = DMXComposer.compose(patch: patch, library: baseLibrary, levels: [], scales: [], blackout: true)
        for _ in 0..<3 { artnet.sendDMX(zeros, to: target) }
    }

    private func snapshotLocked(visuals: [FixtureVisual], now: TimeInterval, beat: Double, sending: Bool) -> EngineSnapshot {
        var s = EngineSnapshot()
        s.scene = lastScene
        s.pendingScene = sequencer.pendingScene
        s.pendingSceneBank = sequencer.pendingSceneBank
        s.pendingIsDownbeat = sequencer.pendingIsDownbeat
        s.stopped = sequencer.isStopped
        s.stopFading = sequencer.isStopFading(beat: beat, now: now)
        s.isDemo = !showsRealPatch
        s.master = master
        s.energy = params.energy
        s.subdivision = sequencer.isRateLocked ? .one : params.subdivision
        s.movementLocked = sequencer.isRateLocked
        s.patternBeat = sequencer.patternBeat(beat: beat)
        s.sceneLook = sequencer.currentSceneLook
        s.sceneBeatAnchor = sequencer.currentSceneBeatAnchor
        s.levels = levels
        s.accentLevel = levels.accentLevel
        s.accentActive = (accentOn || accentReleaseFrom != nil) && !blackout
        s.blackout = blackout
        s.armed = armed
        s.outputRequested = outputRequested
        s.sending = sending
        s.framesSent = framesSent
        s.suspended = suspended
        s.isTesting = diagnosticColor != nil
        let t = tempo.capture()
        s.tempo = t
        s.gridTrusted = gridTrusted(t)
        s.readiness = readinessLocked(now: now).0
        s.fixtures = visuals
        var net = NetworkStatus()
        net.nodes = artnet.nodes(now: now)
        net.selectedID = artnet.preferredIdentity
        net.manualIP = artnet.manualIP
        net.target = artnet.target(now: now, patchUniverses: patch.universes)
        net.interfaces = artnet.interfaces
        net.socketError = artnet.socketError
        net.pollError = artnet.pollError
        net.sendError = artnet.sendError
        net.diagnosis = artnet.diagnosis(now: now)
        s.network = net
        return s
    }

    private func publish(_ s: EngineSnapshot) {
        // This follows output intent, not window visibility. Keep it through outages,
        // blackout and Stop (which still transmit DMX), and release it when output is off.
        outputActivity.update(active: running && (s.outputRequested || s.armed))
        onSnapshot?(s)
    }
}

