import XCTest
@testable import RaysCore
@testable import RaysControl

final class PerformanceControlsTests: XCTestCase {
    private func event(_ kind: MIDIControl.Kind, _ number: UInt8, _ value: UInt8, channel: UInt8 = 14) -> MIDIEvent {
        MIDIEvent(control: .init(kind, channel: channel, number: number), value: value, isNoteOn: kind == .note && value > 0)
    }
    func testK2PresetSoftTakeoverAndRelativeLearn() {
        var router = MIDIRouter()
        XCTAssertEqual(router.handle(event(.note, 35, 0), fromK2: true), .none, "Unmatched release must not launch Drop")
        XCTAssertEqual(router.handle(event(.note, 35, 127), fromK2: true), .command(.buildHold(true)))
        XCTAssertEqual(router.handle(event(.note, 35, 127), fromK2: true), .none, "Held notes never restart Build")
        XCTAssertEqual(router.handle(event(.note, 35, 0), fromK2: true), .command(.buildHold(false)))
        XCTAssertEqual(router.handle(event(.cc, 19, 0), fromK2: true, current: { _ in 0.8 }), .waiting(.master, 0))
        XCTAssertEqual(router.handle(event(.cc, 19, 127), fromK2: true, current: { _ in 0.8 }), .command(.master(1)), "Crossing takes over")
        router.resetTakeover(.master)
        XCTAssertEqual(router.handle(event(.cc, 19, 0), fromK2: true, current: { _ in 0.8 }), .waiting(.master, 0))
        router.learning = .energy
        _ = router.handle(event(.cc, 20, 1), fromK2: true)
        XCTAssertEqual(router.handle(event(.cc, 20, 127), fromK2: true, current: { _ in 0.5 }), .command(.energy(0.49)))
        XCTAssertEqual(router.handle(event(.cc, 20, 1), fromK2: true, current: { _ in 0.5 }), .command(.energy(0.51)))
    }
    func testGestureRateOverrideDoesNotChangeTheUsersMovementRate() {
        var sequence = SceneSequencer(scene: .ambra, rate: 0.25)
        sequence.request(.respiro, beat: 32.08, now: 16, gridTrusted: true, rateOverride: 1, forceRestart: true)
        sequence.advance(beat: 32.08, bpm: 120, now: 16, gridTrusted: true)
        XCTAssertEqual(sequence.rate, 0.25)
        sequence.setRate(0.5, beat: 32.08, now: 16)
        XCTAssertEqual(sequence.rate, 0.5, "The future scene preference can change")
        XCTAssertTrue(sequence.isRateLocked)
        let actual = sequence.render(beat: 32.08, energy: 1, now: 16)
        let expected = Choreography.render(.respiro, SceneContext(beat: 32.08, phrase: 0.08, energy: 1))
        for (a, b) in zip(actual.center.cob, expected.center.cob) { XCTAssertEqual(a, b, accuracy: 0.00001) }
    }

    func testConsoleDownbeatReleaseDoesNotWaitAFullBar() {
        var sequencer = SceneSequencer(scene: .aurora)
        sequencer.request(.respiro, beat: 32.08, now: 16.04, gridTrusted: true)
        XCTAssertNil(sequencer.pendingScene)
        XCTAssertEqual(sequencer.targetScene, .respiro)
        let frame = sequencer.render(beat: 32.08, energy: 1, now: 16.04)
        XCTAssertGreaterThan(frame.center.cob.max()!, 0.1)
    }
    func testChoreographiesUseIndependentSegmentsAndRemainBounded() {
        for scene in SceneID.allCases {
            for beat in [-1e9, -4, 0, 0.5, 16, 31.9, 1e9, .nan, .infinity] {
                for energy in [0.0, 0.5, 1, .nan] {
                    let frame = Choreography.render(scene, SceneContext(beat: beat, phrase: beat, energy: energy))
                    XCTAssertTrue(frame.isFinite)
                    XCTAssertEqual(frame.center.rgb.count, 6)
                    XCTAssertEqual(frame.center.cob.count, 3)
                    XCTAssertTrue(frame.center.cob.allSatisfy { (0...1).contains($0) })
                    XCTAssertTrue((frame.left.cob + frame.right.cob).allSatisfy { (0...1).contains($0) })
                }
            }
        }
        let frame = Choreography.render(.ambra, SceneContext(beat: 2, energy: 1))
        XCTAssertGreaterThan(Set(frame.center.rgb.map { [$0.r, $0.g, $0.b] }).count, 1)
    }
    func testCustomScenePersistenceClampingAndUnreadableProtection() throws {
        var scene = CustomScene(name: " \n  Club\tRosso  ", energy: .nan, warmth: 4, leftLevel: -1)
        scene.colors = [SceneRGB(r: 1, g: 0, b: 0)]
        let clean = scene.sanitized
        XCTAssertEqual(clean.name, "Club Rosso")
        XCTAssertEqual(clean.energy, 0.5)
        XCTAssertEqual(clean.warmth, 1)
        XCTAssertEqual(clean.leftLevel, 0)
        XCTAssertEqual(clean.colors.count, 3)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = CustomSceneFile(directory: directory)
        try file.save([clean])
        XCTAssertEqual(try file.load(), [clean])
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: file.url)
        XCTAssertThrowsError(try file.load())
        XCTAssertEqual(try Data(contentsOf: file.url), corrupt)
    }
    func testSequencerRecoversFromClockJumpsAndStopDoesNotRelight() {
        var sequence = SceneSequencer()
        sequence.request(.aurora, beat: 3, now: 1.5, gridTrusted: true)
        for (beat, time) in [(3.0, 1.5), (-20.0, 1.6), (50.0, 1.7), (.nan, 2.0), (60.0, 10.0)] {
            sequence.advance(beat: beat, bpm: 128, now: time, gridTrusted: true)
            XCTAssertTrue(sequence.render(beat: beat, energy: 1, now: time).isFinite)
        }
        sequence.stop(beat: 60, now: 10, gridTrusted: true)
        sequence.advance(beat: 61, bpm: 128, now: 11, gridTrusted: true)
        XCTAssertTrue(sequence.isStopped)
        XCTAssertEqual(sequence.render(beat: 61, energy: 1, now: 11), .black)
    }
}
