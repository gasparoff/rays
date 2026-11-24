import Foundation
import RaysOutput
import RaysTempo
import RaysCore

/// The 30 Hz lighting engine: tempo in, scenes and choreography, DMX out through an `OutputDriver`, snapshots to the UI.
///
/// `@unchecked Sendable`: every mutable stored property is owned by the serial `queue`. Public
/// methods only enqueue work on it (or `queue.sync` for shutdown and tests); the timer, the
/// driver's receive callback and the driver itself run on it. The two callbacks below are the
/// exception: they may be set from any thread and are guarded by `callbackLock`.
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
    /// Receives every snapshot, on `queue`: hop to the main thread yourself (see `LatestMailbox`).
    /// Safe to set from any thread, also while the engine runs.
    public var onSnapshot: ((EngineSnapshot) -> Void)? {
        get { callbackLock.withLock { snapshotHandler } }
        set { callbackLock.withLock { snapshotHandler = newValue } }
    }
    /// The driver auto-selected a node; called on `queue`. Safe to set from any thread.
    public var onPreferredNodeChanged: ((String?) -> Void)? {
        get { callbackLock.withLock { preferredNodeHandler } }
        set { callbackLock.withLock { preferredNodeHandler = newValue } }
    }
    /// Guards only the two handlers above, which the app sets from the main thread. Held just to
    /// copy a reference, never while a handler runs.
    private let callbackLock = NSLock()
    private var snapshotHandler: ((EngineSnapshot) -> Void)?
    private var preferredNodeHandler: ((String?) -> Void)?

    private let tempo: TempoSource
    private var output: OutputDriver
    private let transport: DatagramTransport
    private let interfaces: () -> [NetworkInterface]
    private let clock: () -> TimeInterval
    private var baseLibrary: ProfileLibrary
    private var timer: DispatchSourceTimer?
    /// Output safety: armed, request, blackout, diagnostic, running. Decides; the engine does the I/O.
    private var gate = OutputGate()
    private let outputActivity = OutputActivity()

    private var sequencer = SceneSequencer()
    private var lastScene: SceneID = .ambra
    private var params = SceneParameters()
    private var smoothedEnergy = 0.5
    private var lastTick: TimeInterval?
    private var master = 0.8
    private var levels = ShowSettings() {
        didSet { rebuildMixLocked() }
    }
    /// Live direct commands on groups (colour, flash, solo, mute). Never saved.
    private var overrides = GroupOverrides() {
        didSet { rebuildMixLocked() }
    }
    /// `levels.masters` and `overrides` by group position, rebuilt when either changes, so the frame
    /// reads arrays instead of looking group ids up.
    private var mix = GroupMix(ids: LightEngine.frameGroups, masters: ShowSettings().masters)
    private var lastSocketAttempt: TimeInterval = -.infinity
    private var patch = Patch.empty
    private var patchIssues: [PatchIssue] = []
    private var patchConfirmed = false
    /// Default-rig fixtures missing from the real patch; composed into a buffer that is never sent.
    private var shadow = VarytecRig.referenceRig()
    /// Patch-derived data for the frame, rebuilt only when the patch or library changes.
    private var cache = PatchCache()
    /// Network part of the snapshot, refreshed at a low rate or when something changed.
    private var network = NetworkStatus()
    private var networkRefreshedAt: TimeInterval = -.infinity
    private var networkWasOpen = false
    /// Set by user actions that change the network selection: refresh on the next snapshot.
    private var networkDirty = true
    private var framesSent: UInt64 = 0
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
    public init(
        tempo: TempoSource, transport: DatagramTransport,
        interfaces: @escaping () -> [NetworkInterface] = NetworkInterface.current,
        library: ProfileLibrary = ProfileLibrary(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        runsTimer: Bool = true,
        outputDrivers: OutputDriverRegistry = .builtIn,
        outputDriverID: String = OutputDriverRegistry.defaultDriverID
    ) {
        self.runsTimer = runsTimer
        self.tempo = tempo
        self.transport = transport
        self.interfaces = interfaces
        self.output = outputDrivers.make(id: outputDriverID, transport: transport, interfaces: interfaces)
        self.baseLibrary = library
        self.clock = clock
        rebuildPatchCacheLocked()
        observeOutputDriver()
    }

    // MARK: Lifecycle

    public func start() { queue.async { self.startLocked() } }

    private func startLocked() {
        guard gate.start() else { return }
        outputActivity.update(active: gate.wantsOutput)
        lastSocketAttempt = clock()
        output.open(queue: queue, now: clock)
        output.forcePoll(now: clock())
        networkDirty = true
        guard runsTimer else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: 1 / Self.frameRate, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// `effects` comes from the gate's stop transition (black frames while still armed).
    private func stopLocked(_ effects: OutputGate.Effects) {
        perform(effects)
        timer?.cancel()
        timer = nil
        output.close()
        networkDirty = true
        outputActivity.stop()
    }

    /// System sleep: zero frames, stop timer and socket. Armed state is kept for wake.
    public func suspend() {
        queue.async {
            guard let effects = self.gate.suspend() else { return }
            self.stopLocked(effects)
            let now = self.clock(), t = self.tempo.capture()
            let (readiness, target) = self.currentReadinessLocked()
            self.publish(
                self.snapshotLocked(
                    visuals: [], now: now, beat: self.musicalBeat(t), tempo: t,
                    readiness: readiness, target: target, sending: false))
        }
    }

    /// Wake: rebind socket (interfaces may have changed) and rediscover immediately.
    public func resume() {
        queue.async {
            guard self.gate.resume() else { return }
            self.startLocked()
        }
    }

    /// App termination: synchronously send zero frames, disarm and close.
    public func shutdown() {
        queue.sync { stopLocked(gate.shutdown()) }
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
            self.sequencer.request(
                held ? .aurora : .respiro, look: compiled, beat: self.musicalBeat(t), now: self.clock(),
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
            self.previewState = PreviewState(
                sequencer: self.sequencer, params: self.params,
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
            if !self.previewBlendActive { self.scaleByGroupMasters(&from) }
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
    /// Master of any rig group (ADR 0005).
    public func setLevel(group id: RigGroupID, _ v: Double) { queue.async { self.levels.setLevel(group: id, v) } }
    public func setShowSettings(_ show: ShowSettings) { queue.async { self.levels = show } }
    public func setWhiteLevel(_ v: Double) { queue.async { self.levels.whiteLevel = clamp01(v) } }

    public func setAccentLevel(_ v: Double) { queue.async { self.levels.accentLevel = clamp01(v) } }

    /// Momentary warm COB hit on every fixture: `true` on press, `false` on release. Ignored
    /// during blackout; auto-releases after `accentMaxHold`.
    public func setAccent(_ on: Bool) {
        queue.async {
            let now = self.clock()
            if on {
                guard !self.gate.blackout else { return }
                self.accentOn = true
                self.accentStart = now
                self.accentReleaseFrom = nil
            } else if self.accentOn {
                self.accentOn = false
                self.accentReleaseFrom = now
            }
        }
    }

    // MARK: Group direct commands (ADR 0005)
    //
    // Performance state layered on the scene in a fixed order (see `GroupMix`); blackout always wins
    // over every one of them, and none of them arms the output or touches strobe/program channels.

    /// Replaces the group's colour, keeping the scene's intensity shape; nil gives the scene's colour back.
    public func setGroupColor(_ color: LightColor?, for id: RigGroupID) {
        queue.async { self.overrides.colors[id] = color.map { LightColor($0.r, $0.g, $0.b).clamped } }
    }

    /// Momentary full-on of a group: `true` on press, `false` on release. Ignored during blackout,
    /// and released by blackout, so leaving blackout never flashes.
    public func setGroupFlash(_ on: Bool, for id: RigGroupID) {
        queue.async {
            if on {
                guard !self.gate.blackout else { return }
                self.overrides.flashing.insert(id)
            } else {
                self.overrides.flashing.remove(id)
            }
        }
    }

    /// While any group is soloed, every group that is not is dark.
    public func setGroupSolo(_ on: Bool, for id: RigGroupID) {
        queue.async {
            if on { self.overrides.soloed.insert(id) } else { self.overrides.soloed.remove(id) }
        }
    }

    public func setGroupMute(_ on: Bool, for id: RigGroupID) {
        queue.async {
            if on { self.overrides.muted.insert(id) } else { self.overrides.muted.remove(id) }
        }
    }

    /// Drops every colour override, flash, solo and mute.
    public func clearGroupOverrides() { queue.async { self.overrides = GroupOverrides() } }

    /// Set by the beat-source owner while an external grid (XDJ / Beat Link) drives the Link
    /// timeline. With it, or with Link peers, scene changes are quantised.
    public func setExternalBeatGrid(_ on: Bool) { queue.async { self.externalGrid = on } }

    public func setBlackout(_ on: Bool) {
        queue.async { self.perform(self.gate.setBlackout(on)) }
    }

    /// Brief static check using the same validated patch and socket as the show. If output was
    /// off it is armed for the test and black frames + disarm follow; if it was on, the show resumes.
    /// Ignored during blackout: blackout always wins, so a test never lights a blacked-out rig.
    public func runDiagnostic(_ color: LightColor, duration: TimeInterval = 5, target: DiagnosticTarget = .all) {
        queue.async {
            let effects = self.gate.startDiagnostic(
                color, target: target, duration: duration, now: self.clock(),
                ready: self.currentReadinessLocked().0 == .ready)
            self.perform(effects)
        }
    }

    public func cancelDiagnostic() { queue.async { self.perform(self.gate.endDiagnostic()) } }

    public func setTempo(_ bpm: Double) { queue.async { self.tempo.setTempo(bpm) } }
    public func setStartStopSync(_ on: Bool) { queue.async { self.tempo.setStartStopSync(on) } }

    public func setArmed(_ on: Bool) {
        queue.async {
            let ready = on && self.currentReadinessLocked().0 == .ready
            self.perform(self.gate.setOutput(on, ready: ready))
        }
    }

    /// Restore a saved output request even before the node is discovered. Validation is
    /// still checked on every frame. Explicit off cancels both active and pending output.
    public func setOutputRequested(_ on: Bool) {
        if !on { setArmed(false); return }
        queue.async { self.gate.restoreRequest() }
    }

    public func setPatch(_ newPatch: Patch, library: ProfileLibrary? = nil) {
        queue.async {
            // Black frames go out on the old patch, before it is replaced.
            self.perform(self.gate.patchChanged())
            if let library { self.baseLibrary = library }
            self.patch = newPatch
            self.patchIssues = newPatch.validate(library: self.baseLibrary)
            self.patchConfirmed = newPatch.isConfirmed(library: self.baseLibrary)
            let present: Set<FixtureRole> = self.showsRealPatch ? Set(newPatch.roles(library: self.baseLibrary)) : []
            var rig = VarytecRig.referenceRig(universe: 1)
            rig.fixtures.removeAll { present.contains($0.role ?? .center) }
            self.shadow = rig
            self.rebuildPatchCacheLocked()
            self.networkDirty = true
        }
    }

    public func selectNode(_ identity: String?) {
        queue.async {
            self.perform(self.gate.destinationChanged())
            self.output.select(identity: identity)
            self.networkDirty = true
        }
    }

    public func setManualIP(_ ip: IPv4Address?) {
        queue.async {
            self.perform(self.gate.destinationChanged())
            self.output.manualIP = ip
            if ip != nil { self.output.preferredIdentity = nil }
            self.output.forcePoll(now: self.clock())
            self.networkDirty = true
        }
    }

    /// Switches the output driver. Output is disarmed first (black frames on the old driver),
    /// so changing the driver never turns lights on.
    public func useOutputDriver(_ id: String, registry: OutputDriverRegistry) {
        queue.async {
            self.perform(self.gate.destinationChanged())
            self.outputActivity.update(active: false)
            self.output.close()
            self.output = registry.make(id: id, transport: self.transport, interfaces: self.interfaces)
            self.observeOutputDriver()
            self.lastSocketAttempt = -.infinity
            if self.gate.running, !self.gate.suspended {
                self.lastSocketAttempt = self.clock()
                self.output.open(queue: self.queue, now: self.clock)
                self.output.forcePoll(now: self.clock())
            }
            self.networkDirty = true
        }
    }

    public var outputDriverID: String { sync { output.driverID } }

    /// Forwards the driver's auto-selected node to `onPreferredNodeChanged` without retaining the engine.
    private func observeOutputDriver() {
        output.onPreferredIdentityChanged = { [weak self] id in self?.onPreferredNodeChanged?(id) }
    }

    public func setPreferredIdentity(_ identity: String?) {
        queue.async {
            self.output.preferredIdentity = identity
            self.networkDirty = true
        }
    }

    public func rediscover() {
        queue.async {
            self.reopenSocketIfNeeded(now: self.clock(), force: true)
            self.output.forcePoll(now: self.clock())
            self.networkDirty = true
        }
    }

    private func reopenSocketIfNeeded(now: TimeInterval, force: Bool = false) {
        guard gate.running, !gate.suspended, !output.isOpen,
            force || now - lastSocketAttempt >= output.reopenInterval
        else { return }
        lastSocketAttempt = now
        output.open(queue: queue, now: clock)
        if output.isOpen { output.forcePoll(now: now) }
    }

    /// Runs one frame synchronously (tests).
    public func stepForTesting() { queue.sync { tick() } }

    public func sync<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

    // MARK: Frame

    /// Whether DMX can be sent to `target` (the driver's target for the patch universes, looked up once).
    private func readinessLocked(target: OutputTarget?) -> OutputReadiness {
        if patch.fixtures.isEmpty { return .noPatch }
        if let issue = patchIssues.first { return .invalidPatch(issue.message) }
        if !patchConfirmed { return .notConfirmed }
        if !output.isOpen { return .socketUnavailable(output.socketError ?? String(localized: "Output closed")) }
        guard let target else { return .noDevice }
        if target.verified && !target.fresh { return .noDevice }
        // Patch universes are unique: every one must be among the target's.
        if !cache.universes.allSatisfy({ target.universes.contains($0) }) { return .noMatchingUniverse }
        return .ready
    }

    /// Readiness and target right now, for actions outside the frame.
    private func currentReadinessLocked() -> (OutputReadiness, OutputTarget?) {
        let target = output.target(now: clock(), patchUniverses: cache.universes)
        return (readinessLocked(target: target), target)
    }

    /// Where black frames may go: a validated patch on an open output with a known (even stale) target.
    static func blackFrameTarget(_ readiness: OutputReadiness, _ target: OutputTarget?) -> OutputTarget? {
        switch readiness {
        case .ready, .noDevice, .noMatchingUniverse: return target
        case .noPatch, .invalidPatch, .notConfirmed, .socketUnavailable: return nil
        }
    }

    /// Carries out what the gate decided, outside a frame: black frames go to the current target.
    private func perform(_ effects: OutputGate.Effects) {
        if effects.contains(.sendBlack) {
            let (readiness, target) = currentReadinessLocked()
            sendBlackFramesLocked(to: Self.blackFrameTarget(readiness, target))
        }
        if effects.contains(.killAccent) {
            accentOn = false
            accentReleaseFrom = nil
            if !overrides.flashing.isEmpty { overrides.flashing.removeAll() }
        }
        if effects.contains(.renderNow) { tick() }
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
            func role(_ n: Int, _ k: Int) -> RoleFrame {
                RoleFrame(rgb: Array(repeating: rgb, count: n), cob: Array(repeating: c.w, count: k))
            }
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
        if let test = gate.diagnostic { return diagnosticFrame(test.color, test.target) }
        // Custom looks and program tracks are rendered inside the sequencer layers (fades, Stop).
        var rig = sequencer.render(beat: beat, energy: smoothedEnergy, now: now)
        let accent = accentEnvelope(now: now) * levels.accentLevel
        if accent > 0 {
            // Deliberately above Stop: a blinder hit out of a stopped, dark room is a classic move.
            for role in FixtureRole.allCases { rig[role].cob = rig[role].cob.map { max($0, accent) } }
        }
        if let from = restoreFrom {
            scaleByGroupMasters(&rig)
            let progress = min(1, max(0, (now - restoreStart) / 0.3))
            rig = from.mixed(with: rig, progress * progress * (3 - 2 * progress))
            previewBlendActive = true
            if progress >= 1 { restoreFrom = nil }
        }
        return rig
    }

    /// Group order of every frame the engine renders (the classic layout until frames follow the patch layout).
    static let frameGroups = RigFrame.black.groups.map(\.id)

    private func rebuildMixLocked() {
        mix = GroupMix(ids: Self.frameGroups, masters: levels.masters, overrides: overrides)
    }

    /// Multiplies each group of `frame` by its master (preview restore blend).
    private func scaleByGroupMasters(_ frame: inout RigFrame) {
        for g in frame.groups.indices {
            frame.groups[g].light = frame.groups[g].light.scaled(mix.master(of: frame.groups[g].id, at: g))
        }
    }

    /// `groups[i]` is fixture i's position in `mix` (see `PatchCache`). The diagnostic ignores group
    /// masters and overrides; during the restore blend the frames already carry the group masters.
    private func compose(
        _ p: Patch, roles: [FixtureRole], groups: [Int], rig: RigFrame, diagnostic: Bool
    ) -> [PortAddress: [UInt8]] {
        // Apply white brightness after crossfades too, so zero always silences COBs immediately.
        let lv = roles.map { role in
            FixtureLevels(rgb: rig[role].rgb, cob: rig[role].cob.map { $0 * levels.whiteLevel })
        }
        let scales = groups.map { i in
            diagnostic ? master : mix.scale(group: i, master: master, groupMaster: !previewBlendActive)
        }
        return DMXComposer.compose(patch: p, library: baseLibrary, levels: lv, scales: scales, blackout: gate.blackout)
    }

    private func tick() {
        let now = clock()
        reopenSocketIfNeeded(now: now)
        perform(gate.expireDiagnostic(now: now))
        output.pollIfDue(now: now)
        // One tempo capture, one target and one readiness per frame: output, black frames and the
        // snapshot all describe the same instant.
        let t = tempo.capture()
        let beat = musicalBeat(t)
        var rig = rigFrame(now: now, beat: beat, tempo: t)
        let diagnostic = gate.isTesting
        // Colour overrides and flashes, after the scene and before the masters; blackout still wins.
        if !diagnostic { mix.apply(to: &rig) }

        var sending = false
        let target = output.target(now: now, patchUniverses: cache.universes)
        let readiness = readinessLocked(target: target)
        if gate.frame(ready: readiness == .ready).contains(.sendBlack) {
            // Stop transmitting until validation passes again, but retain the user's request.
            sendBlackFramesLocked(to: Self.blackFrameTarget(readiness, target))
        }
        let real = showsRealPatch ? compose(patch, roles: cache.roles, groups: cache.groups, rig: rig, diagnostic: diagnostic) : [:]
        if gate.armed, let target {
            sending = output.sendDMX(real, to: target)
            if sending { framesSent &+= 1 }
        }
        let shadowFrames = compose(
            shadow, roles: cache.shadowRoles, groups: cache.shadowGroups, rig: rig, diagnostic: diagnostic)
        let visuals = visualsLocked(real: real, shadow: shadowFrames, live: gate.armed && sending)
        publish(
            snapshotLocked(
                visuals: visuals, now: now, beat: beat, tempo: t, readiness: readiness, target: target, sending: sending))
    }

    /// Patch-derived data for the frame. Rebuilt by `rebuildPatchCacheLocked` when the patch or library changes.
    private struct PatchCache {
        /// One preview fixture, already in display order.
        struct Slot {
            var previewOnly: Bool
            var id: String
            var label: String
            var profileID: String
            var profile: FixtureProfile?
            var port: PortAddress?
            var role: FixtureRole
            var universe: Int
            var address: Int
        }
        var roles: [FixtureRole] = []
        var shadowRoles: [FixtureRole] = []
        /// Each fixture's group position in `frameGroups` (-1 for none), for the per-group arrays of `mix`.
        var groups: [Int] = []
        var shadowGroups: [Int] = []
        var universes: [PortAddress] = []
        /// Real fixtures (when the patch is shown), then shadow fixtures, sorted left, center, right.
        var slots: [Slot] = []
    }

    private func rebuildPatchCacheLocked() {
        var c = PatchCache()
        c.roles = patch.roles(library: baseLibrary)
        c.shadowRoles = shadow.roles(library: baseLibrary)
        c.groups = c.roles.map { Self.frameGroups.firstIndex(of: $0.groupID) ?? -1 }
        c.shadowGroups = c.shadowRoles.map { Self.frameGroups.firstIndex(of: $0.groupID) ?? -1 }
        c.universes = patch.universes
        func slots(_ p: Patch, roles: [FixtureRole], previewOnly: Bool) -> [PatchCache.Slot] {
            let lib = p.library(base: baseLibrary)
            return p.fixtures.enumerated().map { i, f in
                PatchCache.Slot(
                    previewOnly: previewOnly, id: previewOnly ? "preview-\(roles[i].rawValue)" : f.id.uuidString,
                    label: f.label, profileID: f.profileID, profile: lib.profile(id: f.profileID),
                    port: PortAddress(f.universe), role: roles[i], universe: f.universe, address: f.address)
            }
        }
        let all =
            (showsRealPatch ? slots(patch, roles: c.roles, previewOnly: false) : [])
            + slots(shadow, roles: c.shadowRoles, previewOnly: true)
        let order: [FixtureRole: Int] = [.left: 0, .center: 1, .right: 2]
        c.slots = all.enumerated().sorted {
            (order[$0.element.role]!, $0.offset) < (order[$1.element.role]!, $1.offset)
        }.map(\.element)
        cache = c
    }

    /// Preview fixtures decoded from the composed bytes: `real` for patched ones, `shadow` for the rest.
    private func visualsLocked(real: [PortAddress: [UInt8]], shadow: [PortAddress: [UInt8]], live: Bool) -> [FixtureVisual] {
        var visuals: [FixtureVisual] = []
        visuals.reserveCapacity(cache.slots.count)
        for slot in cache.slots {
            let frames = slot.previewOnly ? shadow : real
            let levels =
                slot.profile.flatMap { pr in
                    slot.port.flatMap { frames[$0] }.map { DMXComposer.decode(profile: pr, universe: $0, address: slot.address) }
                } ?? .off
            visuals.append(
                FixtureVisual(
                    id: slot.id, label: slot.label, profileID: slot.profileID, role: slot.role, universe: slot.universe,
                    address: slot.address, rgb: levels.rgb, cob: levels.cob,
                    status: slot.previewOnly ? .previewOnly : (live ? .live : .off)))
        }
        return visuals
    }

    /// Zero frames, three times. Only called when the gate disarms an armed output.
    private func sendBlackFramesLocked(to target: OutputTarget?) {
        guard let target else { return }
        let zeros = DMXComposer.compose(patch: patch, library: baseLibrary, levels: [], scales: [], blackout: true)
        for _ in 0..<3 { output.sendDMX(zeros, to: target) }
    }

    private func snapshotLocked(
        visuals: [FixtureVisual], now: TimeInterval, beat: Double, tempo t: TempoSnapshot,
        readiness: OutputReadiness, target: OutputTarget?, sending: Bool
    ) -> EngineSnapshot {
        var s = EngineSnapshot()
        s.scene = lastScene
        s.pendingScene = sequencer.pendingScene
        s.pendingSceneBank = sequencer.pendingSceneBank
        s.pendingIsDownbeat = sequencer.pendingIsDownbeat
        s.pendingProgress = sequencer.pendingProgress(beat: beat, now: now)
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
        s.accentActive = (accentOn || accentReleaseFrom != nil) && !gate.blackout
        s.blackout = gate.blackout
        s.armed = gate.armed
        s.outputRequested = gate.requested
        s.sending = sending
        s.framesSent = framesSent
        s.suspended = gate.suspended
        s.isTesting = gate.isTesting
        s.tempo = t
        s.gridTrusted = gridTrusted(t)
        s.readiness = readiness
        s.fixtures = visuals
        s.network = networkLocked(now: now, target: target)
        return s
    }

    /// Node lists and localized diagnosis are rebuilt every `networkRefreshInterval`, after user
    /// actions that change the selection, and as soon as a cheap field (target, selection, errors) changes.
    static let networkRefreshInterval: TimeInterval = 0.5

    private func networkLocked(now: TimeInterval, target: OutputTarget?) -> NetworkStatus {
        let elapsed = now - networkRefreshedAt
        let changed =
            network.target != target || network.selectedID != output.preferredIdentity
            || network.manualIP != output.manualIP || network.socketError != output.socketError
            || network.pollError != output.pollError || network.sendError != output.sendError
            || networkWasOpen != output.isOpen
        guard networkDirty || changed || !(0..<Self.networkRefreshInterval).contains(elapsed) else { return network }
        var net = NetworkStatus()
        net.nodes = output.nodes(now: now)
        net.selectedID = output.preferredIdentity
        net.manualIP = output.manualIP
        net.target = target
        net.interfaces = output.interfaces
        net.socketError = output.socketError
        net.pollError = output.pollError
        net.sendError = output.sendError
        net.diagnosis = output.diagnosis(now: now)
        network = net
        networkRefreshedAt = now
        networkWasOpen = output.isOpen
        networkDirty = false
        return net
    }

    private func publish(_ s: EngineSnapshot) {
        // This follows output intent, not window visibility. Keep it through outages,
        // blackout and Stop (which still transmit DMX), and release it when output is off.
        outputActivity.update(active: gate.running && (s.outputRequested || s.armed))
        onSnapshot?(s)
    }
}
