import Foundation

// Scene structure: tracks drawn by hand on the beat grid (kick, clap, hi-hat…). The labels are
// only musical: no audio is analysed, every track follows the Link beat. The model is optional
// (`CustomScene.program`): without it a scene behaves exactly as before.

/// Musical label of a track. It only chooses a name, an icon and a starting pattern.
public enum TrackSound: String, Codable, CaseIterable, Identifiable, Sendable {
    case kick, clap, hat, bass, accent, free
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .kick: return "Cassa"
        case .clap: return "Clap"
        case .hat: return "Hi-hat"
        case .bass: return "Basso"
        case .accent: return "Accento"
        case .free: return "Libero"
        }
    }

    /// One-line hint shown in menus.
    public var hint: String {
        switch self {
        case .kick: return "Tutti i quarti, al centro"
        case .clap: return "Battiti 2 e 4, bianco caldo"
        case .hat: return "In levare, laterali alternate"
        case .bass: return "Giro di 2 battute, onde lunghe"
        case .accent: return "Un colpo ogni 4 battute"
        case .free: return "Griglia vuota in sedicesimi"
        }
    }
}

public enum TrackMotion: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Every target lights on every hit.
    case together
    /// Hits alternate between the two halves of the target (left/right, or inside/outside "from the centre").
    case alternate
    /// Each hit moves to the next position of the target.
    case chase
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .together: return "Insieme"
        case .alternate: return "Alterna"
        case .chase: return "Corsa"
        }
    }
}

public enum TrackDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Left → right across the stage (centre segments along the U path).
    case forward
    /// Right → left.
    case backward
    /// Chase: there and back. Delays and halves: as `forward`.
    case bounce
    /// From the centre towards the sides (symmetric positions move together).
    case center
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .forward: return "Sx → Dx"
        case .backward: return "Dx → Sx"
        case .bounce: return "Avanti e indietro"
        case .center: return "Dal centro"
        }
    }
}

/// Which of the scene's three colours a track uses.
public enum TrackColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case first, second, third
    /// Colour 1 → 2 → 3 on successive hits.
    case cycle
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .first: return "1"
        case .second: return "2"
        case .third: return "3"
        case .cycle: return "1→2→3"
        }
    }
}

/// How a track combines with the base choreography and the tracks above it.
public enum TrackBlend: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Per channel the strongest value wins (default, never brighter than the brightest source).
    case max
    /// Values add up, limited to full scale.
    case add
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .max: return "Più forte"
        case .add: return "Somma"
        }
    }
}

/// Where a track sends its light. Colour (RGB) and warm white (COB) stay independent.
public struct TrackTarget: Codable, Equatable, Hashable, Sendable {
    public var left: Bool
    public var center: Bool
    public var right: Bool
    /// RGB pixel groups.
    public var color: Bool
    /// Warm COB emitters.
    public var warm: Bool
    /// Centre RGB segments 0…5 (see `RigFrame` geometry). Only used when `center` is on.
    public var segments: [Bool]
    /// Centre COBs 0…2. Only used when `center` is on.
    public var cobs: [Bool]

    public init(left: Bool = true, center: Bool = true, right: Bool = true, color: Bool = true, warm: Bool = false,
                segments: [Bool] = Array(repeating: true, count: RigFrame.centerSegments),
                cobs: [Bool] = Array(repeating: true, count: RigFrame.centerCOBs)) {
        self.left = left; self.center = center; self.right = right
        self.color = color; self.warm = warm
        self.segments = segments; self.cobs = cobs
    }

    public static let all = TrackTarget()
    public static let centerOnly = TrackTarget(left: false, right: false)
    public static let sides = TrackTarget(center: false)

    public enum Zone: String, CaseIterable, Identifiable, Sendable {
        case all, center, sides, left, right
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .all: return "Tutte"
            case .center: return "Centro"
            case .sides: return "Laterali"
            case .left: return "Sinistra"
            case .right: return "Destra"
            }
        }
    }

    /// The quick zone this target matches (nil when it is a custom mix).
    public var zone: Zone? {
        switch (left, center, right) {
        case (true, true, true): return .all
        case (false, true, false): return .center
        case (true, false, true): return .sides
        case (true, false, false): return .left
        case (false, false, true): return .right
        default: return nil
        }
    }

    public mutating func setZone(_ zone: Zone) {
        switch zone {
        case .all: (left, center, right) = (true, true, true)
        case .center: (left, center, right) = (false, true, false)
        case .sides: (left, center, right) = (true, false, true)
        case .left: (left, center, right) = (true, false, false)
        case .right: (left, center, right) = (false, false, true)
        }
    }

    /// Every centre segment and COB selected.
    public var usesWholeCenter: Bool { segments.allSatisfy { $0 } && cobs.allSatisfy { $0 } }

    public var isEmpty: Bool {
        let anyRole = left || right || (center && (segments.contains(true) || cobs.contains(true)))
        return !anyRole || !(color || warm)
    }

    public var sanitized: TrackTarget {
        var t = self
        t.segments = (0..<RigFrame.centerSegments).map { $0 < segments.count ? segments[$0] : true }
        t.cobs = (0..<RigFrame.centerCOBs).map { $0 < cobs.count ? cobs[$0] : true }
        return t
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TrackTarget()
        left = (try? c.decodeIfPresent(Bool.self, forKey: .left)) ?? d.left
        center = (try? c.decodeIfPresent(Bool.self, forKey: .center)) ?? d.center
        right = (try? c.decodeIfPresent(Bool.self, forKey: .right)) ?? d.right
        color = (try? c.decodeIfPresent(Bool.self, forKey: .color)) ?? d.color
        warm = (try? c.decodeIfPresent(Bool.self, forKey: .warm)) ?? d.warm
        segments = (try? c.decodeIfPresent([Bool].self, forKey: .segments)) ?? d.segments
        cobs = (try? c.decodeIfPresent([Bool].self, forKey: .cobs)) ?? d.cobs
        self = sanitized
    }

    private enum CodingKeys: String, CodingKey { case left, center, right, color, warm, segments, cobs }
}

/// One track: a step pattern on the beat grid, a target, a spatial motion and a light envelope.
public struct ProgramTrack: Codable, Equatable, Identifiable, Sendable {
    public static let maxSteps = 32
    public static let maxNameLength = 24
    public static let resolutions = [1, 2, 4]
    public static let lengths = [1, 2, 4, 8, 16]
    public static let rises = [0, 4, 8, 16, 32]
    public static let maxAttack = 4.0, maxHold = 4.0, maxRelease = 8.0
    public static let maxSpread = 1.0, maxOffset = 0.5

    public var id: UUID
    public var name: String
    public var sound: TrackSound
    /// Muted tracks keep their settings but send no light.
    public var enabled: Bool
    /// Steps per beat: 1 quarters, 2 eighths, 4 sixteenths.
    public var stepsPerBeat: Int
    /// Pattern cycle in beats (1, 2, 4, 8, 16), at most `maxSteps` steps.
    public var lengthBeats: Int
    /// Level of each step, 0 = off, 1 = strong; values in between are soft (ghost) hits.
    public var steps: [Double]
    /// Shifts the whole pattern, in beats (−0.5…0.5): negative anticipates.
    public var offset: Double
    public var target: TrackTarget
    public var motion: TrackMotion
    public var direction: TrackDirection
    /// Delay between successive positions of the target, in beats (0…1).
    public var spread: Double
    /// Envelope in beats. The attack ends exactly on the hit, so the peak lands on the step.
    public var attack: Double
    public var hold: Double
    public var release: Double
    /// Level between hits (0…1) and at the peak (0…1, 1 = full 255 before master).
    public var floor: Double
    public var peak: Double
    public var color: TrackColor
    public var blend: TrackBlend
    /// When on, soft steps scale with Energia; strong steps always reach the peak.
    public var softFollowsEnergy: Bool
    /// Rise from 25 % to full over this many beats from the scene start (0 = off, Build-style).
    public var riseBeats: Int

    public init(id: UUID = UUID(), name: String? = nil, sound: TrackSound = .free, enabled: Bool = true,
                stepsPerBeat: Int = 4, lengthBeats: Int = 4, steps: [Double]? = nil, offset: Double = 0,
                target: TrackTarget = .all, motion: TrackMotion = .together, direction: TrackDirection = .forward,
                spread: Double = 0, attack: Double = 0.05, hold: Double = 0.05, release: Double = 0.45,
                floor: Double = 0, peak: Double = 1, color: TrackColor = .first, blend: TrackBlend = .max,
                softFollowsEnergy: Bool = true, riseBeats: Int = 0) {
        self.id = id
        self.name = name ?? sound.title
        self.sound = sound
        self.enabled = enabled
        let safeResolution = Self.resolutions.contains(stepsPerBeat) ? stepsPerBeat : 4
        let safeLength = min(Self.lengths.last { $0 <= max(1, lengthBeats) } ?? 1,
                             Self.maxLength(stepsPerBeat: safeResolution))
        self.stepsPerBeat = safeResolution
        self.lengthBeats = safeLength
        self.steps = steps ?? Array(repeating: 0, count: safeResolution * safeLength)
        self.offset = offset
        self.target = target
        self.motion = motion
        self.direction = direction
        self.spread = spread
        self.attack = attack; self.hold = hold; self.release = release
        self.floor = floor; self.peak = peak
        self.color = color
        self.blend = blend
        self.softFollowsEnergy = softFollowsEnergy
        self.riseBeats = riseBeats
    }

    public var stepCount: Int { stepsPerBeat * lengthBeats }
    public var activeStepCount: Int { steps.filter { $0 > 0 }.count }

    /// Largest allowed length for a resolution.
    public static func maxLength(stepsPerBeat: Int) -> Int {
        lengths.last { $0 * max(1, stepsPerBeat) <= maxSteps } ?? 1
    }

    /// Finite, bounded copy with exactly `stepCount` steps.
    public var sanitized: ProgramTrack {
        var t = self
        t.name = ProgramTrack.cleanName(name, fallback: sound.title)
        if !Self.resolutions.contains(t.stepsPerBeat) { t.stepsPerBeat = 4 }
        if !Self.lengths.contains(t.lengthBeats) { t.lengthBeats = Self.lengths.last { $0 <= max(1, lengthBeats) } ?? 4 }
        t.lengthBeats = min(t.lengthBeats, Self.maxLength(stepsPerBeat: t.stepsPerBeat))
        let n = t.stepCount
        t.steps = (0..<n).map { i in i < steps.count ? unitValue(steps[i], fallback: 0) : 0 }
        t.offset = bounded(offset, -Self.maxOffset, Self.maxOffset, fallback: 0)
        t.target = target.sanitized
        t.spread = bounded(spread, 0, Self.maxSpread, fallback: 0)
        t.attack = bounded(attack, 0, Self.maxAttack, fallback: 0.05)
        t.hold = bounded(hold, 0, Self.maxHold, fallback: 0.05)
        t.release = bounded(release, 0, Self.maxRelease, fallback: 0.45)
        t.peak = unitValue(peak, fallback: 1)
        t.floor = min(unitValue(floor, fallback: 0), t.peak)
        if !Self.rises.contains(t.riseBeats) { t.riseBeats = Self.rises.last { $0 <= max(0, riseBeats) } ?? 0 }
        return t
    }

    static func cleanName(_ raw: String, fallback: String) -> String {
        let scalars = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let words = String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let short = String(words.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? fallback : short
    }

    /// Changes resolution and length keeping every hit at its musical time; a longer cycle repeats the pattern.
    public func resized(stepsPerBeat newRes: Int, lengthBeats newLength: Int) -> ProgramTrack {
        var t = sanitized
        let res = Self.resolutions.contains(newRes) ? newRes : t.stepsPerBeat
        let length = min(Self.lengths.contains(newLength) ? newLength : t.lengthBeats, Self.maxLength(stepsPerBeat: res))
        let old = t.steps, oldRes = t.stepsPerBeat, oldCount = max(1, old.count)
        t.steps = (0..<(res * length)).map { i in
            // Time of the new step in old steps; only exact matches carry a hit.
            let num = i * oldRes
            guard num % res == 0 else { return 0 }
            return old[(num / res) % oldCount]
        }
        t.stepsPerBeat = res
        t.lengthBeats = length
        return t
    }

    /// Moves the pattern by whole steps (positive = later), wrapping around the cycle.
    public func rotated(by k: Int) -> ProgramTrack {
        var t = sanitized
        let n = t.steps.count
        guard n > 0 else { return t }
        let s = ((k % n) + n) % n
        t.steps = Array(t.steps[(n - s)...] + t.steps[..<(n - s)])
        return t
    }

    // Tolerant decoding: unknown or missing fields fall back to defaults instead of dropping the scene.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sound = (try? c.decodeIfPresent(String.self, forKey: .sound)).flatMap(TrackSound.init(rawValue:)) ?? .free
        let d = ProgramTrack(sound: sound)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? d.name
        self.sound = sound
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        stepsPerBeat = (try? c.decodeIfPresent(Int.self, forKey: .stepsPerBeat)) ?? d.stepsPerBeat
        lengthBeats = (try? c.decodeIfPresent(Int.self, forKey: .lengthBeats)) ?? d.lengthBeats
        steps = (try? c.decodeIfPresent([Double].self, forKey: .steps)) ?? []
        offset = (try? c.decodeIfPresent(Double.self, forKey: .offset)) ?? d.offset
        target = (try? c.decodeIfPresent(TrackTarget.self, forKey: .target)) ?? d.target
        motion = (try? c.decodeIfPresent(String.self, forKey: .motion)).flatMap(TrackMotion.init(rawValue:)) ?? d.motion
        direction = (try? c.decodeIfPresent(String.self, forKey: .direction)).flatMap(TrackDirection.init(rawValue:)) ?? d.direction
        spread = (try? c.decodeIfPresent(Double.self, forKey: .spread)) ?? d.spread
        attack = (try? c.decodeIfPresent(Double.self, forKey: .attack)) ?? d.attack
        hold = (try? c.decodeIfPresent(Double.self, forKey: .hold)) ?? d.hold
        release = (try? c.decodeIfPresent(Double.self, forKey: .release)) ?? d.release
        floor = (try? c.decodeIfPresent(Double.self, forKey: .floor)) ?? d.floor
        peak = (try? c.decodeIfPresent(Double.self, forKey: .peak)) ?? d.peak
        color = (try? c.decodeIfPresent(String.self, forKey: .color)).flatMap(TrackColor.init(rawValue:)) ?? d.color
        blend = (try? c.decodeIfPresent(String.self, forKey: .blend)).flatMap(TrackBlend.init(rawValue:)) ?? d.blend
        softFollowsEnergy = (try? c.decodeIfPresent(Bool.self, forKey: .softFollowsEnergy)) ?? d.softFollowsEnergy
        riseBeats = (try? c.decodeIfPresent(Int.self, forKey: .riseBeats)) ?? 0
        self = sanitized
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sound, enabled, stepsPerBeat, lengthBeats, steps, offset, target, motion, direction, spread
        case attack, hold, release, floor, peak, color, blend, softFollowsEnergy, riseBeats
    }
}

/// The animation structure of a scene: up to `maxTracks` tracks over an optional share of the base choreography.
public struct SceneProgram: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxTracks = 8

    /// Schema of this program (additive; unknown fields of newer versions are ignored on read).
    public var version: Int
    /// How much of the original choreography stays under the tracks (0 = only the tracks).
    public var baseLevel: Double
    public var tracks: [ProgramTrack]

    public init(baseLevel: Double = 0, tracks: [ProgramTrack] = []) {
        version = Self.currentVersion
        self.baseLevel = baseLevel
        self.tracks = tracks
    }

    public var sanitized: SceneProgram {
        var p = self
        p.version = Self.currentVersion
        p.baseLevel = unitValue(baseLevel, fallback: 0)
        var seen = Set<UUID>()
        p.tracks = tracks.prefix(Self.maxTracks).map { track in
            var t = track.sanitized
            if !seen.insert(t.id).inserted { t.id = UUID(); seen.insert(t.id) }
            return t
        }
        return p
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        baseLevel = (try? c.decodeIfPresent(Double.self, forKey: .baseLevel)) ?? 0
        // One broken track must not drop the others.
        var list: [ProgramTrack] = []
        if var items = try? c.nestedUnkeyedContainer(forKey: .tracks) {
            while !items.isAtEnd {
                if let track = try? items.decode(ProgramTrack.self) { list.append(track) }
                else { _ = try? items.decode(Skip.self) }
            }
        }
        tracks = list
        self = sanitized
    }

    private struct Skip: Decodable {}
    private enum CodingKeys: String, CodingKey { case version, baseLevel, tracks }
}

// MARK: - Musical starting points

/// Quick fills for the step pattern. They only write steps (and the resolution when needed);
/// everything stays editable afterwards.
public enum PatternFill: String, CaseIterable, Identifiable, Sendable {
    case kick, clap, hat, bass, clear
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .kick: return "Cassa"
        case .clap: return "Clap"
        case .hat: return "Hi-hat"
        case .bass: return "Basso"
        case .clear: return "Libero"
        }
    }

    public var hint: String {
        switch self {
        case .kick: return "Tutti i quarti"
        case .clap: return "Battiti 2 e 4"
        case .hat: return "In levare (ottavi)"
        case .bass: return "Ritmo lungo 3+3+2"
        case .clear: return "Svuota la griglia"
        }
    }

    public func apply(to track: ProgramTrack) -> ProgramTrack {
        var t = track.sanitized
        switch self {
        case .hat where t.stepsPerBeat == 1:
            t = t.resized(stepsPerBeat: 2, lengthBeats: t.lengthBeats)
        case .bass where t.stepsPerBeat == 1:
            t = t.resized(stepsPerBeat: 2, lengthBeats: max(t.lengthBeats, 4))
        default: break
        }
        let res = t.stepsPerBeat
        t.steps = (0..<t.stepCount).map { i in
            let beatPos = Double(i) / Double(res)        // position in beats
            let onBeat = i % res == 0
            switch self {
            case .kick: return onBeat ? 1 : 0
            case .clap: return onBeat && (i / res) % 2 == 1 ? 1 : 0
            case .hat: return i % res == res / 2 ? 1 : 0
            case .bass:
                // 3+3+2 eighths per bar: beats 0, 1.5, 3 of every bar.
                let x = beatPos.truncatingRemainder(dividingBy: 4)
                return [0.0, 1.5, 3.0].contains(where: { abs($0 - x) < 1e-9 }) ? 1 : 0
            case .clear: return 0
            }
        }
        return t
    }
}

extension ProgramTrack {
    /// A ready-to-play track for a musical label (the DJ edits it afterwards).
    public static func template(_ sound: TrackSound) -> ProgramTrack {
        switch sound {
        case .kick:
            return PatternFill.kick.apply(to: ProgramTrack(sound: .kick, stepsPerBeat: 1, lengthBeats: 4,
                                                            target: .centerOnly, attack: 0.04, hold: 0.06, release: 0.6,
                                                            color: .first))
        case .clap:
            return PatternFill.clap.apply(to: ProgramTrack(sound: .clap, stepsPerBeat: 1, lengthBeats: 4,
                                                            target: TrackTarget(left: false, right: false, color: false, warm: true),
                                                            attack: 0.03, hold: 0.05, release: 0.35, color: .third))
        case .hat:
            return PatternFill.hat.apply(to: ProgramTrack(sound: .hat, stepsPerBeat: 2, lengthBeats: 1,
                                                           target: .sides, motion: .alternate, attack: 0.03, hold: 0,
                                                           release: 0.25, color: .third))
        case .bass:
            return PatternFill.bass.apply(to: ProgramTrack(sound: .bass, stepsPerBeat: 2, lengthBeats: 8,
                                                            target: .all, attack: 0.1, hold: 0.3, release: 1.2,
                                                            floor: 0.12, color: .second))
        case .accent:
            var t = ProgramTrack(sound: .accent, stepsPerBeat: 1, lengthBeats: 16,
                                 target: TrackTarget(color: true, warm: true), attack: 0.03, hold: 0.1, release: 1.5,
                                 color: .first)
            t.steps[0] = 1
            return t
        case .free:
            return ProgramTrack(sound: .free, stepsPerBeat: 4, lengthBeats: 4, target: .all, release: 0.4)
        }
    }
}

extension SceneProgram {
    /// Tracks on top of the untouched original choreography: the DJ adds hits without losing the scene.
    public static var overOriginal: SceneProgram {
        SceneProgram(baseLevel: 1, tracks: [.template(.kick)])
    }

    /// The preset rebuilt as editable tracks (an approximation of its movement, not a copy of its maths).
    /// The original choreography is muted (`baseLevel` 0) so every movement comes from the tracks.
    public static func starter(for scene: SceneID) -> SceneProgram {
        func steps(_ n: Int, _ on: [Int], soft: [Int] = []) -> [Double] {
            (0..<n).map { on.contains($0) ? 1 : (soft.contains($0) ? 0.5 : 0) }
        }
        let warmOnly = TrackTarget(color: false, warm: true)
        switch scene {
        case .ambra:
            return SceneProgram(tracks: [
                ProgramTrack(name: "Respiro", sound: .bass, stepsPerBeat: 1, lengthBeats: 8, steps: steps(8, [0]),
                             target: .all, attack: 4, hold: 0, release: 4, floor: 0.45, color: .cycle),
                ProgramTrack(name: "Cassa", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, [0, 1, 2, 3]),
                             target: .centerOnly, attack: 0.15, hold: 0, release: 0.6, floor: 0, peak: 0.85, color: .second),
                ProgramTrack(name: "Onda calda", sound: .free, stepsPerBeat: 1, lengthBeats: 16, steps: steps(16, [0]),
                             target: warmOnly, direction: .forward, spread: 1, attack: 4, hold: 0, release: 6, color: .first),
            ])
        case .sunset:
            return SceneProgram(tracks: [
                ProgramTrack(name: "Fondo", sound: .free, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, []),
                             target: .all, floor: 0.4, color: .first),
                ProgramTrack(name: "Cassa", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, [0, 1, 2, 3]),
                             target: .centerOnly, attack: 0.12, hold: 0, release: 0.5, color: .second),
                ProgramTrack(name: "Levare", sound: .hat, stepsPerBeat: 2, lengthBeats: 1, steps: steps(2, [1]),
                             target: .sides, attack: 0.15, hold: 0, release: 0.45, floor: 0.3, color: .third),
                ProgramTrack(name: "Clap", sound: .clap, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, [0, 2]),
                             target: TrackTarget(left: false, right: false, color: false, warm: true),
                             motion: .alternate, attack: 0.15, hold: 0, release: 0.8, color: .first),
            ])
        case .pulse:
            return SceneProgram(tracks: [
                ProgramTrack(name: "Fondo UV", sound: .free, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, []),
                             target: .centerOnly, floor: 0.16, color: .first),
                ProgramTrack(name: "Colpi 3+3+2", sound: .bass, stepsPerBeat: 2, lengthBeats: 4, steps: steps(8, [0, 3, 6]),
                             target: .centerOnly, motion: .chase, direction: .forward, attack: 0.1, hold: 0, release: 0.5,
                             floor: 0, color: .third),
                ProgramTrack(name: "Hi-hat", sound: .hat, stepsPerBeat: 2, lengthBeats: 1, steps: steps(2, [1]),
                             target: .sides, attack: 0.1, hold: 0, release: 0.3, floor: 0.12, color: .second),
                ProgramTrack(name: "Bianco 1", sound: .accent, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, [0]),
                             target: TrackTarget(left: false, right: false, color: false, warm: true),
                             motion: .chase, attack: 0.1, hold: 0, release: 0.5, color: .first),
            ])
        case .chase:
            return SceneProgram(tracks: [
                ProgramTrack(name: "Corsa", sound: .free, stepsPerBeat: 2, lengthBeats: 4, steps: steps(8, Array(0..<8)),
                             target: .all, motion: .chase, direction: .bounce, attack: 0.1, hold: 0.1, release: 0.7,
                             floor: 0.1, color: .first),
                ProgramTrack(name: "Rullante", sound: .clap, stepsPerBeat: 2, lengthBeats: 1, steps: steps(2, [1]),
                             target: TrackTarget(left: false, right: false, segments: [false, false, true, true, false, false]),
                             attack: 0.1, hold: 0, release: 0.5, color: .second),
                ProgramTrack(name: "Bianco", sound: .accent, stepsPerBeat: 1, lengthBeats: 8, steps: steps(8, [0, 6]),
                             target: TrackTarget(center: false, color: false, warm: true),
                             motion: .alternate, attack: 0.12, hold: 0, release: 0.8, color: .first),
            ])
        case .aurora:
            return SceneProgram(tracks: [
                ProgramTrack(name: "Salita", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, [0, 1, 2, 3]),
                             target: .all, attack: 0.08, hold: 0, release: 0.6, floor: 0.28, color: .cycle, riseBeats: 16),
                ProgramTrack(name: "Rullo", sound: .hat, stepsPerBeat: 4, lengthBeats: 1, steps: steps(4, [0, 2], soft: [1, 3]),
                             target: .centerOnly, motion: .chase, direction: .forward, attack: 0.05, hold: 0, release: 0.2,
                             color: .second, riseBeats: 16),
                ProgramTrack(name: "Bianco", sound: .accent, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, [0]),
                             target: TrackTarget(color: false, warm: true), motion: .chase, direction: .center,
                             attack: 0.1, hold: 0, release: 0.6, color: .first, riseBeats: 16),
            ])
        case .respiro:
            return SceneProgram(tracks: [
                ProgramTrack(name: "Impatto", sound: .accent, stepsPerBeat: 1, lengthBeats: 8, steps: steps(8, [0]),
                             target: TrackTarget(color: true, warm: true), attack: 0.06, hold: 0.1, release: 1.4,
                             color: .third),
                ProgramTrack(name: "Cassa", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, [0, 1, 2, 3]),
                             target: .centerOnly, motion: .chase, attack: 0.06, hold: 0, release: 0.35, floor: 0.06,
                             color: .first),
                ProgramTrack(name: "Levare", sound: .hat, stepsPerBeat: 2, lengthBeats: 2, steps: steps(4, [1, 3]),
                             target: .sides, motion: .alternate, attack: 0.06, hold: 0, release: 0.3, color: .second),
                ProgramTrack(name: "Clap", sound: .clap, stepsPerBeat: 1, lengthBeats: 4, steps: steps(4, [2]),
                             target: TrackTarget(left: false, right: false, color: false, warm: true), motion: .chase,
                             attack: 0.1, hold: 0, release: 0.6, peak: 0.6, color: .first),
            ])
        }
    }
}

// MARK: - Private math

@inline(__always) private func unitValue(_ x: Double, fallback: Double) -> Double { x.isFinite ? min(1, max(0, x)) : fallback }

@inline(__always) private func bounded(_ x: Double, _ lo: Double, _ hi: Double, fallback: Double) -> Double {
    x.isFinite ? min(hi, max(lo, x)) : fallback
}
