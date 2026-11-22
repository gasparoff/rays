import Foundation

/// What one fixture should emit, before its output scale (master × role level):
/// one colour per RGB pixel group and one level per white/COB emitter, all 0...1.
public struct FixtureLevels: Equatable, Sendable {
    public var rgb: [LightColor]
    public var cob: [Double]

    public init(rgb: [LightColor], cob: [Double]) { self.rgb = rgb; self.cob = cob }

    /// The same colour on every segment; `w` drives every COB.
    public init(uniform c: LightColor) { rgb = [LightColor(c.r, c.g, c.b)]; cob = [c.w] }

    public init(_ frame: RoleFrame) { rgb = frame.rgb; cob = frame.cob }

    public static let off = FixtureLevels(rgb: [], cob: [])

    /// Adapts to a profile's segment counts: averages when the fixture has fewer groups than the
    /// frame (e.g. a TRI 180 in the centre role), repeats when it has more.
    public func resampled(rgbCount: Int, cobCount: Int) -> FixtureLevels {
        FixtureLevels(rgb: Self.resample(rgb, rgbCount, zero: .black) { list in
            let n = Double(list.count)
            return LightColor(list.map(\.r).reduce(0, +) / n, list.map(\.g).reduce(0, +) / n, list.map(\.b).reduce(0, +) / n)
        }, cob: Self.resample(cob, cobCount, zero: 0) { $0.reduce(0, +) / Double($0.count) })
    }

    static func resample<T>(_ src: [T], _ n: Int, zero: T, average: ([T]) -> T) -> [T] {
        guard n > 0 else { return [] }
        guard !src.isEmpty else { return Array(repeating: zero, count: n) }
        if src.count == n { return src }
        return (0..<n).map { j in
            if n > src.count { return src[j * src.count / n] }
            let lo = j * src.count / n, hi = max(lo + 1, (j + 1) * src.count / n)
            return average(Array(src[lo..<hi]))
        }
    }

    public var isFinite: Bool { rgb.allSatisfy(\.isFinite) && cob.allSatisfy(\.isFinite) }
}

/// Maps per-fixture levels into 512-slot universes using the fixture profiles.
///
/// - All dimming is done in software, linearly, no gamma. A fixture dimmer channel is 255 while the
///   fixture's output scale is above zero and 0 otherwise, so master = 0 (or a role fader at 0)
///   zeroes every light channel, white/COB included, whatever the fixture's internal dimmer curve.
/// - `.blinder` and `.white` channels carry the COB level × scale; they are never boosted by RGB.
/// - Strobe/program channels are `.ignore` and always 0. Channels a profile does not describe stay 0.
/// - Blackout zeroes everything, constants included. Unknown profiles produce nothing.
public enum DMXComposer {
    public static func compose(patch: Patch, library: ProfileLibrary, levels: [FixtureLevels],
                               scales: [Double], blackout: Bool) -> [PortAddress: [UInt8]] {
        var universes: [PortAddress: [UInt8]] = [:]
        for u in patch.universes { universes[u] = [UInt8](repeating: 0, count: ArtNet.dmxSlots) }
        guard !blackout else { return universes }
        let lib = patch.library(base: library)
        for (index, fixture) in patch.fixtures.enumerated() {
            guard let profile = lib.profile(id: fixture.profileID), let pa = PortAddress(fixture.universe),
                  (1...512).contains(fixture.address), fixture.address + profile.footprint - 1 <= 512,
                  index < levels.count else { continue }
            let scale = index < scales.count ? scales[index] : 0
            let values = channelValues(profile: profile, levels: levels[index], scale: scale)
            for (offset, value) in values.enumerated() {
                universes[pa]?[fixture.address - 1 + offset] = value
            }
        }
        return universes
    }

    /// Convenience: one uniform colour per fixture, every fixture at `master`.
    public static func compose(patch: Patch, library: ProfileLibrary, colors: [LightColor],
                               master: Double, blackout: Bool) -> [PortAddress: [UInt8]] {
        compose(patch: patch, library: library, levels: colors.map(FixtureLevels.init(uniform:)),
                scales: Array(repeating: master, count: colors.count), blackout: blackout)
    }

    public static func channelValues(profile: FixtureProfile, color: LightColor, master: Double) -> [UInt8] {
        channelValues(profile: profile, levels: FixtureLevels(uniform: color), scale: master)
    }

    public static func channelValues(profile: FixtureProfile, levels raw: FixtureLevels, scale rawScale: Double) -> [UInt8] {
        let scale = clamp01(rawScale)
        let levels = raw.isFinite ? raw : .off
        let segments = profile.channelSegments
        let rgbCount = profile.rgbSegmentCount, cobCount = profile.cobCount
        let lv = levels.resampled(rgbCount: rgbCount, cobCount: cobCount)
        // Without any white/COB channel the warm COB level folds into RGB as warm white.
        let fold = cobCount == 0 && !levels.cob.isEmpty ? levels.cob.map(clamp01).reduce(0, +) / Double(levels.cob.count) : 0
        func color(_ seg: Int?) -> LightColor {
            guard let seg, seg < lv.rgb.count else { return .black }
            let c = lv.rgb[seg]
            return LightColor(c.r + fold, c.g + fold * 0.9, c.b + fold * 0.75).clamped
        }
        func cob(_ seg: Int?) -> Double {
            guard let seg, seg < lv.cob.count else { return 0 }
            return clamp01(lv.cob[seg])
        }
        func byte(_ x: Double) -> UInt8 { UInt8((clamp01(x) * scale * 255).rounded()) }
        return zip(profile.channels, segments).map { ch, seg in
            switch ch.kind {
            case .dimmer: return scale > 0 ? 255 : 0
            case .red: return byte(color(seg).r)
            case .green: return byte(color(seg).g)
            case .blue: return byte(color(seg).b)
            case .amber: let c = color(seg); return byte(min(c.r, c.g * 2) * 0.6)
            case .white, .blinder: return byte(cob(seg))
            case .constant: return ch.value
            case .ignore: return 0
            }
        }
    }

    /// Reads a fixture's light back from the bytes actually composed (preview = output).
    /// Fixture dimmer channels multiply RGB and `.white`; `.blinder` COBs are independent.
    public static func decode(profile: FixtureProfile, universe: [UInt8], address: Int) -> FixtureLevels {
        let start = address - 1
        guard start >= 0, start + profile.footprint <= universe.count else { return .off }
        let bytes = universe[start..<(start + profile.footprint)].map { Double($0) / 255 }
        var dimmer = 1.0
        for (ch, v) in zip(profile.channels, bytes) where ch.kind == .dimmer { dimmer *= v }
        var rgb = Array(repeating: LightColor.black, count: profile.rgbSegmentCount)
        var cob = Array(repeating: 0.0, count: profile.cobCount)
        for ((ch, seg), v) in zip(zip(profile.channels, profile.channelSegments), bytes) {
            guard let seg else { continue }
            switch ch.kind {
            case .red where seg < rgb.count: rgb[seg].r = clamp01(rgb[seg].r + v * dimmer)
            case .green where seg < rgb.count: rgb[seg].g = clamp01(rgb[seg].g + v * dimmer)
            case .blue where seg < rgb.count: rgb[seg].b = clamp01(rgb[seg].b + v * dimmer)
            case .amber where seg < rgb.count:
                rgb[seg].r = clamp01(rgb[seg].r + v * dimmer); rgb[seg].g = clamp01(rgb[seg].g + 0.5 * v * dimmer)
            case .white where seg < cob.count: cob[seg] = v * dimmer
            case .blinder where seg < cob.count: cob[seg] = v
            default: break
            }
        }
        return FixtureLevels(rgb: rgb, cob: cob)
    }
}
