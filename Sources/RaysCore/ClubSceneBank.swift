import Foundation

// "Club 130–138" bank: six factory scenes for fast house, garage and rave (130–138 BPM).
// Design intent: the groove, swing, garage shuffle and drive of contemporary club sets, without
// trying to reproduce any real show. Every scene is a track-only `SceneProgram` (`baseLevel` 0),
// so it is fully editable in the scene editor.
//
// Shared stage rules:
// - the centre (TRI 380) holds the kick, the sides (TRI 180) answer on the offbeat;
// - different colours never overlap on the same segments (the "strongest" blend would wash them out);
// - warm COBs only on claps and accents: no static white, no fast white strobe;
// - strong hits at 1 (always full), ghost hits at 0.5 (they follow Energy).

/// The six factory scenes of the Club bank, one per performance slot.
public enum ClubSceneBank {
    /// Built once: stable scene and track ids, identical on every lookup and every launch.
    public static let scenes: [CustomScene] = SceneID.allCases.enumerated().map { make($1, number: $0 + 1) }

    public static func scene(for slot: SceneID) -> CustomScene {
        scenes[SceneID.allCases.firstIndex(of: slot) ?? 0]
    }

    public static func scene(id: UUID) -> CustomScene? { scenes.first { $0.id == id } }

    /// Short card line (Italian), the Club counterpart of `SceneID.subtitle`.
    public static func subtitle(for slot: SceneID) -> String {
        switch slot {
        case .ambra: return "Club · basso 3+3+2"
        case .sunset: return "Club · clave e swing"
        case .pulse: return "Garage · botta e risposta"
        case .chase: return "Rave · corsa 136–138"
        case .aurora: return "Salita · 8 battiti"
        case .respiro: return "Impatto · coda lunga"
        }
    }

    // MARK: - Factory

    private static func make(_ slot: SceneID, number: Int) -> CustomScene {
        let (name, colors, tracks) = design(slot)
        let ids = tracks.indices.map { trackID(scene: number, track: $0 + 1) }
        let program = SceneProgram(baseLevel: 0, tracks: zip(ids, tracks).map { id, track in
            var t = track
            t.id = id
            return t
        })
        return CustomScene(id: sceneID(number), name: name, presetSlot: slot, presetBank: .club, base: slot,
                           colors: colors, energy: 0.7, subdivision: .one, warmth: 1,
                           leftLevel: 1, centerLevel: 1, rightLevel: 1, program: program).sanitized
    }

    static func sceneID(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "13013800-0000-4000-8000-%012d", number))!
    }

    static func trackID(scene: Int, track: Int) -> UUID {
        UUID(uuidString: String(format: "13013800-0000-4000-8%03d-%012d", scene, track))!
    }

    // Swing as a micro-delay of a whole track, in beats (the engine shifts patterns, not single steps).
    private static let laidBack = 0.05     // offbeat 8th sitting behind the beat
    private static let swing16 = 0.06      // off-16ths ≈ 62 % swing

    private static func design(_ slot: SceneID) -> (String, [SceneRGB], [ProgramTrack]) {
        switch slot {
        case .ambra: return pocket
        case .sunset: return shuffle
        case .pulse: return jack
        case .chase: return drive
        case .aurora: return build
        case .respiro: return drop
        }
    }

    /// Pocket: bouncing centre kick, 3+3+2 bass answering top-left/top-right, laid-back offbeat sides.
    private static var pocket: (String, [SceneRGB], [ProgramTrack]) {
        let teal = rgb(0, 0.78, 0.72), amber = rgb(1, 0.52, 0.04), violet = rgb(0.52, 0.12, 1)
        return ("Pocket", [teal, amber, violet], [
            ProgramTrack(name: "Cassa", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [0, 1, 2, 3]),
                         target: centerRGB(lowerSegments), direction: .center, spread: 0.05,
                         attack: 0.04, hold: 0.1, release: 0.55, floor: 0.1, color: .first),
            ProgramTrack(name: "Basso 3+3+2", sound: .bass, stepsPerBeat: 2, lengthBeats: 8,
                         steps: grid(16, [0, 3, 6, 8, 11, 14], soft: [15]),
                         target: centerRGB(topSegments), motion: .alternate,
                         attack: 0.06, hold: 0.2, release: 1.1, floor: 0.08, color: .second),
            ProgramTrack(name: "Levare swing", sound: .hat, stepsPerBeat: 2, lengthBeats: 1, steps: grid(2, [1]),
                         offset: laidBack, target: sidesRGB,
                         attack: 0.05, hold: 0.08, release: 0.32, floor: 0.12, color: .third),
            ProgramTrack(name: "Clap", sound: .clap, stepsPerBeat: 1, lengthBeats: 8, steps: grid(8, [3, 7], soft: [1, 5]),
                         target: centerCOB([0]), attack: 0.03, hold: 0.08, release: 0.4),
            ProgramTrack(name: "Frase", sound: .accent, stepsPerBeat: 1, lengthBeats: 16, steps: grid(16, [0]),
                         target: sidesCOB, attack: 0.05, hold: 0.15, release: 1.6),
        ])
    }

    /// Shuffle: 2-bar clave walking round the centre edges, alternating offbeat sides, swung ghost 16ths.
    private static var shuffle: (String, [SceneRGB], [ProgramTrack]) {
        let violet = rgb(0.55, 0.1, 1), mint = rgb(0.2, 1, 0.62), coral = rgb(1, 0.38, 0.3)
        return ("Shuffle", [violet, mint, coral], [
            ProgramTrack(name: "Cassa", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [0, 1, 2, 3]),
                         target: centerRGB(bottomSegments), attack: 0.04, hold: 0.1, release: 0.5, floor: 0.1, color: .first),
            // Son clave 3-2 in eighths over two bars: beats 0, 1.5, 3 | 5, 6.
            ProgramTrack(name: "Clave", sound: .free, stepsPerBeat: 2, lengthBeats: 8, steps: grid(16, [0, 3, 6, 10, 12]),
                         target: centerRGB(edgeSegments), motion: .chase, direction: .forward,
                         attack: 0.05, hold: 0.12, release: 0.7, floor: 0.06, color: .second),
            ProgramTrack(name: "Levare", sound: .hat, stepsPerBeat: 2, lengthBeats: 2, steps: grid(4, [1, 3]),
                         target: sidesRGB, motion: .alternate,
                         attack: 0.05, hold: 0.08, release: 0.35, floor: 0.1, color: .third),
            ProgramTrack(name: "Ghost swing", sound: .hat, stepsPerBeat: 4, lengthBeats: 1, steps: grid(4, [], soft: [1, 3]),
                         offset: swing16, target: sidesRGB, motion: .alternate,
                         attack: 0.03, hold: 0.03, release: 0.18, color: .third),
            ProgramTrack(name: "Clap", sound: .clap, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [1, 3]),
                         target: centerCOB([1, 2]), motion: .alternate, attack: 0.03, hold: 0.08, release: 0.45),
        ])
    }

    /// Jack: garage bounce. Kick at the bottom, 3+3+2 bass on the middle edges, hats on top,
    /// left asks and right answers.
    private static var jack: (String, [SceneRGB], [ProgramTrack]) {
        let amber = rgb(1, 0.5, 0.02), violet = rgb(0.42, 0.06, 1), ice = rgb(0.55, 0.85, 1)
        return ("Jack", [amber, violet, ice], [
            ProgramTrack(name: "Cassa", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [0, 1, 2, 3]),
                         target: centerRGB(bottomSegments), attack: 0.04, hold: 0.1, release: 0.45, floor: 0.1, color: .second),
            ProgramTrack(name: "Basso 3+3+2", sound: .bass, stepsPerBeat: 2, lengthBeats: 4, steps: grid(8, [0, 3, 6]),
                         target: centerRGB(midSegments), motion: .alternate,
                         attack: 0.05, hold: 0.18, release: 0.8, floor: 0.1, color: .first),
            ProgramTrack(name: "Hi-hat", sound: .hat, stepsPerBeat: 2, lengthBeats: 1, steps: grid(2, [1]),
                         target: centerRGB(topSegments), attack: 0.03, hold: 0.05, release: 0.22, color: .third),
            ProgramTrack(name: "Hat swing", sound: .hat, stepsPerBeat: 4, lengthBeats: 1, steps: grid(4, [], soft: [1, 3]),
                         offset: swing16, target: centerRGB(topSegments), motion: .alternate,
                         attack: 0.02, hold: 0.03, release: 0.15, color: .third),
            ProgramTrack(name: "Domanda", sound: .free, stepsPerBeat: 2, lengthBeats: 8, steps: grid(16, [1, 3, 9, 11]),
                         target: leftRGB, attack: 0.04, hold: 0.08, release: 0.4, floor: 0.08, color: .second),
            ProgramTrack(name: "Risposta", sound: .free, stepsPerBeat: 2, lengthBeats: 8, steps: grid(16, [5, 7, 13, 15], soft: [14]),
                         target: rightRGB, attack: 0.04, hold: 0.08, release: 0.4, floor: 0.08, color: .second),
            ProgramTrack(name: "Clap", sound: .clap, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [1, 3]),
                         target: centerCOB([0]), attack: 0.03, hold: 0.08, release: 0.4),
        ])
    }

    /// Drive: an ice head runs L → R in eighths on bar 1 and R → L on bar 2 with a long tail,
    /// acid punch on every quarter at the centre, UV floor and offbeats. White only on the phrase.
    private static var drive: (String, [SceneRGB], [ProgramTrack]) {
        let acid = rgb(0.55, 1, 0), uv = rgb(0.38, 0, 1), iceBlue = rgb(0.45, 0.78, 1)
        let run = { (name: String, on: [Int], direction: TrackDirection) in
            ProgramTrack(name: name, sound: .free, stepsPerBeat: 2, lengthBeats: 8, steps: grid(16, on),
                         target: .all, motion: .chase, direction: direction,
                         attack: 0.1, hold: 0.08, release: 0.9, color: .third)
        }
        return ("Drive", [acid, uv, iceBlue], [
            ProgramTrack(name: "Fondo UV", sound: .free, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, []),
                         target: .all, floor: 0.14, color: .second),
            run("Corsa →", Array(0..<8), .forward),
            run("Corsa ←", Array(8..<16), .backward),
            ProgramTrack(name: "Punch", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [0, 1, 2, 3]),
                         target: centerRGB(lowerSegments), attack: 0.03, hold: 0.1, release: 0.4, color: .first),
            ProgramTrack(name: "Levare", sound: .hat, stepsPerBeat: 2, lengthBeats: 1, steps: grid(2, [1]),
                         target: sidesRGB, attack: 0.04, hold: 0.06, release: 0.3, color: .second),
            ProgramTrack(name: "Clap", sound: .clap, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [], soft: [1, 3]),
                         target: centerCOB([0]), attack: 0.03, hold: 0.06, release: 0.35),
            ProgramTrack(name: "Stacco", sound: .accent, stepsPerBeat: 1, lengthBeats: 16, steps: grid(16, [0], soft: [8]),
                         target: TrackTarget(color: false, warm: true), attack: 0.05, hold: 0.12, release: 1.4),
        ])
    }

    /// Build +: every track rises from 25 % to full over the first 8 beats after the press.
    /// Centre wave climbs bottom → top on each beat, sides roll L/R in eighths, centre COBs rotate.
    private static var build: (String, [SceneRGB], [ProgramTrack]) {
        let cyan = rgb(0, 0.72, 1), magenta = rgb(1, 0.08, 0.62), gold = rgb(1, 0.72, 0.2)
        return ("Build +", [cyan, magenta, gold], [
            ProgramTrack(name: "Fondo", sound: .free, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, []),
                         target: .all, floor: 0.16, color: .first, riseBeats: 8),
            ProgramTrack(name: "Onda su", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [0, 1, 2, 3]),
                         target: centerRGB(allSegments), direction: .center, spread: 0.12,
                         attack: 0.04, hold: 0.08, release: 0.45, color: .cycle, riseBeats: 8),
            ProgramTrack(name: "Rullo", sound: .hat, stepsPerBeat: 2, lengthBeats: 1, steps: grid(2, [0, 1]),
                         target: sidesRGB, motion: .alternate,
                         attack: 0.04, hold: 0.06, release: 0.32, color: .second, riseBeats: 8),
            ProgramTrack(name: "Giro COB", sound: .free, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [0, 1, 2, 3]),
                         target: centerCOB([0, 1, 2]), motion: .chase, direction: .forward,
                         attack: 0.04, hold: 0.08, release: 0.5, riseBeats: 8),
            ProgramTrack(name: "Battere", sound: .accent, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [0]),
                         target: sidesCOB, attack: 0.04, hold: 0.1, release: 0.8, riseBeats: 8),
        ])
    }

    /// Drop +: dark until the anchored downbeat, then gold on every RGB (long tail) and the three
    /// centre COBs (short tail); then crimson kick quarters, UV offbeats on sides and top edges.
    private static var drop: (String, [SceneRGB], [ProgramTrack]) {
        let crimson = rgb(1, 0.04, 0.1), uv = rgb(0.4, 0, 1), gold = rgb(1, 0.7, 0.32)
        return ("Drop +", [crimson, uv, gold], [
            ProgramTrack(name: "Impatto", sound: .accent, stepsPerBeat: 1, lengthBeats: 16, steps: grid(16, [0], soft: [8]),
                         target: .all, attack: 0.04, hold: 0.25, release: 3, color: .third),
            ProgramTrack(name: "Impatto bianco", sound: .accent, stepsPerBeat: 1, lengthBeats: 16, steps: grid(16, [0]),
                         target: centerCOB([0, 1, 2]), attack: 0.04, hold: 0.12, release: 0.9),
            ProgramTrack(name: "Cassa", sound: .kick, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [0, 1, 2, 3]),
                         target: centerRGB(lowerSegments), attack: 0.04, hold: 0.1, release: 0.42, floor: 0.08, color: .first),
            ProgramTrack(name: "Levare", sound: .hat, stepsPerBeat: 2, lengthBeats: 1, steps: grid(2, [1]),
                         target: sidesRGB, attack: 0.04, hold: 0.08, release: 0.32, floor: 0.06, color: .second),
            ProgramTrack(name: "Scia", sound: .hat, stepsPerBeat: 2, lengthBeats: 2, steps: grid(4, [1, 3]),
                         target: centerRGB(topSegments), motion: .alternate,
                         attack: 0.04, hold: 0.06, release: 0.3, color: .second),
            ProgramTrack(name: "Clap", sound: .clap, stepsPerBeat: 1, lengthBeats: 4, steps: grid(4, [], soft: [1, 3]),
                         target: centerCOB([1, 2]), motion: .alternate, attack: 0.03, hold: 0.06, release: 0.35),
        ])
    }

    // MARK: - Vocabulary

    // Centre segments: 0,1 right edge top→bottom, 2,3 bottom edge, 4,5 left edge bottom→top.
    private static let topSegments = [0, 5], midSegments = [1, 4], bottomSegments = [2, 3]
    private static let lowerSegments = [1, 2, 3, 4], edgeSegments = [0, 1, 4, 5], allSegments = [0, 1, 2, 3, 4, 5]

    private static let sidesRGB = TrackTarget(center: false)
    private static let leftRGB = TrackTarget(center: false, right: false)
    private static let rightRGB = TrackTarget(left: false, center: false)
    private static let sidesCOB = TrackTarget(center: false, color: false, warm: true)

    private static func centerRGB(_ segments: [Int]) -> TrackTarget {
        TrackTarget(left: false, right: false, segments: mask(segments, RigFrame.centerSegments))
    }

    private static func centerCOB(_ cobs: [Int]) -> TrackTarget {
        TrackTarget(left: false, right: false, color: false, warm: true, cobs: mask(cobs, RigFrame.centerCOBs))
    }

    private static func mask(_ on: [Int], _ count: Int) -> [Bool] { (0..<count).map(on.contains) }

    /// Strong steps are 1 (always full), soft steps 0.5 (scaled by Energia).
    private static func grid(_ count: Int, _ strong: [Int], soft: [Int] = []) -> [Double] {
        (0..<count).map { strong.contains($0) ? 1 : (soft.contains($0) ? 0.5 : 0) }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> SceneRGB { SceneRGB(r: r, g: g, b: b) }
}
