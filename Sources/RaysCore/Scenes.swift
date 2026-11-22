import Foundation

/// RGBW colour, components 0...1.
public struct LightColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, w: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ w: Double = 0) {
        self.r = r; self.g = g; self.b = b; self.w = w
    }

    public static let black = LightColor(0, 0, 0)

    public func scaled(_ k: Double) -> LightColor { LightColor(r * k, g * k, b * k, w * k).clamped }

    public func mixed(with o: LightColor, _ t: Double) -> LightColor {
        let t = clamp01(t)
        return LightColor(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, w + (o.w - w) * t).clamped
    }

    public var clamped: LightColor { LightColor(clamp01(r), clamp01(g), clamp01(b), clamp01(w)) }
    public var isFinite: Bool { r.isFinite && g.isFinite && b.isFinite && w.isFinite }
    public var peak: Double { max(r, g, b) }

    /// Approximate emitted RGB for the preview (white folded in).
    public var previewRGB: (r: Double, g: Double, b: Double) {
        (clamp01(r + w * 0.95), clamp01(g + w * 0.9), clamp01(b + w * 0.8))
    }
}

@inline(__always) package func clamp01(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }

/// Positive modulo, finite-safe.
@inline(__always) package func pmod(_ a: Double, _ m: Double) -> Double {
    guard a.isFinite, m > 0 else { return 0 }
    let r = a.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
}

/// Scene identifiers are persisted (preferences, MIDI slots): raw values never change.
/// The case order is the on-screen / K2 / keyboard order (house → tech house → build → drop).
public enum SceneID: String, Codable, CaseIterable, Identifiable, Sendable {
    case ambra, sunset, pulse, chase, aurora, respiro
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ambra: return "Ambra"
        case .sunset: return "Tramonto"
        case .pulse: return "Pulse"
        case .chase: return "Chase"
        case .aurora: return "Build"
        case .respiro: return "Drop"
        }
    }

    public var subtitle: String {
        switch self {
        case .ambra: return "House · respiro caldo"
        case .sunset: return "House · groove in levare"
        case .pulse: return "Tech house · colpi 3+3+2"
        case .chase: return "Tech house · corsa sx–dx"
        case .aurora: return "Salita · 16 battiti"
        case .respiro: return "Impatto sul battere"
        }
    }

    /// Scene palette (also used for the UI swatches).
    public var palette: [LightColor] {
        switch self {
        case .ambra: return [.init(1.0, 0.5, 0.1), .init(1.0, 0.7, 0.28), .init(0.95, 0.3, 0.3), .init(0.5, 0.1, 0.38)]
        case .sunset: return [.init(1.0, 0.6, 0.08), .init(1.0, 0.36, 0.18), .init(0.85, 0.1, 0.45), .init(0.2, 0.08, 0.62)]
        case .pulse: return [.init(0.32, 0.04, 1.0), .init(0.0, 0.62, 0.58), .init(0.55, 0.85, 1.0), .init(1.0, 0.32, 0.02)]
        case .chase: return [.init(0.08, 0.22, 1.0), .init(1.0, 0.08, 0.42), .init(1.0, 0.38, 0.0), .init(0.5, 0.62, 0.85)]
        case .aurora: return [.init(0.04, 0.08, 0.55), .init(0.0, 0.7, 1.0), .init(0.62, 0.4, 1.0), .init(1.0, 0.82, 0.58)]
        case .respiro: return [.init(1.0, 0.04, 0.06), .init(0.38, 0.0, 1.0), .init(1.0, 0.8, 0.55), .init(0.03, 0.0, 0.1)]
        }
    }

    /// How a change to this scene lines up with the beat grid.
    public var transition: SceneTransition {
        switch self {
        case .ambra, .sunset: return SceneTransition(start: .immediate, fadeBeats: 4)
        case .pulse, .chase: return SceneTransition(start: .nextBeat, fadeBeats: 2)
        // Build reacts on the press and counts its rise from there; its pulses follow the grid.
        case .aurora: return SceneTransition(start: .immediate, fadeBeats: 0.5)
        // Drop is anchored at the next downbeat (no lead: an early release never waits a bar);
        // the fade window is the pre-drop dark dip.
        case .respiro: return SceneTransition(start: .downbeat(lead: 0), fadeBeats: 0.25)
        }
    }
}

/// How the engine changes from one scene to the next.
public struct SceneTransition: Equatable, Sendable {
    /// When a scene change starts.
    public enum Start: Equatable, Sendable {
        /// Fade starts on the press.
        case immediate
        /// Fade starts on the next whole beat.
        case nextBeat
        /// Phrase anchored at b0 = 4·ceil((press + lead)/4); fade runs over [b0 − fadeBeats, b0].
        case downbeat(lead: Double)
    }
    public var start: Start
    public var fadeBeats: Double
}

/// Motion rate. The persisted raw value is the historical "movement every N beats", so the
/// rate is its inverse: 0.5 → ×2, 1 → ×1, 2 → ×½, 4 → ×¼. All rates stay phase-locked to the grid.
public enum Subdivision: Double, Codable, CaseIterable, Identifiable, Sendable {
    case half = 0.5, one = 1, two = 2, four = 4
    public var id: Double { rawValue }
    public var rate: Double { 1 / rawValue }

    public var label: String {
        switch self {
        case .half: return "2×"
        case .one: return "1×"
        case .two: return "½×"
        case .four: return "¼×"
        }
    }

    /// Slow → fast, as on screen and on the K2 pads I–L.
    public static let rateOrder: [Subdivision] = [.four, .two, .one, .half]
}

/// Shared performance controls; renderers remain pure functions of the beat grid.
public struct SceneParameters: Equatable, Sendable {
    public var energy: Double
    public var subdivision: Subdivision
    public init(energy: Double = 0.5, subdivision: Subdivision = .one) { self.energy = energy; self.subdivision = subdivision }
}

/// Uniform-color adapter retained for generic fixtures and existing integrations.
public enum SceneRenderer {
    public static func render(_ scene: SceneID, beat: Double, index: Int, count: Int, params: SceneParameters) -> LightColor {
        let frame = Choreography.render(scene, SceneContext(beat: beat * params.subdivision.rate,
                                                          phrase: beat * params.subdivision.rate, energy: params.energy))
        let role: FixtureRole = count <= 1 ? .left : (index == 0 ? .left : (index == count - 1 ? .right : .center))
        let f = frame[role]
        let n = Double(max(1, f.rgb.count))
        return LightColor(f.rgb.map(\.r).reduce(0, +) / n, f.rgb.map(\.g).reduce(0, +) / n,
                          f.rgb.map(\.b).reduce(0, +) / n, f.cob.reduce(0, +) / Double(max(1, f.cob.count))).clamped
    }
}
