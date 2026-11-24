import Foundation

/// Light for one stage role before subs/master: RGB pixel groups (w unused) and warm COBs, 0...1.
public struct RoleFrame: Equatable, Sendable {
    public var rgb: [LightColor]
    public var cob: [Double]

    public init(rgb: [LightColor], cob: [Double]) { self.rgb = rgb; self.cob = cob }

    public static func black(rgb: Int, cob: Int) -> RoleFrame {
        RoleFrame(rgb: Array(repeating: .black, count: rgb), cob: Array(repeating: 0, count: cob))
    }

    public func mixed(with o: RoleFrame, _ t: Double) -> RoleFrame {
        RoleFrame(
            rgb: zip(rgb, o.rgb).map { $0.mixed(with: $1, t) },
            cob: zip(cob, o.cob).map { $0 + ($1 - $0) * clamp01(t) })
    }

    public func scaled(_ k: Double) -> RoleFrame {
        RoleFrame(rgb: rgb.map { $0.scaled(k) }, cob: cob.map { clamp01($0 * k) })
    }

    public var isFinite: Bool { rgb.allSatisfy(\.isFinite) && cob.allSatisfy(\.isFinite) }
}

/// Inputs of one scene evaluation. Times are in *scene beats* (Link beats × rate).
public struct SceneContext: Equatable, Sendable {
    /// Free-running scene time (Link beat × rate), used by the unanchored scenes.
    public var beat: Double
    /// Phrase time since the anchored downbeat b0 ((Link beat − b0) × rate); may be negative.
    public var phrase: Double
    /// Smoothed energy 0...1.
    public var energy: Double
    /// Shortest allowed attack in scene beats (0.06 Link beats × rate).
    public var minAttack: Double

    public init(beat: Double, phrase: Double = 0, energy: Double, minAttack: Double = 0.06) {
        self.beat = beat; self.phrase = phrase; self.energy = energy; self.minAttack = minAttack
    }
}

/// The six House scenes, implemented as pure
/// deterministic functions of musical time. No strobe channel, no fixture programs, no guessing
/// of the track structure: every phrase is counted from the Link grid or from the press.
///
/// Deliberate, documented adaptations of the spec formulas:
/// - Pulse: the hit time is `b − x + a` (the peak), so the edge rotates on beat 8 as the spec's tests require.
/// - Tramonto: the vertical gradient offset is clamped at 0 so the top never wraps into indigo.
/// - Build/Drop (hold gesture): Build counts its rise from the press and holds at the peak instead
///   of looping; Drop darkens during its quantised fade and hits on the anchored downbeat.
public enum Choreography {
    /// Full-scale scene COB peaks; the user white fader and global master set the actual output ceiling.
    public static let centerCOBCap = 1.0
    public static let sideCOBCap = 1.0

    static let tau = 2 * Double.pi

    public static func render(_ scene: SceneID, _ ctx: SceneContext) -> RigFrame {
        let c = Ctx(ctx)
        var frame: RigFrame
        switch scene {
        case .ambra: frame = ambra(c)
        case .sunset: frame = sunset(c)
        case .pulse: frame = pulse(c)
        case .chase: frame = chase(c)
        case .aurora: frame = aurora(c)
        case .respiro: frame = respiro(c)
        }
        // Reference crest per role, independent of Energy. These gains depend only on the
        // chosen pattern/energy, never on the current frame, so troughs and black dips stay intact.
        let gains: (center: Double, side: Double)
        switch scene {
        case .ambra:
            gains = (1 / ((0.72 + 0.16 * c.e) * (0.80 + 0.20 * cos(.pi / 6))), 1 / 0.70)
        case .sunset: gains = (1 / 0.8011, 1 / (0.48 + 0.27 * c.e))
        case .pulse: gains = (1, 1 / 0.82)
        default: gains = (1, 1)
        }
        frame.center.rgb = frame.center.rgb.map { $0.scaled(gains.center) }
        frame.left.rgb = frame.left.rgb.map { $0.scaled(gains.side) }
        frame.right.rgb = frame.right.rgb.map { $0.scaled(gains.side) }
        frame = frame.sanitized
        frame.center.cob = frame.center.cob.map { min($0, centerCOBCap) }
        frame.left.cob = frame.left.cob.map { min($0, sideCOBCap) }
        frame.right.cob = frame.right.cob.map { min($0, sideCOBCap) }
        return frame
    }

    // MARK: Helpers (names follow the spec)

    struct Ctx {
        let b: Double, rd: Double, e: Double, minAttack: Double
        init(_ c: SceneContext) {
            b = c.beat.isFinite ? c.beat : 0
            rd = c.phrase.isFinite ? c.phrase : 0
            e = clamp01(c.energy)
            minAttack = max(0.02, c.minAttack.isFinite ? c.minAttack : 0.06)
        }
        /// Brightness belongs to the output master; Energy only shapes the choreography.
        var lvl: Double { 1 }
        func w(_ a: Double, _ c: Double) -> Double { Choreography.sstep(a, c, e) }
        /// Rounded pulse peaking exactly at t = o (mod P).
        func on(_ t: Double, _ o: Double, _ p: Double, _ a: Double, _ d: Double) -> Double {
            let a = min(max(a, minAttack), p / 2)
            return Choreography.env(pmod(t - o + a, p), a, d)
        }
    }

    static func s(_ t: Double) -> Double { let c = clamp01(t); return c * c * (3 - 2 * c) }
    static func sstep(_ a: Double, _ c: Double, _ x: Double) -> Double { s((x - a) / (c - a)) }
    static func fract(_ x: Double) -> Double { pmod(x, 1) }
    static func tri(_ t: Double) -> Double { 1 - abs(2 * fract(t) - 1) }
    static func cd(_ a: Double, _ b: Double, _ n: Double) -> Double { min(pmod(a - b, n), pmod(b - a, n)) }
    static func bump(_ d: Double, _ wd: Double) -> Double { d < wd ? 0.5 + 0.5 * cos(Double.pi * d / wd) : 0 }
    static func env(_ x: Double, _ a: Double, _ d: Double) -> Double { x < a ? s(x / a) : exp(-d * (x - a)) }

    /// Cyclic smooth palette.
    static func pal(_ p: [LightColor], _ t: Double) -> LightColor {
        let n = p.count
        let x = fract(t) * Double(n)
        let j = min(Int(x), n - 1)
        return p[j].mixed(with: p[(j + 1) % n], s(x - Double(j)))
    }

    /// Non-cyclic palette, t clamped to 0...1.
    static func pallin(_ p: [LightColor], _ t: Double) -> LightColor {
        let x = clamp01(t) * Double(p.count - 1)
        let j = min(Int(x), p.count - 2)
        return p[j].mixed(with: p[j + 1], s(x - Double(j)))
    }

    static func lit(_ c: LightColor, _ i: Double) -> LightColor {
        // Palette chooses hue/saturation; its HSV value must not secretly dim the master.
        let peak = c.peak
        guard peak.isFinite, peak > 1e-9 else { return .black }
        let level = clamp01(i)
        return LightColor(c.r / peak * level, c.g / peak * level, c.b / peak * level)
    }

    static func side(_ c: LightColor, _ i: Double, cob: Double) -> RoleFrame {
        RoleFrame(rgb: [lit(c, i)], cob: [cob])
    }

    // MARK: Scenes

    /// Ambra (house): slow clockwise warm gradient, 8-beat breath, sides breathe 2 beats behind.
    static func ambra(_ c: Ctx) -> RigFrame {
        let p = SceneID.ambra.palette, b = c.b, e = c.e
        let br = 0.5 - 0.5 * cos(tau * b / 8)
        let brS = 0.5 - 0.5 * cos(tau * (b - 2) / 8)
        let kick = c.on(b, 0, 1, 0.15, 3.0)
        let rgb = (0..<6).map { i -> LightColor in
            let x = Double(i) / 6
            let level = c.lvl * (0.50 + 0.22 * br + 0.16 * e * kick) * (0.80 + 0.20 * cos(tau * (b / 16 - x)))
            return lit(pal(p, b / 32 + x), level)
        }
        let cob = (0..<3).map { k -> Double in
            let wave = 0.5 + 0.5 * cos(tau * (b / 16 - Double(k) / 3))
            return wave * wave
        }
        let sideC = pal(p, b / 32 + 0.5), sideI = c.lvl * (0.45 + 0.25 * brS)
        let sideCob = brS
        return RigFrame(
            left: side(sideC, sideI, cob: sideCob), center: RoleFrame(rgb: rgb, cob: cob),
            right: side(sideC, sideI, cob: sideCob))
    }

    /// Tramonto (house): vertical dusk gradient, kick strongest at the bottom, offbeat side swell.
    static func sunset(_ c: Ctx) -> RigFrame {
        let p = SceneID.sunset.palette, b = c.b, e = c.e
        let rowT: [Double] = [0, 0.33, 0.67, 0.67, 0.33, 0]
        let kick = c.on(b, 0, 1, 0.12, 4.0)
        let oh = c.on(b, 0.5, 1, 0.15, 3.2)
        let ep = 1.0
        let rgb = (0..<6).map { i in
            lit(pal(p, max(0, 0.75 * rowT[i] + 0.08 * sin(tau * b / 32))), c.lvl * (0.40 + kick * (0.18 + 0.33 * rowT[i])))
        }
        let kb = pmod(floor(b / 4), 2) == 0 ? 2 : 0
        var cob = [0.0, 0.0, 0.0]
        cob[1] = 1.0 * ep * c.on(b, 0, 4, 0.15, 1.8)
        cob[kb] = 0.80 * ep * c.on(b, 2, 4, 0.15, 2.2)
        let sideC = p[1].mixed(with: p[2], 0.5 - 0.5 * cos(tau * b / 16))
        let sideI = c.lvl * (0.30 + 0.45 * oh * (0.4 + 0.6 * e))
        let sideCob = 1.0 * c.on(b, 3.5, 8, 0.2, 2.5)
        return RigFrame(
            left: side(sideC, sideI, cob: sideCob), center: RoleFrame(rgb: rgb, cob: cob),
            right: side(sideC, sideI, cob: sideCob))
    }

    /// Pulse (tech house): 3+3+2 hits, one centre edge each, rotating clockwise every 8 beats.
    static func pulse(_ c: Ctx) -> RigFrame {
        let p = SceneID.pulse.palette, b = c.b
        let uv = p[0], teal = p[1], ice = p[2], ember = p[3]
        let a = max(0.1, c.minAttack)
        let offsets = [0.0, 1.5, 3.0]
        let x = offsets.map { pmod(b - $0 + a, 4) }
        let j = x.indices.min { x[$0] < x[$1] } ?? 0
        let h = env(x[j], a, 4.5)
        let hitPeak = b - x[j] + a
        let edge = Int(pmod(Double(j) + floor((hitPeak + 0.01) / 8), 3))
        let oh = c.on(b, 0.5, 1, 0.1, 5.0)
        let emb = 0.6 * c.w(0.3, 0.7) * c.on(b, 7.5, 8, 0.15, 3.0)
        let rgb = (0..<6).map { i -> LightColor in
            let active = i / 2 == edge
            let base = active ? (i % 2 == 0 ? ice : teal) : uv
            return lit(base.mixed(with: ember, emb), active ? c.lvl * (0.25 + 0.75 * h) : c.lvl * (0.16 + 0.10 * h))
        }
        var cob = [0.0, 0.0, 0.0]
        if j == 0 { cob[edge] = 1.0 * env(x[0], a, 3.0) }
        let sideC = teal.mixed(with: ice, oh), sideI = c.lvl * (0.12 + 0.70 * oh)
        let sideCob = 1.0 * c.on(b, 7.5, 8, 0.15, 2.5)
        return RigFrame(
            left: side(sideC, sideI, cob: sideCob), center: RoleFrame(rgb: rgb, cob: cob),
            right: side(sideC, sideI, cob: sideCob))
    }

    /// Chase (tech house): eased ping-pong head L → centre (U path) → R and back every bar.
    static func chase(_ c: Ctx) -> RigFrame {
        let p = SceneID.chase.palette, b = c.b, e = c.e
        let electric = p[0], steel = p[3]
        let pos = 7 * s(tri(b / 4))
        let width = 1.2 + 0.8 * e
        func hd(_ x: Double) -> Double { bump(abs(x - pos), width) }
        let ch = p[1].mixed(with: p[2], 0.5 - 0.5 * cos(tau * b / 8))
        let gh = c.w(0.45, 0.85) * c.on(b, 0.75, 1, 0.1, 6.0)
        let rgb = (0..<6).map { i -> LightColor in
            let h = hd(Double(6 - i))
            var color = electric.mixed(with: ch, h)
            var level = c.lvl * (0.10 + 0.90 * h)
            if i == 2 || i == 3 { color = color.mixed(with: steel, 0.5 * gh); level += c.lvl * 0.35 * gh }
            return lit(color, level)
        }
        let cob = (0..<3).map { k -> Double in
            let ripple = 1.0 * c.on(b, 12 + 0.25 * Double(k), 16, 0.12, 3.5)
            return max(ripple, k == 1 ? 0.25 * e * bump(abs(3.5 - pos), 1.0) : 0)
        }
        let sideCob = 1.0
        return RigFrame(
            left: side(electric.mixed(with: ch, hd(0)), c.lvl * (0.08 + 0.92 * hd(0)), cob: sideCob * c.on(b, 0, 8, 0.12, 3.0)),
            center: RoleFrame(rgb: rgb, cob: cob),
            right: side(electric.mixed(with: ch, hd(7)), c.lvl * (0.08 + 0.92 * hd(7)), cob: sideCob * c.on(b, 6, 8, 0.12, 3.0)))
    }

    /// Segment heights for the centre, 0 = bottom edge, 1 = top vertex.
    static let height: [Double] = [0.75, 0.25, 0, 0, 0.25, 0.75]

    /// Build (hold gesture): tension counted from the press (phrase), pulses on the grid (beat).
    /// Quarters → 8ths (beat 4) → 16ths (beat 12) while a bottom→top sweep doubles its density
    /// (2 → 1 → ½ beat, cresting just before the beat) and the colour climbs cyan → lavender → warm.
    /// Sides share the colour and call: left on the beat, right on the offbeat (then left 8ths,
    /// right the 16ths in between). After 16 beats it holds peak tension, no fake phrase restart.
    static func aurora(_ c: Ctx) -> RigFrame {
        let p = SceneID.aurora.palette, warm = p[3]
        let t = max(0, c.rd), b = c.b, e = c.e
        let u = clamp01(t / 16)
        let w8 = s(t - 3.5), w16 = s(t - 11.5)
        let q = c.on(b, 0, 1, 0.08, 4.0)
        let pw = q + (c.on(b, 0, 0.5, 0.06, 6.0) - q) * w8
        let pulse = pw + (c.on(b, 0, 0.25, 0.05, 9.0) - pw) * w16 * (0.55 + 0.45 * e)
        func sweep(_ per: Double, _ y: Double) -> Double { bump(abs(y - (1.9 * fract(b / per) - 0.5)), 0.3 + 0.1 * (1 - u)) }
        func sw(_ y: Double) -> Double {
            let a = sweep(2, y) + (sweep(1, y) - sweep(2, y)) * w8
            return a + (sweep(0.5, y) - a) * w16
        }
        let rgb = (0..<6).map { i -> LightColor in
            let h = height[i], hd = sw(h)
            let color = pallin(p, 0.22 + 0.58 * u + 0.18 * h).mixed(with: warm, 0.35 * u * hd)
            return lit(color, c.lvl * (0.28 + 0.16 * u + (0.30 + 0.25 * u) * hd + (0.22 + 0.25 * u) * pulse * (0.6 + 0.4 * h)))
        }
        let bar = Int(pmod(floor((b + 0.5) / 4), 3))
        let ce = 1.0
        let cob = (0..<3).map { k -> Double in
            let down = ce * (0.35 + 0.65 * u) * (k == bar ? 1 : 0.3 * u) * c.on(b, 0, 4, 0.1, 2.5)
            return down + (k == (bar + 1) % 3 ? 0.65 * ce * w8 * c.on(b, 2, 4, 0.1, 3.0) : 0)
        }
        let sideC = pallin(p, 0.30 + 0.62 * u)
        func call(_ o: Double) -> Double {
            let a = c.on(b, o, 1, 0.08, 4.5)
            return a + (c.on(b, o / 2, 0.5, 0.06, 6.0) - a) * w8
        }
        func sideI(_ k: Double) -> Double { c.lvl * (0.20 + 0.26 * u + (0.36 + 0.24 * u) * k) }
        let sideCob = u * u * ce
        let cl = call(0), cr = call(0.5)
        return RigFrame(
            left: side(sideC.mixed(with: warm, 0.3 * u * cl), sideI(cl), cob: sideCob * c.on(b, 0, 4, 0.1, 2.5)),
            center: RoleFrame(rgb: rgb, cob: cob),
            right: side(sideC.mixed(with: warm, 0.3 * u * cr), sideI(cr), cob: sideCob * c.on(b, 2, 4, 0.1, 2.5)))
    }

    /// Drop: before the anchored downbeat (the quantised fade window) a near-black dip; on it a big
    /// warm impact on everything that decays into a clean low floor with a rounded kick (edge
    /// accent rotating clockwise per bar), offbeat sides (L/R alternate the accent every 2 beats)
    /// and smaller re-impacts every 8 beats. Base colour swaps crimson ↔ UV every 16 beats.
    static func respiro(_ c: Ctx) -> RigFrame {
        let ink = SceneID.respiro.palette[3]
        let dip = RigFrame(
            left: .black(rgb: 1, cob: 1),
            center: RoleFrame(rgb: Array(repeating: ink.scaled(0.6), count: 6), cob: [0, 0, 0]),
            right: .black(rgb: 1, cob: 1))
        let a = max(0.06, c.minAttack)
        guard c.rd >= 0 else { return c.rd < -a ? dip : dip.mixed(with: dropState(c, 0), s((c.rd + a) / a)) }
        return dropState(c, c.rd)
    }

    static func dropState(_ c: Ctx, _ rd: Double) -> RigFrame {
        let p = SceneID.respiro.palette
        let crimson = p[0], uv = p[1], bone = p[2], ink = p[3]
        let e = c.e, x16 = pmod(rd, 16)
        let swap = sstep(15.6, 16, x16)
        let sel = pmod(floor(rd / 16), 2) == 1 ? 1 - swap : swap
        let base = crimson.mixed(with: uv, sel)
        let n = Int(floor((rd + 0.5) / 8))
        let imp = c.on(rd, 0, 8, 0.06, 1.4) * (n == 0 ? 1 : (n % 2 == 0 ? 0.7 : 0.45))
        let k1 = c.on(rd, 0, 1, 0.06, 5.0)
        let oh = c.on(rd, 0.5, 1, 0.06, 6.0)
        let edge = Int(pmod(floor((rd + 0.5) / 4), 3))
        let rgb = (0..<6).map { i -> LightColor in
            let h = height[i], wt = i / 2 == edge ? 1.0 : 0.55
            let color = base.mixed(with: bone, 0.8 * imp + 0.25 * k1 * wt)
            let level = c.lvl * (0.06 + 0.72 * k1 * wt * (1 - 0.4 * h) + 0.18 * oh * h) + imp
            let lit = LightColor(
                0.4 * ink.r + color.r * clamp01(level), 0.4 * ink.g + color.g * clamp01(level),
                0.4 * ink.b + color.b * clamp01(level))
            return lit.clamped
        }
        let cob = (0..<3).map { k -> Double in
            max(imp, k == edge ? 0.45 * (0.5 + 0.5 * e) * c.on(rd, 2, 4, 0.1, 3.0) : 0)
        }
        let ws = 0.55 + 0.45 * e
        let sideC = base.mixed(with: bone, 0.3 * oh + 0.8 * imp)
        func sideI(_ accent: Double) -> Double {
            c.lvl * (0.04 + 0.18 * k1 + ws * (0.45 * oh + 0.35 * accent)) + imp
        }
        let sideCob = imp
        return RigFrame(
            left: side(sideC, sideI(c.on(rd, 0.5, 2, 0.06, 4.0)), cob: sideCob),
            center: RoleFrame(rgb: rgb, cob: cob),
            right: side(sideC, sideI(c.on(rd, 1.5, 2, 0.06, 4.0)), cob: sideCob))
    }
}
