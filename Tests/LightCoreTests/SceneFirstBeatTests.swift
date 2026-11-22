import XCTest
@testable import LightCore

final class SceneFirstBeatTests: XCTestCase {
    func testRestartsWholeLongProgramAtEveryMovementRate() throws {
        for rate in [0.25, 0.5, 1, 2] {
            var scene = ClubSceneBank.scene(for: .ambra)
            scene.program = SceneProgram(tracks: [ProgramTrack(stepsPerBeat: 1, lengthBeats: 16,
                steps: [1] + Array(repeating: 0, count: 15), target: .all, attack: 0.06, hold: 0.1, release: 0.2)])
            var seq = SceneSequencer(scene: .ambra, rate: rate)
            seq.setLook(SceneLook(scene))
            seq.advance(beat: 119, bpm: 120, now: 0, gridTrusted: true)
            seq.restartCurrentScene(at: 119)
            XCTAssertEqual(try XCTUnwrap(seq.patternBeat(beat: 119)), 0, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(seq.patternBeat(beat: 120)), rate, accuracy: 1e-9)
            XCTAssertEqual(seq.currentSceneLook, scene)
            let expected = SceneLook(scene).render(.ambra, SceneContext(beat: 0, phrase: 0, energy: 0.7, minAttack: 0.06 * rate))
            XCTAssertEqual(seq.render(beat: 119, energy: 0.7, now: 0), expected)
            XCTAssertEqual(seq.currentSceneBeatAnchor, 0)
        }
    }

    func testOriginalChoreographyRestartsWithoutConvertingLegacyProgram() {
        let legacy = CustomScene(name: "Legacy", base: .chase, program: nil)
        var seq = SceneSequencer(scene: .chase)
        let look = SceneLook(legacy)
        seq.setLook(look)
        seq.restartCurrentScene(at: 123.7)
        XCTAssertNil(seq.currentSceneLook?.program)
        XCTAssertEqual(seq.render(beat: 123.7, energy: 0.5, now: 0),
            look.render(.chase, SceneContext(beat: 0, phrase: 0, energy: 0.5)))
    }

    func testDropRestartsItsPhraseAndKeepsGestureRateLock() throws {
        var seq = SceneSequencer(scene: .ambra, rate: 0.25)
        seq.request(.respiro, beat: 115.95, now: 0, gridTrusted: true, rateOverride: 1, forceRestart: true)
        seq.advance(beat: 116, bpm: 120, now: 0.025, gridTrusted: true)
        seq.restartCurrentScene(at: 116)
        XCTAssertEqual(try XCTUnwrap(seq.patternBeat(beat: 116)), 0)
        XCTAssertEqual(try XCTUnwrap(seq.patternBeat(beat: 117)), 1)
        XCTAssertTrue(seq.isRateLocked)
        XCTAssertEqual(seq.targetScene, .respiro)
    }

    func testStopAndPendingLaunchKeepTheirMeaning() {
        var seq = SceneSequencer(scene: .pulse)
        seq.request(.chase, beat: 100.2, now: 0, gridTrusted: true)
        XCTAssertEqual(seq.pendingScene, .chase)
        seq.restartCurrentScene(at: 100.2)
        XCTAssertEqual(seq.targetScene, .pulse)
        XCTAssertEqual(seq.pendingScene, .chase)
        seq.stop(beat: 100.2, now: 0, gridTrusted: true)
        seq.restartCurrentScene(at: 100.2)
        XCTAssertTrue(seq.isStopped)
        XCTAssertNil(seq.patternBeat(beat: 100.2))
    }

    func testEngineReconcilesGridJumpAndStartsSceneWithoutChangingOutputOrSource() throws {
        for pressTime in [61.875, 60.75] { // small correction and a −1.5 beat jump
        let clock = ManualClock()
        let source = LocalTempoClock(bpm: 120, now: { clock.now })
        let grid = DownbeatTempoSource(source: source)
        let transport = FakeTransport()
        let engine = LightEngine(tempo: grid, transport: transport, clock: { clock.now }, runsTimer: false)
        engine.setScene(.ambra, look: ClubSceneBank.scene(for: .ambra), immediate: true)
        engine.setBlackout(true)
        var snap = EngineSnapshot()
        engine.onSnapshot = { snap = $0 }
        clock.now = pressTime
        engine.stepForTesting()
        let before = source.capture()
        let origin = try XCTUnwrap(grid.setDownbeat())
        engine.restartScene(at: origin)
        engine.stepForTesting()
        XCTAssertEqual(source.capture(), before)
        XCTAssertEqual(snap.tempo.phase, 0, accuracy: 1e-9)
        let lead = LightEngine.outputLatency * 120 / 60
        XCTAssertEqual(try XCTUnwrap(snap.patternBeat), lead, accuracy: 1e-9)
        clock.now += 0.5
        engine.stepForTesting()
        XCTAssertEqual(try XCTUnwrap(snap.patternBeat), 1 + lead, accuracy: 1e-9)
        XCTAssertTrue(snap.blackout)
        XCTAssertFalse(snap.armed)
        XCTAssertTrue(transport.dmxPackets.isEmpty)
        }
    }
    func testLargeAlignmentKeepsNextSceneQueuedOnCorrectedGrid() throws {
        let clock = ManualClock()
        let source = LocalTempoClock(bpm: 120, now: { clock.now })
        let grid = DownbeatTempoSource(source: source)
        let engine = LightEngine(tempo: grid, transport: FakeTransport(), clock: { clock.now }, runsTimer: false)
        engine.setScene(.ambra, look: ClubSceneBank.scene(for: .ambra), immediate: true)
        engine.setExternalBeatGrid(true)
        var snap = EngineSnapshot()
        engine.onSnapshot = { snap = $0 }
        clock.now = 60.75 // source beat 121.5
        engine.stepForTesting()
        engine.setScene(.chase)
        engine.sync {}
        let origin = try XCTUnwrap(grid.setDownbeat()) // corrected beat 120
        engine.restartScene(at: origin)
        engine.stepForTesting()
        XCTAssertEqual(snap.scene, .ambra)
        XCTAssertEqual(snap.pendingScene, .chase)
        XCTAssertEqual(try XCTUnwrap(snap.patternBeat), 0.08, accuracy: 1e-9)
        clock.now += 0.5 // corrected beat 121: pending launch still happens on the next beat
        engine.stepForTesting()
        XCTAssertEqual(snap.scene, .chase)
        XCTAssertNil(snap.pendingScene)
    }

}
