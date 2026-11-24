import Foundation

/// Scene changes, crossfades, rate changes and Stop on the musical grid. Pure value type:
/// the engine feeds it the (latency-compensated) Link beat each frame.
///
/// Robustness rules:
/// - With a trusted grid (Link peers or an external beat source) scenes start as their
///   `SceneTransition` says; without one they start on the press (no fake quantisation).
/// - Fades are measured in beats but always finish within `maxFadeSeconds` of wall time, and a
///   pending start never waits longer than `maxPendingSeconds`.
/// - A jump of the beat timeline (Link phase realignment, tempo source switch, sleep) shifts fades
///   by the jump and anchored phrases by whole bars, and re-quantises a pending start.
/// - Non-finite beats are replaced by the last valid beat; negative beats are fine.
/// - Custom looks (colours, warm white, program tracks) live in the layers: a fading-out scene keeps
///   its own look, Stop stays black. A layer without a look uses its original choreography.
public struct SceneSequencer: Sendable {
    public static let maxFadeSeconds: TimeInterval = 4
    public static let maxPendingSeconds: TimeInterval = 6
    public static let jumpThreshold = 0.5
    public static let rateFadeBeats = 1.0
    static let maxLayers = 4

    struct Layer: Equatable, Sendable {
        var scene: SceneID?  // nil = black (Stop)
        var rate: Double
        var anchor: Double  // phrase downbeat b0 (Link beats)
        var beatOrigin: Double? = nil  // explicit “scene beat 1”; nil preserves historical grid timing
        var fadeStart: Double  // Link beat at which the fade-in starts
        var fadeBeats: Double
        var startTime: TimeInterval  // wall clock at activation
        var maxSeconds: TimeInterval
        var lockedRate = false
        /// nil = original choreography; later pending looks must never change this layer.
        var look: SceneLook?
    }

    private var layers: [Layer]
    private var pendingLayer: Layer?
    private var pendingSince: TimeInterval = 0
    private var pendingRequestBeat = 0.0
    private var lastBeat: Double?
    private var lastTime: TimeInterval?
    private var lastBPM = 120.0
    public private(set) var rate: Double
    /// Look of the running scene and of the layers created from now on.
    public private(set) var look: SceneLook?

    /// Scene shown once all fades end (nil after Stop).
    public var targetScene: SceneID? { layers.last?.scene }
    /// Source of the layer currently playing, independent of any pending launch.
    public var currentSceneLook: CustomScene? { layers.last?.look?.source }
    /// The playing phrase anchor expressed in scene beats (after its movement rate).
    public var currentSceneBeatAnchor: Double? {
        guard let layer = layers.last, layer.scene != nil else { return nil }
        return (layer.anchor - (layer.beatOrigin ?? 0)) * layer.rate
    }
    public var pendingScene: SceneID? { pendingLayer?.scene }
    public var pendingSceneBank: SceneBank? {
        guard let pending = pendingLayer else { return nil }
        guard let source = pending.look?.source else { return .house }
        return source.presetSlot == nil ? nil : source.presetBank
    }
    public var isRateLocked: Bool { pendingLayer?.lockedRate ?? layers.last?.lockedRate ?? false }
    /// Pending start waits for a downbeat (anchored scene) rather than the next beat.
    public var pendingIsDownbeat: Bool {
        if case .downbeat = pendingLayer?.scene?.transition.start { return true }
        return false
    }
    public var isStopped: Bool { pendingLayer == nil && layers.last?.scene == nil }
    /// How far a queued launch is towards its start, from 0 (just pressed) to 1 (starting now):
    /// beats on the grid, or the wall-clock limit `maxPendingSeconds` when that comes first.
    /// nil when nothing is queued. Drives the countdown ring on the scene buttons.
    public func pendingProgress(beat rawBeat: Double, now: TimeInterval) -> Double? {
        guard let pending = pendingLayer else { return nil }
        let beat = rawBeat.isFinite ? rawBeat : (lastBeat ?? pendingRequestBeat)
        let span = pending.fadeStart - pendingRequestBeat
        let byBeat = span > 1e-9 ? (beat - pendingRequestBeat) / span : 1
        let byTime = (now - pendingSince) / Self.maxPendingSeconds
        let p = max(byBeat, byTime)
        return p.isFinite ? min(1, max(0, p)) : 1
    }
    /// True while a fade to black from Stop is still running.
    public func isStopFading(beat: Double, now: TimeInterval) -> Bool {
        guard let last = layers.last, last.scene == nil, layers.count > 1 else { return false }
        return progress(last, beat: beat, now: now) < 1
    }

    public init(scene: SceneID = .ambra, rate: Double = 1) {
        self.rate = Self.validRate(rate)
        layers = [
            Layer(
                scene: scene, rate: self.rate, anchor: 0, fadeStart: -.infinity, fadeBeats: 0,
                startTime: -.infinity, maxSeconds: 0)
        ]
    }

    static func validRate(_ r: Double) -> Double { r.isFinite && r > 0 ? min(max(r, 0.125), 4) : 1 }

    // MARK: Commands

    /// Only removes a queued launch. Running layers, fades, rate and clock anchors stay intact.
    @discardableResult
    public mutating func cancelPendingScene() -> Bool {
        guard pendingLayer != nil else { return false }
        pendingLayer = nil
        look = layers.last?.look
        return true
    }

    public mutating func request(
        _ scene: SceneID, beat rawBeat: Double, now: TimeInterval, gridTrusted: Bool, rateOverride: Double? = nil,
        forceRestart: Bool = false
    ) {
        _ = startLayer(scene, beat: rawBeat, now: now, gridTrusted: gridTrusted, rateOverride: rateOverride, forceRestart: forceRestart)
    }

    /// Changing bank is a new launch even when two banks share the same slot.
    /// Live edits within the bank still update the current look without restarting it.
    public mutating func request(
        _ scene: SceneID, look newLook: SceneLook?, beat rawBeat: Double, now: TimeInterval, gridTrusted: Bool,
        rateOverride: Double? = nil, forceRestart: Bool = false
    ) {
        let changedBank = (look?.source.presetBank ?? .house) != (newLook?.source.presetBank ?? .house)
        look = newLook
        if !startLayer(
            scene, beat: rawBeat, now: now, gridTrusted: gridTrusted, rateOverride: rateOverride, forceRestart: forceRestart || changedBank)
        {
            setLook(newLook)
        }
    }

    /// Changes the look of the running (and pending) scene and of later layers. Fading-out layers
    /// keep theirs and Stop stays black.
    public mutating func setLook(_ newLook: SceneLook?) {
        look = newLook
        if pendingLayer != nil { pendingLayer?.look = newLook }
        if let i = layers.indices.last, layers[i].scene != nil { layers[i].look = newLook }
    }

    /// Returns true when a new (pending or active) layer was created.
    private mutating func startLayer(
        _ scene: SceneID, beat rawBeat: Double, now: TimeInterval, gridTrusted: Bool, rateOverride: Double?, forceRestart: Bool
    ) -> Bool {
        let beat = sanitize(rawBeat)
        if !forceRestart && pendingLayer?.scene == scene { return false }
        if !forceRestart, pendingLayer != nil, targetScene == scene {
            pendingLayer = nil  // pressing the running scene again cancels a pending change
            return false
        }
        // Re-pressing a running phrase scene re-arms its phrase on the next downbeat.
        if !forceRestart, pendingLayer == nil, targetScene == scene, !isAnchored(scene) { return false }
        let layer = makeLayer(scene, beat: beat, now: now, gridTrusted: gridTrusted, rateOverride: rateOverride)
        if layer.fadeStart > beat + 1e-9 {
            pendingLayer = layer
            pendingSince = now
            pendingRequestBeat = beat
        } else {
            pendingLayer = nil
            push(layer)
        }
        return true
    }

    /// Fades everything to black over one beat (0.5 s without a trusted grid) and clears the scene.
    public mutating func stop(beat rawBeat: Double, now: TimeInterval, gridTrusted: Bool) {
        let beat = sanitize(rawBeat)
        pendingLayer = nil
        guard !isStopped else { return }
        push(
            Layer(
                scene: nil, rate: rate, anchor: beat, fadeStart: beat, fadeBeats: 1, startTime: now,
                maxSeconds: gridTrusted ? Self.maxFadeSeconds : 0.5))
    }

    /// Explicit user alignment: restart the running scene's complete cycle (not just a bar).
    /// A stopped scene stays stopped; outgoing layers, pending launches, fades and rate locks keep
    /// their state. This is runtime phase only: it never changes a stored scene or shared Link.
    public mutating func restartCurrentScene(at beat: Double) {
        guard beat.isFinite, let i = layers.indices.last, layers[i].scene != nil else { return }
        layers[i].beatOrigin = beat
        layers[i].anchor = beat
    }

    /// Rate changes crossfade over one beat; both rates stay phase-locked to the grid.
    public mutating func setRate(_ newRate: Double, beat rawBeat: Double, now: TimeInterval) {
        let r = Self.validRate(newRate)
        guard r != rate || layers.last?.rate != r else { return }
        rate = r
        let beat = sanitize(rawBeat)
        if pendingLayer?.lockedRate != true { pendingLayer?.rate = r }
        guard var current = layers.last, current.scene != nil, !current.lockedRate else { return }
        current.rate = r
        current.fadeStart = beat
        current.fadeBeats = Self.rateFadeBeats
        current.startTime = now
        current.maxSeconds = Self.maxFadeSeconds
        push(current)
    }

    // MARK: Frame

    /// Call once per frame before `render`.
    public mutating func advance(beat rawBeat: Double, bpm: Double, now: TimeInterval, gridTrusted: Bool) {
        let beat = sanitize(rawBeat)
        let tempo = bpm.isFinite && bpm > 0 ? bpm : lastBPM
        if let lb = lastBeat, let lt = lastTime {
            let expected = lb + max(0, now - lt) * lastBPM / 60
            let jump = beat - expected
            if abs(jump) > Self.jumpThreshold { shift(by: jump, beat: beat, now: now, gridTrusted: gridTrusted) }
        }
        lastBeat = beat
        lastTime = now
        lastBPM = tempo

        if var pending = pendingLayer {
            if beat >= pending.fadeStart {
                pending.startTime = now
                pendingLayer = nil
                push(pending)
            } else if now - pendingSince > Self.maxPendingSeconds {
                pendingLayer = nil
                var late = makeLayer(
                    pending.scene ?? .ambra, beat: beat, now: now, gridTrusted: false, rateOverride: pending.lockedRate ? pending.rate : nil
                )
                late.look = pending.look
                push(late)
            }
        }
        // Drop layers completely covered by a finished fade above them.
        if let top = layers.indices.last(where: { $0 > 0 && progress(layers[$0], beat: beat, now: now) >= 1 }) {
            layers.removeFirst(top)
        }
    }

    /// The frame on the classic rig.
    public func render(beat rawBeat: Double, energy: Double, now: TimeInterval) -> RigFrame {
        render(beat: rawBeat, energy: energy, now: now, rig: .classic)
    }

    /// The frame on `rig` (ADR 0005): every layer is fitted to the rig's groups before the crossfade, so
    /// layers always mix group by group. On the classic rig a classic frame is used as it is.
    public func render(beat rawBeat: Double, energy: Double, now: TimeInterval, rig: SpatialRig) -> RigFrame {
        let beat = rawBeat.isFinite ? rawBeat : (lastBeat ?? 0)
        var out: RigFrame?
        for layer in layers {
            let frame =
                layer.scene.map { scene -> RigFrame in
                    let ctx = context(layer, beat: beat, energy: energy)
                    guard let look = layer.look else { return rig.fitting(Choreography.render(scene, ctx)) }
                    return rig.fitting(look.render(scene, ctx))
                } ?? rig.black
            if let base = out {
                let t = Choreography.s(progress(layer, beat: beat, now: now))
                out = base.mixed(with: frame, t)
            } else {
                out = frame
            }
        }
        return (out ?? rig.black).sanitized
    }

    /// Compiles every look again for `rig` after a patch or layout change (never per frame). Looks already
    /// compiled for it are kept as they are.
    public mutating func retarget(_ rig: SpatialRig) {
        func moved(_ look: SceneLook?) -> SceneLook? {
            guard let look, look.rig != rig else { return look }
            return SceneLook(look.source, rig: rig)
        }
        look = moved(look)
        for i in layers.indices { layers[i].look = moved(layers[i].look) }
        if pendingLayer != nil { pendingLayer?.look = moved(pendingLayer?.look) }
    }

    /// Pattern time (scene beats, as the program tracks see it) of the running scene; nil after Stop.
    public func patternBeat(beat rawBeat: Double) -> Double? {
        guard let layer = layers.last, let scene = layer.scene else { return nil }
        let beat = rawBeat.isFinite ? rawBeat : (lastBeat ?? 0)
        return SceneLook.patternTime(scene, context(layer, beat: beat, energy: 0))
    }

    // MARK: Internals

    func isAnchored(_ scene: SceneID) -> Bool {
        scene == .aurora || scene == .respiro
    }

    private func makeLayer(_ scene: SceneID, beat: Double, now: TimeInterval, gridTrusted: Bool, rateOverride: Double? = nil) -> Layer {
        let tr = scene.transition
        var fadeStart = beat, anchor = beat + tr.fadeBeats
        if gridTrusted {
            switch tr.start {
            case .immediate: break
            case .nextBeat: fadeStart = floor(beat) + 1
            case .downbeat(let lead):
                // A DJ releasing Build on the downbeat must not wait another bar.
                let phase = pmod(beat, 4)
                anchor = scene == .respiro && phase < 0.30 ? 4 * floor(beat / 4) : 4 * ceil((beat + lead) / 4)
                fadeStart = anchor - tr.fadeBeats
            }
        }
        return Layer(
            scene: scene, rate: Self.validRate(rateOverride ?? rate), anchor: anchor, fadeStart: fadeStart, fadeBeats: tr.fadeBeats,
            startTime: now, maxSeconds: Self.maxFadeSeconds, lockedRate: rateOverride != nil, look: look)
    }

    private mutating func push(_ layer: Layer) {
        layers.append(layer)
        if layers.count > Self.maxLayers { layers.removeFirst(layers.count - Self.maxLayers) }
    }

    private mutating func shift(by jump: Double, beat: Double, now: TimeInterval, gridTrusted: Bool) {
        let bars = 4 * (jump / 4).rounded()
        for i in layers.indices {
            if layers[i].fadeStart.isFinite { layers[i].fadeStart += jump }
            layers[i].anchor += bars
            if let origin = layers[i].beatOrigin { layers[i].beatOrigin = origin + bars }
        }
        if let pending = pendingLayer, let scene = pending.scene {
            pendingLayer = makeLayer(
                scene, beat: beat, now: now, gridTrusted: gridTrusted, rateOverride: pending.lockedRate ? pending.rate : nil)
            pendingLayer?.look = pending.look
            pendingRequestBeat = beat
            if pendingLayer!.fadeStart <= beat {
                push(pendingLayer!)
                pendingLayer = nil
            }
        }
    }

    func progress(_ layer: Layer, beat: Double, now: TimeInterval) -> Double {
        guard layer.fadeStart.isFinite else { return 1 }
        let byBeat = layer.fadeBeats > 0 ? (beat - layer.fadeStart) / layer.fadeBeats : 1
        let byTime = layer.maxSeconds > 0 ? (now - layer.startTime) / layer.maxSeconds : 1
        let p = max(byBeat, byTime)
        return p.isFinite ? clamp01(p) : 1
    }

    private func context(_ layer: Layer, beat: Double, energy: Double) -> SceneContext {
        SceneContext(
            beat: (beat - (layer.beatOrigin ?? 0)) * layer.rate, phrase: (beat - layer.anchor) * layer.rate, energy: energy,
            minAttack: 0.06 * layer.rate)
    }

    private func sanitize(_ beat: Double) -> Double { beat.isFinite ? beat : (lastBeat ?? 0) }
}
