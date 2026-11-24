import Foundation

/// A custom scene prepared once for the 30 Hz path: palette map, warm-white amount and the compiled
/// program. Sequencer layers carry it, so crossfades and Stop treat the tracks like any choreography.
/// Rendering is a pure function of the musical context.
public struct SceneLook: Equatable, Sendable {
    public let source: CustomScene
    /// Where the program's emitters sit on the stage; fixed for the life of the look.
    public let rig: SpatialRig
    let remap: CustomPaletteMap
    let keepColors: Bool
    let warmth: Double
    let program: CompiledProgram?

    /// The look on the classic rig.
    public init(_ scene: CustomScene) { self.init(scene, rig: .classic) }

    /// The look on `rig`: spatial targets are resolved here, once, never per frame.
    public init(_ scene: CustomScene, rig: SpatialRig) {
        let clean = scene.sanitized
        source = clean
        self.rig = rig
        remap = clean.paletteMap
        keepColors = clean.usesBaseColors
        warmth = clean.warmCOB(1)
        program = clean.program.map { CompiledProgram($0, palette: clean.palette, rig: rig) }
    }

    public static func == (a: SceneLook, b: SceneLook) -> Bool { a.source == b.source && a.rig == b.rig }

    public var id: UUID { source.id }

    /// Base choreography, recoloured, then the program tracks; warm white amount applied last.
    /// Without a program this equals `CustomScene.applyingLook(to: Choreography.render(...))`.
    public func render(_ scene: SceneID, _ ctx: SceneContext) -> RigFrame {
        guard let program else { return apply(to: Choreography.render(scene, ctx)) }
        var frame: RigFrame
        if program.baseLevel > 0 {
            frame = recolored(Choreography.render(scene, ctx))
            if program.baseLevel < 1 { frame = frame.scaled(program.baseLevel) }
        } else {
            frame = rig.black
        }
        program.render(into: &frame, scene: scene, ctx)
        return finish(frame)
    }

    /// The historical custom-look transform (colours and warm white only).
    public func apply(to frame: RigFrame) -> RigFrame { finish(recolored(frame)) }

    private func recolored(_ frame: RigFrame) -> RigFrame {
        guard !keepColors else { return frame }
        var out = frame
        for i in out.groups.indices { out.groups[i].light.rgb = frame.groups[i].light.rgb.map(remap.apply) }
        return out
    }

    private func finish(_ frame: RigFrame) -> RigFrame {
        var out = frame
        for i in out.groups.indices { out.groups[i].light.cob = frame.groups[i].light.cob.map { clamp01($0) * warmth } }
        return out.sanitized
    }

    /// Pattern time of a scene in scene beats: Drop counts from its anchored downbeat, the others from the grid.
    public static func patternTime(_ scene: SceneID, _ ctx: SceneContext) -> Double {
        let t = scene == .respiro ? ctx.phrase : ctx.beat
        return t.isFinite ? t : 0
    }
}

/// Program flattened into fixed arrays: no lookups or allocations per frame beyond the output frame.
struct CompiledProgram: Sendable {
    /// One light emitter a track can drive.
    struct Unit: Sendable {
        /// Index of the group in the rig (and in the frame, when the frame follows the rig's layout).
        var group: Int
        var id: RigGroupID
        var cob: Bool
        var index: Int
        /// Delay of this unit in beats (spread × position rank).
        var delay: Double
        /// Alternate group: 0, 1, or 2 = both halves (odd middle position).
        var half: Int
        /// Chase position.
        var slot: Int
    }

    struct Hit: Sendable {
        /// Within the cycle, beats.
        var time: Double
        /// 0…1.
        var level: Double
        var soft: Bool
        /// Index among the active steps.
        var rank: Int
    }

    struct Track: Sendable {
        var units: [Unit]
        var hits: [Hit]
        var cycle: Double
        var slotCount: Int
        var bounce: Bool
        var motion: TrackMotion
        var offset: Double
        var attack: Double, hold: Double, release: Double
        var floor: Double, peak: Double
        /// One entry, or three for `.cycle`.
        var colors: [LightColor]
        var add: Bool
        var softFollowsEnergy: Bool
        var rise: Double
    }

    let baseLevel: Double
    let tracks: [Track]

    /// Emitter positions come from `rig` (`SpatialRig`), computed once per layout.
    init(_ program: SceneProgram, palette: [LightColor], rig: SpatialRig) {
        let p = program.sanitized
        baseLevel = p.baseLevel
        let pal = palette.count >= 3 ? palette : palette + Array(repeating: LightColor(1, 1, 1), count: 3 - palette.count)
        tracks = p.tracks.compactMap { Self.compile($0, palette: pal, rig: rig) }
    }

    private static func compile(_ t: ProgramTrack, palette: [LightColor], rig: SpatialRig) -> Track? {
        guard t.enabled, !t.target.isEmpty else { return nil }
        let target = t.target
        let picked = rig.picks(target.selection)
        func selected(_ e: StageEmitter) -> Bool {
            guard e.cob ? target.warm : target.color, picked[e.group] else { return false }
            return target.allows(rig.groups[e.group].id, index: e.index, cob: e.cob)
        }
        // Left → right across the stage, RGB then COB.
        let raw = rig.rgb.filter(selected) + rig.cob.filter(selected)
        guard !raw.isEmpty else { return nil }

        // Ordering key per direction; equal keys share a position (e.g. "from the centre": both sides together).
        func key(_ x: Double) -> Double {
            switch t.direction {
            case .forward, .bounce: return x
            case .backward: return 1 - x
            case .center: return abs(x - 0.5)
            }
        }
        var keys: [Double] = []
        for k in raw.map({ key($0.x) }).sorted() where !keys.contains(where: { abs($0 - k) < 1e-6 }) { keys.append(k) }
        let positions = keys.count
        let units = raw.map { e -> Unit in
            let rank = keys.firstIndex { abs($0 - key(e.x)) < 1e-6 } ?? 0
            let half: Int
            if positions == 1 || (positions % 2 == 1 && rank == positions / 2) {
                half = 2
            } else {
                half = rank < (positions + 1) / 2 ? 0 : 1
            }
            return Unit(
                group: e.group, id: rig.groups[e.group].id, cob: e.cob, index: e.index, delay: t.spread * Double(rank),
                half: half, slot: rank)
        }

        let res = Double(t.stepsPerBeat)
        var hits: [Hit] = []
        for (i, v) in t.steps.enumerated() where v > 0 {
            hits.append(Hit(time: Double(i) / res, level: v, soft: v < 0.999, rank: hits.count))
        }
        let colors: [LightColor]
        switch t.color {
        case .first: colors = [palette[0]]
        case .second: colors = [palette[1]]
        case .third: colors = [palette[2]]
        case .cycle: colors = Array(palette.prefix(3))
        }
        return Track(
            units: units, hits: hits, cycle: Double(t.lengthBeats), slotCount: positions,
            bounce: t.direction == .bounce, motion: t.motion, offset: t.offset,
            attack: t.attack, hold: t.hold, release: max(0.02, t.release),
            floor: t.floor, peak: t.peak, colors: colors, add: t.blend == .add,
            softFollowsEnergy: t.softFollowsEnergy, rise: Double(t.riseBeats))
    }

    /// Envelope of one hit at relative time x (beats, 0 = the hit): attack ends on the hit, then hold and release.
    @inline(__always) static func envelope(_ x: Double, attack a: Double, hold: Double, release r: Double) -> Double {
        if x < 0 { return x <= -a ? 0 : Choreography.s((x + a) / a) }
        if x <= hold { return 1 }
        let y = (x - hold) / r
        return y >= 1 ? 0 : 1 - Choreography.s(y)
    }

    func render(into frame: inout RigFrame, scene: SceneID, _ ctx: SceneContext) {
        let time = SceneLook.patternTime(scene, ctx)
        let energy = clamp01(ctx.energy)
        let minAttack = max(0.02, ctx.minAttack.isFinite ? ctx.minAttack : 0.06)
        let phrase = ctx.phrase.isFinite ? ctx.phrase : 0
        // Drop keeps its identity: dark dip before the anchored downbeat, tracks from the impact on.
        var gate = 1.0
        if scene == .respiro && phrase < 0 {
            let a = max(0.06, minAttack)
            gate = phrase < -a ? 0 : Choreography.s((phrase + a) / a)
        }
        guard gate > 0 else { return }
        for track in tracks {
            let a = max(track.attack, minAttack)
            var gain = gate
            if track.rise > 0 { gain *= 0.25 + 0.75 * Choreography.s(max(0, phrase) / track.rise) }
            for unit in track.units {
                let (level, colorIndex) = Self.level(track, unit, time: time, attack: a, energy: energy)
                let value = (track.floor + (track.peak - track.floor) * level) * gain
                guard value > 0 else { continue }
                // Element paths mutate in place; a frame in another group order is matched by id.
                if unit.group < frame.groups.count && frame.groups[unit.group].id == unit.id {
                    Self.blend(&frame.groups[unit.group].light, unit, value, track, colorIndex)
                } else if let g = frame.index(of: unit.id) {
                    Self.blend(&frame.groups[g].light, unit, value, track, colorIndex)
                }
            }
        }
    }

    @inline(__always) static func blend(_ role: inout RoleFrame, _ unit: Unit, _ value: Double, _ track: Track, _ colorIndex: Int) {
        if unit.cob {
            guard unit.index < role.cob.count else { return }
            let old = role.cob[unit.index]
            role.cob[unit.index] = track.add ? min(1, old + value) : max(old, value)
        } else {
            guard unit.index < role.rgb.count else { return }
            let c = Choreography.lit(track.colors[colorIndex], value)
            let old = role.rgb[unit.index]
            role.rgb[unit.index] = track.add
                ? LightColor(min(1, old.r + c.r), min(1, old.g + c.g), min(1, old.b + c.b), old.w)
                : LightColor(max(old.r, c.r), max(old.g, c.g), max(old.b, c.b), old.w)
        }
    }

    /// Strongest envelope among the hits that reach this unit now, with the colour of that hit.
    static func level(_ track: Track, _ unit: Unit, time: Double, attack a: Double, energy: Double) -> (Double, Int) {
        guard !track.hits.isEmpty, track.cycle > 0 else { return (0, 0) }
        let u = time - track.offset - unit.delay
        let count = track.hits.count
        let tail = track.hold + track.release
        var best = 0.0, bestColor = 0
        for hit in track.hits {
            // Occurrences h = hit.time + cycle·m within [u − tail, u + a].
            let lo = ((u - tail - hit.time) / track.cycle).rounded(.up)
            let hi = ((u + a - hit.time) / track.cycle).rounded(.down)
            guard lo.isFinite, hi.isFinite, hi >= lo else { continue }
            var m = lo
            var guardCount = 0
            while m <= hi && guardCount < 24 {
                defer { m += 1; guardCount += 1 }
                let n = Int(m.magnitude < 1e15 ? m : 0) * count + hit.rank
                guard fires(track, unit, hit: n) else { continue }
                let level = hit.soft ? (track.softFollowsEnergy ? hit.level * energy : hit.level) : 1
                let env = envelope(u - (hit.time + m * track.cycle), attack: a, hold: track.hold, release: track.release) * level
                if env > best { best = env; bestColor = track.colors.count > 1 ? pmodInt(n, track.colors.count) : 0 }
            }
        }
        return (best, bestColor)
    }

    @inline(__always) static func fires(_ track: Track, _ unit: Unit, hit n: Int) -> Bool {
        switch track.motion {
        case .together: return true
        case .alternate: return unit.half == 2 || unit.half == pmodInt(n, 2)
        case .chase:
            let k = track.slotCount
            guard k > 1 else { return true }
            if track.bounce {
                let period = 2 * k - 2
                let p = pmodInt(n, period)
                return unit.slot == (p < k ? p : period - p)
            }
            return unit.slot == pmodInt(n, k)
        }
    }

    @inline(__always) static func pmodInt(_ a: Int, _ m: Int) -> Int { let r = a % m; return r < 0 ? r + m : r }
}
