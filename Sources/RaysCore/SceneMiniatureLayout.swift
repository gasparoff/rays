import Foundation

/// A small, static score of the running lighting scene. Prepared only when its source or
/// viewport changes; the live cursor uses the engine's patternBeat separately.
public struct SceneMiniatureLayout: Equatable, Sendable {
    /// One hit drawn in a lane.
    public struct Mark: Equatable, Sendable {
        public var beat: Double
        public var duration: Double
        public var level: Double
    }

    /// One track row of the miniature.
    public struct Lane: Equatable, Sendable {
        public var name: String
        public var color: SceneRGB
        public var enabled: Bool
        public var marks: [Mark]
        /// Legacy scenes use actual sampled light envelopes, rather than inventing track steps.
        public var waveform: [Double]
    }

    public let span: Double
    public let startBeat: Double
    public let lanes: [Lane]
    public let usesTracks: Bool

    public init(scene: SceneID, look: CustomScene?, windowStart: Double = 0, phraseAnchor: Double = 0, energy: Double = 0.7) {
        let clean = look?.sanitized
        let anchor = phraseAnchor.isFinite ? phraseAnchor : 0
        let strength = energy.isFinite ? min(1, max(0, energy)) : 0.7
        if let program = clean?.program {
            usesTracks = true
            startBeat = 0
            span = Double(max(4, program.tracks.map(\.lengthBeats).max() ?? 4))
            let palette = clean?.colors ?? CustomScene.defaultColors(for: scene)
            var rows: [Lane] = []
            for track in program.tracks {
                let cycle = Double(track.lengthBeats)
                var marks: [Mark] =
                    track.floor > 0
                    ? [Mark(beat: 0, duration: span, level: track.floor)] : []
                // Patterns are powers of two, so every visible repeat fits the longest cycle.
                for repeatIndex in -1...Int(span / cycle) {
                    for (step, level) in track.steps.enumerated() where level > 0 {
                        let beat = Double(repeatIndex) * cycle + Double(step) / Double(track.stepsPerBeat) + track.offset
                        guard beat >= 0, beat < span else { continue }
                        marks.append(Mark(beat: beat, duration: min(0.7, max(0.12, track.hold + track.release * 0.35)), level: level))
                    }
                }
                let color: SceneRGB
                if !track.target.color {
                    color = SceneRGB(r: 1, g: 0.69, b: 0.32)
                } else {
                    let i = track.color == .second ? 1 : (track.color == .third ? 2 : 0)
                    color = palette[i]
                }
                rows.append(
                    Lane(
                        name: track.name, color: color, enabled: track.enabled && !track.target.isEmpty,
                        marks: marks.sorted { $0.beat < $1.beat }, waveform: []))
            }
            if program.baseLevel > 0 {
                let wave = Self.sample(scene: scene, start: 0, span: span, anchor: anchor, energy: strength).map { $0 * program.baseLevel }
                rows.insert(
                    Lane(
                        name: "Base \(scene.title)", color: SceneRGB(r: 0.65, g: 0.57, b: 0.9),
                        enabled: true, marks: [], waveform: wave), at: 0)
            }
            lanes = rows
        } else {
            usesTracks = false
            span = 16
            startBeat = windowStart.isFinite ? windowStart : 0
            let prepared = clean.map(SceneLook.init)
            var waves = Array(repeating: [Double](), count: 3)
            for index in 0..<96 {
                let beat = startBeat + Double(index) / 96 * span
                let ctx = Self.context(scene: scene, time: beat, anchor: anchor, energy: strength)
                let frame = prepared?.render(scene, ctx) ?? Choreography.render(scene, ctx)
                for (i, role) in FixtureRole.allCases.enumerated() {
                    let f = frame[role]
                    waves[i].append(max(f.rgb.map(\.peak).max() ?? 0, f.cob.max() ?? 0))
                }
            }
            let palette = clean?.colors ?? CustomScene.defaultColors(for: scene)
            lanes = zip([String(localized: "Left"), String(localized: "Center"), String(localized: "Right")], waves).enumerated().map { index, item in
                Lane(name: item.0, color: palette[index], enabled: true, marks: [], waveform: item.1)
            }
        }
    }

    private static func context(scene: SceneID, time: Double, anchor: Double, energy: Double) -> SceneContext {
        scene == .respiro
            ? SceneContext(beat: time + anchor, phrase: time, energy: energy)
            : SceneContext(beat: time, phrase: time - anchor, energy: energy)
    }

    private static func sample(scene: SceneID, start: Double, span: Double, anchor: Double, energy: Double) -> [Double] {
        (0..<96).map { i in
            let beat = start + Double(i) / 96 * span
            let ctx = context(scene: scene, time: beat, anchor: anchor, energy: energy)
            let f = Choreography.render(scene, ctx)
            return FixtureRole.allCases.map { role in max(f[role].rgb.map(\.peak).max() ?? 0, f[role].cob.max() ?? 0) }.max() ?? 0
        }
    }

    public static func cursor(beat: Double?, scene: SceneID, span: Double) -> Double? {
        guard let beat, beat.isFinite, span.isFinite, span > 0 else { return nil }
        // A pending Drop must not appear at the end of a fictitious previous cycle.
        guard scene != .respiro || beat >= 0 else { return nil }
        let remainder = beat.truncatingRemainder(dividingBy: span)
        return (remainder < 0 ? remainder + span : remainder) / span
    }
}
