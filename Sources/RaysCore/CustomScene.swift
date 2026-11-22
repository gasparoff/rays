import Foundation

/// Independent performance banks share the same six keyboard and MIDI slots.
public enum SceneBank: String, Codable, CaseIterable, Identifiable, Sendable {
    case house, club
    public var id: String { rawValue }
    public var title: String { self == .house ? "House" : "Club 130–138" }
}

// Custom scenes: a base choreography (SceneID) with three user colours, energy, motion length,
// warm-white (COB) level and L/C/R balance. The engine still computes the base choreography;
// `recolor` maps every produced colour onto the user's palette, preserving peak, black and the
// white channel.

/// Plain sRGB triple (0...1) as stored on disk. The white channel is never stored: whites belong to the choreography.
public struct SceneRGB: Codable, Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// RGB part of a fixture color (the white channel is dropped, not folded in).
    public init(_ color: LightColor) {
        self.init(r: color.r, g: color.g, b: color.b)
    }

    public var lightColor: LightColor { LightColor(r, g, b) }
    public var isFinite: Bool { r.isFinite && g.isFinite && b.isFinite }
    public var clamped: SceneRGB { SceneRGB(r: unit(r), g: unit(g), b: unit(b)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = (try? c.decodeIfPresent(Double.self, forKey: .r)) ?? 0
        g = (try? c.decodeIfPresent(Double.self, forKey: .g)) ?? 0
        b = (try? c.decodeIfPresent(Double.self, forKey: .b)) ?? 0
    }
}

/// A user scene: base choreography, palette, energy, levels and an optional track program. Persisted as JSON.
public struct CustomScene: Codable, Equatable, Identifiable, Sendable {
    public static let defaultName = String(localized: "My scene")
    public static let maxNameLength = 40
    public static let colorCount = 3

    public var id: UUID
    /// When present, edits replace this factory button; its musical identity stays fixed.
    public var presetSlot: SceneID?
    public var presetBank: SceneBank
    public var name: String
    /// Choreography that drives timing, movement and intensity.
    public var base: SceneID
    /// Exactly three user colors after `sanitized`.
    public var colors: [SceneRGB]
    /// 0...1, same meaning as the main Energia control.
    public var energy: Double
    public var subdivision: Subdivision
    /// Warm COB amount, 0 = off, 1 = the choreography's normal level. Applied by the engine to COBs before the master.
    public var warmth: Double
    public var leftLevel: Double
    public var centerLevel: Double
    public var rightLevel: Double
    /// Optional animation structure (tracks on the beat grid). nil = the base choreography as it always was.
    public var program: SceneProgram?

    public init(
        id: UUID = UUID(),
        name: String = CustomScene.defaultName,
        presetSlot: SceneID? = nil,
        presetBank: SceneBank = .house,
        base: SceneID = .ambra,
        colors: [SceneRGB]? = nil,
        energy: Double = 0.5,
        subdivision: Subdivision = .one,
        warmth: Double = 1,
        leftLevel: Double = 1,
        centerLevel: Double = 1,
        rightLevel: Double = 1,
        program: SceneProgram? = nil
    ) {
        self.id = id
        self.presetSlot = presetSlot
        self.presetBank = presetBank
        self.name = name
        self.base = base
        self.colors = colors ?? CustomScene.defaultColors(for: base)
        self.energy = energy
        self.subdivision = subdivision
        self.warmth = warmth
        self.leftLevel = leftLevel
        self.centerLevel = centerLevel
        self.rightLevel = rightLevel
        self.program = program
    }

    /// The first three colors of the base choreography's palette (padded if a palette is shorter).
    public static func defaultColors(for base: SceneID) -> [SceneRGB] {
        var out = base.palette.prefix(colorCount).map { SceneRGB($0).clamped }
        let fallback = [SceneRGB(r: 1, g: 0.5, b: 0.08), SceneRGB(r: 1, g: 0.7, b: 0.25), SceneRGB(r: 1, g: 0.8, b: 0.55)]
        while out.count < colorCount { out.append(fallback[out.count]) }
        return out
    }

    /// Trimmed single-line name without control characters, at most `maxNameLength` characters.
    public static func cleanName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let words = String(scalars).split(whereSeparator: { $0.isWhitespace })
        let joined = words.joined(separator: " ")
        let short = String(joined.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? defaultName : short
    }

    /// Finite, bounded copy: values out of range are clamped, non-finite values fall back to the defaults.
    public var sanitized: CustomScene {
        var s = self
        s.name = CustomScene.cleanName(name)
        s.base = presetSlot ?? base
        let defaults = CustomScene.defaultColors(for: s.base)
        s.colors = (0..<CustomScene.colorCount).map { i in
            guard i < colors.count, colors[i].isFinite else { return defaults[i] }
            return colors[i].clamped
        }
        s.energy = bounded(energy, fallback: 0.5)
        s.warmth = bounded(warmth, fallback: 1)
        s.leftLevel = bounded(leftLevel, fallback: 1)
        s.centerLevel = bounded(centerLevel, fallback: 1)
        s.rightLevel = bounded(rightLevel, fallback: 1)
        s.program = program?.sanitized
        return s
    }

    /// True while the colors are still the base choreography's own.
    public var usesBaseColors: Bool { sanitized.colors == CustomScene.defaultColors(for: base) }

    public var palette: [LightColor] { sanitized.colors.map(\.lightColor) }

    public var paletteMap: CustomPaletteMap {
        CustomPaletteMap(palette: palette, anchors: Array(base.palette.prefix(CustomScene.colorCount)))
    }

    /// Hue-based remap of a choreography color onto the three custom colors. See `CustomPaletteMap`.
    /// For per-frame use, build `paletteMap` once and call `apply` on it.
    public func recolor(_ color: LightColor) -> LightColor { paletteMap.apply(color) }

    /// Stage position used by the per-zone levels.
    public enum Zone: Sendable { case left, center, right }

    public func level(_ zone: Zone) -> Double {
        switch zone {
        case .left: return bounded(leftLevel, fallback: 1)
        case .center: return bounded(centerLevel, fallback: 1)
        case .right: return bounded(rightLevel, fallback: 1)
        }
    }

    /// COB value after the warm-white amount, before the global master.
    public func warmCOB(_ value: Double) -> Double { unit(value) * bounded(warmth, fallback: 1) }

    // Tolerant decoding: missing or unknown fields fall back to the defaults instead of dropping the scene.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CustomScene()
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        presetSlot = (try? c.decodeIfPresent(String.self, forKey: .presetSlot)).flatMap(SceneID.init(rawValue:))
        presetBank = (try? c.decodeIfPresent(SceneBank.self, forKey: .presetBank)) ?? .house
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? d.name
        let baseRaw = try? c.decodeIfPresent(String.self, forKey: .base)
        base = baseRaw.flatMap(SceneID.init(rawValue:)) ?? d.base
        colors = (try? c.decodeIfPresent([SceneRGB].self, forKey: .colors)) ?? CustomScene.defaultColors(for: base)
        energy = (try? c.decodeIfPresent(Double.self, forKey: .energy)) ?? d.energy
        let sub = try? c.decodeIfPresent(Double.self, forKey: .subdivision)
        subdivision = sub.flatMap(Subdivision.init(rawValue:)) ?? d.subdivision
        warmth = (try? c.decodeIfPresent(Double.self, forKey: .warmth)) ?? d.warmth
        leftLevel = (try? c.decodeIfPresent(Double.self, forKey: .leftLevel)) ?? d.leftLevel
        centerLevel = (try? c.decodeIfPresent(Double.self, forKey: .centerLevel)) ?? d.centerLevel
        rightLevel = (try? c.decodeIfPresent(Double.self, forKey: .rightLevel)) ?? d.rightLevel
        // A missing or unreadable program keeps the scene and its historical behaviour.
        program = try? c.decodeIfPresent(SceneProgram.self, forKey: .program)
        self = sanitized
    }

    private enum CodingKeys: String, CodingKey {
        case id, presetSlot, presetBank, name, base, colors, energy, subdivision, warmth, leftLevel, centerLevel, rightLevel, program
    }
}

/// Maps choreography colors onto a custom palette by hue.
///
/// - Hue anchors are the base palette colors: a color with the hue of anchor k becomes custom color k;
///   hues between two anchors blend smoothly (smoothstep in RGB) between their custom colors.
///   With fewer than two usable anchors the hue wheel is split in thirds instead.
/// - Peak intensity (max of R, G, B) is preserved exactly; black stays black, no brightness is invented.
/// - Near-neutral inputs (whites, greys) stay neutral, so white flashes in the choreography survive.
/// - The custom color's brightness is not used (the choreography decides intensity),
///   except that a black or nearly black custom color darkens its slot smoothly.
/// - The white channel is passed through clamped, never replaced by RGB.
public struct CustomPaletteMap: Sendable {
    private struct Slot: Sendable { var hue: Double; var index: Int }
    private let slots: [Slot]
    /// Custom colors normalized to max channel 1, plus how much of them is "present" (0 for black).
    private let chroma: [(r: Double, g: Double, b: Double)]
    private let presence: [Double]

    public init(palette: [LightColor], anchors: [LightColor]) {
        let colors = palette.isEmpty ? [LightColor(1, 1, 1)] : palette
        var chroma: [(r: Double, g: Double, b: Double)] = []
        var presence: [Double] = []
        for c in colors {
            let r = unit(c.r), g = unit(c.g), b = unit(c.b)
            let m = max(r, g, b)
            chroma.append(m > 1e-9 ? (r / m, g / m, b / m) : (0, 0, 0))
            presence.append(smooth(m / 0.08))
        }
        self.chroma = chroma
        self.presence = presence

        var slots: [Slot] = []
        for (i, a) in anchors.prefix(colors.count).enumerated() {
            let hsv = HSV(unit(a.r), unit(a.g), unit(a.b))
            guard hsv.v > 1e-6, hsv.s >= 0.08 else { continue }
            if slots.contains(where: { hueDistance($0.hue, hsv.h) < 0.002 }) { continue }
            slots.append(Slot(hue: hsv.h, index: i))
        }
        if slots.count < 2 {
            slots = (0..<colors.count).map { Slot(hue: Double($0) / Double(colors.count), index: $0) }
        }
        self.slots = slots.sorted { $0.hue < $1.hue }
    }

    public func apply(_ color: LightColor) -> LightColor {
        let r = unit(color.r), g = unit(color.g), b = unit(color.b), w = unit(color.w)
        let hsv = HSV(r, g, b)
        guard hsv.v > 1e-9 else { return LightColor(0, 0, 0, w) }

        // Locate the hue between two neighbouring anchors (circularly).
        var lo = slots[slots.count - 1], hi = slots[0], f = 0.0
        for k in 0..<slots.count {
            let a = slots[k], next = slots[(k + 1) % slots.count]
            var span = next.hue - a.hue
            if span <= 0 { span += 1 }
            var d = hsv.h - a.hue
            if d < 0 { d += 1 }
            if d < span { lo = a; hi = next; f = d / span; break }
        }
        let t = smooth(f)
        let ca = chroma[lo.index], cb = chroma[hi.index]
        var tr = ca.r + (cb.r - ca.r) * t, tg = ca.g + (cb.g - ca.g) * t, tb = ca.b + (cb.b - ca.b) * t
        let tm = max(tr, tg, tb)
        guard tm > 1e-9 else { return LightColor(0, 0, 0, w) }
        tr /= tm; tg /= tm; tb /= tm
        let present = presence[lo.index] + (presence[hi.index] - presence[lo.index]) * t

        // Keep neutral inputs neutral: full custom color from saturation 0.35 upwards.
        let k = smooth(hsv.s / 0.35)
        let scale = hsv.v * present
        let out = LightColor((1 + (tr - 1) * k) * scale, (1 + (tg - 1) * k) * scale, (1 + (tb - 1) * k) * scale, w)
        return out.isFinite ? out.clamped : LightColor(0, 0, 0, w)
    }
}

/// On-disk document `custom-scenes.json`.
///
/// Current schema (version 1): `{"version": 1, "scenes": [CustomScene, ...]}`.
/// A bare JSON array of scenes is also accepted on read. Newer versions are refused, never rewritten.
/// `program` is an additive optional key: files without it read exactly as before, and the envelope
/// stays version 1 so earlier app builds can still open the file (they ignore the tracks).
public enum CustomSceneDocument {
    public static let currentVersion = 1
    public static let fileName = "custom-scenes.json"

    /// Errors reading or writing the scenes file.
    public enum DocumentError: Error, Equatable, LocalizedError {
        case unsupportedVersion(Int)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return String(localized: "The custom scenes file comes from a newer version (\(String(describing: v))): it was left unchanged.")
            case .unreadable(let detail):
                return String(localized: "The custom scenes file can't be read and was left unchanged (\(String(describing: detail))).")
            }
        }
    }

    private struct Envelope: Codable {
        var version: Int
        var scenes: [CustomScene]
    }

    private struct VersionProbe: Decodable { var version: Int? }

    public static func decode(_ data: Data) throws -> [CustomScene] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([CustomScene].self, from: data) { return dedupe(list) }
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw DocumentError.unreadable(String(localized: "invalid JSON"))
        }
        guard let version = probe.version else { throw DocumentError.unreadable(String(localized: "missing version")) }
        guard version <= currentVersion, version >= 1 else { throw DocumentError.unsupportedVersion(version) }
        do {
            return dedupe(try decoder.decode(Envelope.self, from: data).scenes)
        } catch {
            throw DocumentError.unreadable(String(localized: "invalid scene list"))
        }
    }

    public static func encode(_ scenes: [CustomScene]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(version: currentVersion, scenes: scenes.map(\.sanitized)))
    }

    /// Keeps the first scene for each id so lookups by id stay unambiguous.
    private static func dedupe(_ scenes: [CustomScene]) -> [CustomScene] {
        var seen = Set<UUID>()
        return scenes.filter { seen.insert($0.id).inserted }
    }
}

/// Atomic file access for `custom-scenes.json`. Foundation-only so it can be tested without UI.
public struct CustomSceneFile: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(CustomSceneDocument.fileName)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Empty list when the file does not exist; throws when it exists but cannot be used.
    public func load() throws -> [CustomScene] {
        guard exists else { return [] }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw CustomSceneDocument.DocumentError.unreadable(error.localizedDescription)
        }
        return try CustomSceneDocument.decode(data)
    }

    public func save(_ scenes: [CustomScene]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CustomSceneDocument.encode(scenes).write(to: url, options: .atomic)
    }

    /// Moves the current file aside (e.g. `custom-scenes.backup-20261022-193000.json`) and returns its new URL.
    @discardableResult
    public func backupExisting(now: Date = Date()) throws -> URL? {
        guard exists else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var target = dir.appendingPathComponent("\(stem).backup-\(f.string(from: now)).json")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(stem).backup-\(f.string(from: now))-\(n).json")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

// MARK: - Private math (self-contained so it does not depend on Scenes.swift internals)

@inline(__always) private func unit(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }

@inline(__always) private func bounded(_ x: Double, fallback: Double) -> Double { x.isFinite ? min(1, max(0, x)) : fallback }

@inline(__always) private func smooth(_ x: Double) -> Double {
    let c = unit(x)
    return c * c * (3 - 2 * c)
}

@inline(__always) private func hueDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b)
    return min(d, 1 - d)
}

private struct HSV {
    var h: Double, s: Double, v: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        v = mx
        s = mx > 1e-9 ? d / mx : 0
        guard d > 1e-9 else { h = 0; return }
        var hue: Double
        if mx == r { hue = (g - b) / d } else if mx == g { hue = 2 + (b - r) / d } else { hue = 4 + (r - g) / d }
        hue /= 6
        if hue < 0 { hue += 1 }
        h = hue >= 1 ? hue - 1 : hue
    }
}
