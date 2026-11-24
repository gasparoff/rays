import Foundation
import RaysCore
import RaysOutput
import XCTest

/// Golden frames for the classic three-position rig (ADR 0005, step 1).
///
/// Every built-in scene, the club bank and representative custom and program scenes are rendered the
/// way `LightEngine` renders them: `SceneSequencer` (layers, looks, fades) → `RigFrame` → one
/// `FixtureLevels` per patched fixture from its role, COBs × white level, scale = master × role level →
/// `DMXComposer` universes. Each entry hashes (FNV-1a 64) every DMX byte of every frame over a sweep of
/// beats and energies, so any change to a single byte of any frame changes a hash.
///
/// The rig refactor of ADR 0005 must keep this table unchanged. After an intended change to a scene,
/// regenerate it with `RAYS_PRINT_GOLDEN=1 swift test --filter GoldenFrameTests` and paste the
/// printed literal over `expected`, explaining the change in the pull request.
final class GoldenFrameTests: XCTestCase {
    // MARK: Inputs

    struct Rig: Sendable {
        var name: String
        var patch: Patch
    }

    struct Levels: Sendable {
        var name: String
        var master: Double
        var left: Double, center: Double, right: Double
        var white: Double

        func level(_ role: FixtureRole) -> Double {
            switch role {
            case .left: return left
            case .center: return center
            case .right: return right
            }
        }
    }

    /// A scripted launch: at `beat` (or the first frame after it) request `scene` with `look`, or Stop when nil.
    struct Cue: Sendable {
        var beat: Double
        var scene: SceneID?
        var look: CustomScene? = nil
    }

    struct Case: Sendable {
        var name: String
        var scene: SceneID
        var look: CustomScene? = nil
        var rate: Double = 1
        var cues: [Cue] = []
    }

    static let library = ProfileLibrary()
    static let bpm = 120.0
    /// 34 beats in eighths: covers the 16-beat Build rise, 4-bar phrases and the Drop downbeat.
    static let beats = (0..<272).map { Double($0) / 8 }
    static let energies = [0.2, 0.7, 1.0]

    /// The classic rig: the reference 2× TRI 180 8CH + TRI 380 25CH with explicit roles, and the
    /// 5-channel modes with automatic roles (the centre's six segments averaged into one).
    static let rigs = [
        Rig(name: "reference", patch: VarytecRig.referenceRig()),
        Rig(
            name: "compact",
            patch: Patch(fixtures: [
                PatchedFixture(label: "L", profileID: "varytec.tri180.5", universe: 1, address: 1),
                PatchedFixture(label: "C", profileID: "varytec.tri380.5", universe: 1, address: 11),
                PatchedFixture(label: "R", profileID: "varytec.tri180.5", universe: 1, address: 6),
            ])),
    ]

    static let levels = [
        Levels(name: "full", master: 1, left: 1, center: 1, right: 1, white: 1),
        Levels(name: "trim", master: 0.8, left: 0.5, center: 0.9, right: 0.3, white: 0.6),
    ]

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "601DE000-0000-4000-8000-%012ld", n))!
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> SceneRGB { SceneRGB(r: r, g: g, b: b) }

    /// Every track motion, direction, colour mode and blend, a rise, an offset, a muted track and
    /// partial segment/COB masks, over 40 % of the base choreography.
    static var motionProgram: SceneProgram {
        let maskTarget = TrackTarget(
            left: false, right: false, color: true, warm: true,
            segments: [true, false, true, false, true, false], cobs: [false, true, false])
        return SceneProgram(
            baseLevel: 0.4,
            tracks: [
                ProgramTrack(
                    name: "Bounce", stepsPerBeat: 2, lengthBeats: 2, steps: [1, 0, 1, 0.5], target: .all,
                    motion: .chase, direction: .bounce, color: .cycle),
                .template(.hat),
                ProgramTrack(
                    name: "Out", stepsPerBeat: 1, lengthBeats: 4, steps: [1, 0, 0, 0], target: .centerOnly,
                    direction: .center, spread: 0.25, color: .second, blend: .add),
                ProgramTrack(
                    name: "Warm back", stepsPerBeat: 1, lengthBeats: 4, steps: [1, 1, 0.5, 0], offset: -0.1,
                    target: TrackTarget(color: false, warm: true), motion: .chase, direction: .backward,
                    color: .third),
                ProgramTrack(
                    name: "Rise", stepsPerBeat: 4, lengthBeats: 1, steps: [1, 0, 0.5, 0], target: .sides,
                    motion: .alternate, floor: 0.1, peak: 0.8, softFollowsEnergy: false, riseBeats: 8),
                ProgramTrack(
                    name: "Mask", stepsPerBeat: 2, lengthBeats: 4, steps: [1, 0, 0, 1, 0, 0, 1, 0], target: maskTarget,
                    direction: .forward, spread: 0.5, attack: 0.2, hold: 0.1, release: 1),
                ProgramTrack(
                    name: "Muted", enabled: false, stepsPerBeat: 1, lengthBeats: 1, steps: [1], target: .all),
            ])
    }

    static var cases: [Case] {
        var out: [Case] = SceneID.allCases.map { Case(name: "house.\($0.rawValue)", scene: $0) }
        out += SceneID.allCases.map { Case(name: "club.\($0.rawValue)", scene: $0, look: ClubSceneBank.scene(for: $0)) }
        let recolor = CustomScene(
            id: uuid(1), name: "Recolor", base: .pulse, colors: [rgb(0, 1, 0.4), rgb(1, 0, 0.8), rgb(0.2, 0.3, 1)],
            energy: 0.6, subdivision: .one, warmth: 0.4)
        out.append(Case(name: "custom.recolor", scene: .pulse, look: recolor))
        let slow = CustomScene(
            id: uuid(2), name: "Slow", base: .chase, colors: [rgb(1, 0.2, 0), rgb(0, 0.5, 1), rgb(1, 1, 1)],
            subdivision: .two, warmth: 1)
        out.append(Case(name: "custom.slow", scene: .chase, look: slow, rate: Subdivision.two.rate))
        let over = CustomScene(id: uuid(3), name: "Over", base: .sunset, program: .overOriginal)
        out.append(Case(name: "program.overOriginal", scene: .sunset, look: over))
        for (n, scene) in SceneID.allCases.enumerated() {
            let starter = CustomScene(id: uuid(10 + n), name: "Starter", base: scene, program: .starter(for: scene))
            out.append(Case(name: "program.starter.\(scene.rawValue)", scene: scene, look: starter))
        }
        let motion = CustomScene(id: uuid(4), name: "Motion", base: .ambra, warmth: 0.7, program: motionProgram)
        out.append(Case(name: "program.motion", scene: .ambra, look: motion))
        // Launches on the grid: next-beat start, a bank change, the anchored Drop and Stop.
        out.append(
            Case(
                name: "sequence", scene: .ambra,
                cues: [
                    Cue(beat: 4.3, scene: .chase),
                    Cue(beat: 10.6, scene: .pulse, look: ClubSceneBank.scene(for: .pulse)),
                    Cue(beat: 17.2, scene: .respiro),
                    Cue(beat: 26.5, scene: nil),
                ]))
        return out
    }

    // MARK: Rendering (mirrors LightEngine.rigFrame and LightEngine.compose)

    static func universes(_ frame: RigFrame, rig: Rig, roles: [FixtureRole], levels: Levels) -> [PortAddress: [UInt8]] {
        let fixtureLevels = roles.map { role in
            FixtureLevels(rgb: frame[role].rgb, cob: frame[role].cob.map { $0 * levels.white })
        }
        let scales = roles.map { levels.master * levels.level($0) }
        return DMXComposer.compose(patch: rig.patch, library: library, levels: fixtureLevels, scales: scales, blackout: false)
    }

    struct FNV1a64 {
        private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
        mutating func add(_ byte: UInt8) { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
    }

    /// Hash of every frame of `c` on `rig` with `levels`, and whether any byte was above 0.
    static func golden(_ c: Case, rig: Rig, levels: Levels) -> (hash: UInt64, lit: Bool) {
        let roles = rig.patch.roles(library: library)
        var hash = FNV1a64()
        var lit = false
        for energy in energies {
            var sequencer = SceneSequencer(scene: c.scene, rate: c.rate)
            if let look = c.look { sequencer.setLook(SceneLook(look)) }
            var cues = c.cues[...]
            for beat in beats {
                let now = beat * 60 / bpm
                while let cue = cues.first, cue.beat <= beat {
                    if let scene = cue.scene {
                        sequencer.request(scene, look: cue.look.map(SceneLook.init), beat: beat, now: now, gridTrusted: true)
                    } else {
                        sequencer.stop(beat: beat, now: now, gridTrusted: true)
                    }
                    cues = cues.dropFirst()
                }
                sequencer.advance(beat: beat, bpm: bpm, now: now, gridTrusted: true)
                let frame = sequencer.render(beat: beat, energy: energy, now: now)
                let dmx = universes(frame, rig: rig, roles: roles, levels: levels)
                for address in dmx.keys.sorted() {
                    hash.add(UInt8(address.rawValue & 0xFF))
                    hash.add(UInt8(address.rawValue >> 8))
                    for byte in dmx[address]! {
                        hash.add(byte)
                        if byte > 0 { lit = true }
                    }
                }
            }
        }
        return (hash.value, lit)
    }

    static func table() -> [(key: String, hash: UInt64, lit: Bool)] {
        var out: [(key: String, hash: UInt64, lit: Bool)] = []
        for c in cases {
            for rig in rigs {
                for lv in Self.levels {
                    let g = golden(c, rig: rig, levels: lv)
                    out.append(("\(c.name)|\(rig.name)|\(lv.name)", g.hash, g.lit))
                }
            }
        }
        return out
    }

    static func literal(_ rows: [(key: String, hash: UInt64, lit: Bool)]) -> String {
        let lines = rows.map { "        \"\($0.key)\": 0x\(String(format: "%016llx", $0.hash))," }
        return (["    static let expected: [String: UInt64] = ["] + lines + ["    ]"]).joined(separator: "\n")
    }

    // MARK: Tests

    func testClassicRigFramesMatchTheGoldenTable() {
        let rows = Self.table()
        if ProcessInfo.processInfo.environment["RAYS_PRINT_GOLDEN"] == "1" {
            print("GOLDEN-TABLE-BEGIN (\(rows.count) entries)\n\(Self.literal(rows))\nGOLDEN-TABLE-END")
            return
        }
        XCTAssertEqual(Set(rows.map(\.key)).count, rows.count, "unique keys")
        XCTAssertEqual(Set(rows.map(\.key)), Set(Self.expected.keys), "golden table keys")
        for row in rows {
            XCTAssertTrue(row.lit, "\(row.key): every case must light something")
            guard let expected = Self.expected[row.key] else { continue }
            XCTAssertEqual(
                String(format: "%016llx", row.hash), String(format: "%016llx", expected),
                "\(row.key): DMX output changed on the classic rig")
        }
    }

    func testGoldenHashesAreDeterministic() {
        let c = Self.cases.last!
        let first = Self.golden(c, rig: Self.rigs[0], levels: Self.levels[1])
        let second = Self.golden(c, rig: Self.rigs[0], levels: Self.levels[1])
        XCTAssertEqual(first.hash, second.hash)
        XCTAssertTrue(first.lit)
    }

    func testFNV1a64MatchesTheReferenceVectors() {
        var empty = FNV1a64()
        XCTAssertEqual(empty.value, 0xcbf2_9ce4_8422_2325)
        empty.add(UInt8(ascii: "a"))
        XCTAssertEqual(empty.value, 0xaf63_dc4c_8601_ec8c)
    }

    // MARK: Golden table (generated, see the type comment)

    static let expected: [String: UInt64] = [:]
}
