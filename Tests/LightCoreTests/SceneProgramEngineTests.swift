import XCTest
@testable import LightCore

/// Program tracks through the real engine, sequencer and DMX composer (no UI, no hardware).
final class SceneProgramEngineTests: XCTestCase {
    let red = SceneRGB(r: 1, g: 0, b: 0), green = SceneRGB(r: 0, g: 1, b: 0), blue = SceneRGB(r: 0, g: 0, b: 1)

    /// Constant light: no steps, floor = peak.
    func steady(_ target: TrackTarget, level: Double = 1, color: TrackColor = .first) -> ProgramTrack {
        ProgramTrack(stepsPerBeat: 1, lengthBeats: 4, steps: [0, 0, 0, 0], target: target, floor: level, peak: level, color: color)
    }

    func custom(_ tracks: [ProgramTrack], base: SceneID = .ambra, slot: SceneID? = nil, colors: [SceneRGB]? = nil,
                warmth: Double = 1) -> CustomScene {
        CustomScene(name: "Prog", presetSlot: slot, base: base, colors: colors ?? [red, green, blue], warmth: warmth,
                    program: SceneProgram(tracks: tracks))
    }

    func makeEngine(_ clock: ManualClock) -> (LightEngine, () -> EngineSnapshot) {
        clock.now = 0
        let engine = LightEngine(tempo: LocalTempoClock(bpm: 120, now: { clock.now }), transport: FakeTransport(),
                                 clock: { clock.now }, runsTimer: false)
        var patch = VarytecRig.referenceRig()
        patch.setConfirmed(true, library: ProfileLibrary())
        engine.setPatch(patch)
        engine.setMaster(1)
        var snap = EngineSnapshot()
        engine.onSnapshot = { snap = $0 }
        return (engine, { snap })
    }

    func rgb(_ s: EngineSnapshot) -> [LightColor] { s.fixtures.flatMap(\.rgb) }
    func cob(_ s: EngineSnapshot) -> [Double] { s.fixtures.flatMap(\.cob) }

    func testMasterWhiteZonesAndBlackoutStillGovernProgramTracksWithFullPeaks() {
        let clock = ManualClock()
        let (engine, snap) = makeEngine(clock)
        engine.setEnergy(0)
        let both = custom([steady(TrackTarget(color: true, warm: true))])
        engine.setScene(.pulse, look: both, immediate: true)
        clock.now = 1; engine.stepForTesting()
        XCTAssertEqual(snap().fixtures.count, 3)
        XCTAssertTrue(rgb(snap()).allSatisfy { $0 == LightColor(1, 0, 0) }, "every segment 255 red at energy 0, master 100%")
        XCTAssertTrue(cob(snap()).allSatisfy { $0 == 1 }, "every COB 255, no historical cap")

        engine.setWhiteLevel(0); clock.now = 1.1; engine.stepForTesting()
        XCTAssertTrue(cob(snap()).allSatisfy { $0 == 0 }, "Bianco COB 0 silences warm tracks")
        XCTAssertTrue(rgb(snap()).allSatisfy { $0.r == 1 }, "and leaves RGB alone")
        engine.setWhiteLevel(1)

        engine.setMaster(0.5); clock.now = 1.2; engine.stepForTesting()
        XCTAssertTrue(rgb(snap()).allSatisfy { abs($0.r - 128.0 / 255) < 1e-9 })
        XCTAssertTrue(cob(snap()).allSatisfy { abs($0 - 128.0 / 255) < 1e-9 })

        engine.setLevel(.left, 0); clock.now = 1.3; engine.stepForTesting()
        XCTAssertTrue(snap().fixtures[0].isDark, "zone level still applies")
        XCTAssertFalse(snap().fixtures[1].isDark)

        engine.setMaster(0); clock.now = 1.4; engine.stepForTesting()
        XCTAssertTrue(snap().fixtures.allSatisfy(\.isDark), "master zero = dark, COBs included")
        engine.setMaster(1); engine.setBlackout(true); clock.now = 1.5; engine.stepForTesting()
        XCTAssertTrue(snap().fixtures.allSatisfy(\.isDark), "blackout wins over tracks")
    }

    func testStopFadesProgramToBlackAndLiveEditsDoNotRelight() {
        let clock = ManualClock()
        let (engine, snap) = makeEngine(clock)
        let look = custom([steady(.all)], base: .chase)
        engine.setScene(.chase, look: look, immediate: true)
        clock.now = 1; engine.stepForTesting()
        XCTAssertFalse(snap().fixtures.allSatisfy(\.isDark))
        XCTAssertNotNil(snap().patternBeat)
        engine.stop()
        clock.now = 1.25; engine.stepForTesting()
        XCTAssertTrue(snap().stopFading)
        clock.now = 2.5; engine.stepForTesting()
        XCTAssertTrue(snap().stopped)
        XCTAssertTrue(snap().fixtures.allSatisfy(\.isDark), "Stop is black even with a program")
        XCTAssertNil(snap().patternBeat)
        var edited = look
        edited.program?.tracks.append(steady(TrackTarget(color: false, warm: true)))
        engine.setCustomScene(edited)
        clock.now = 3; engine.stepForTesting()
        XCTAssertTrue(snap().fixtures.allSatisfy(\.isDark), "a look change is not drawn over Stop")
        engine.setScene(.chase, look: edited)
        engine.sync {}   // apply the request at t = 3 s, before moving the clock
        clock.now = 6; engine.stepForTesting()
        XCTAssertFalse(snap().stopped)
        XCTAssertTrue(cob(snap()).allSatisfy { $0 == 1 }, "choosing the scene again starts it with the edited tracks")
    }

    func testCrossfadeKeepsTheOutgoingProgramAndBlendsIntoThePreset() {
        let look = SceneLook(custom([steady(.all)], base: .pulse))
        var seq = SceneSequencer(scene: .ambra)
        seq.request(.pulse, look: look, beat: 10, now: 0, gridTrusted: false)
        seq.advance(beat: 20, bpm: 120, now: 5, gridTrusted: false)
        XCTAssertTrue(seq.render(beat: 20, energy: 0.5, now: 5).center.rgb.allSatisfy { $0 == LightColor(1, 0, 0) })
        // Plain Tramonto fades in over 4 beats (immediate start, no trusted grid).
        seq.request(.sunset, look: nil, beat: 20, now: 5, gridTrusted: false)
        seq.advance(beat: 22, bpm: 120, now: 6, gridTrusted: false)
        let mid = seq.render(beat: 22, energy: 0.5, now: 6)
        let ctx = SceneContext(beat: 22, phrase: 22 - 24, energy: 0.5, minAttack: 0.06)
        let expected = look.render(.pulse, ctx).mixed(with: Choreography.render(.sunset, ctx), Choreography.s(0.5))
        for (a, b) in zip(mid.center.rgb, expected.center.rgb) {
            XCTAssertEqual(a.r, b.r, accuracy: 1e-9); XCTAssertEqual(a.g, b.g, accuracy: 1e-9); XCTAssertEqual(a.b, b.b, accuracy: 1e-9)
        }
        XCTAssertNil(seq.look, "new layers follow the preset look")
        seq.advance(beat: 30, bpm: 120, now: 10, gridTrusted: false)
        XCTAssertEqual(seq.render(beat: 30, energy: 0.5, now: 10), Choreography.render(.sunset, SceneContext(beat: 30, phrase: 6, energy: 0.5)))
        // Re-requesting the running scene with a look changes it at once (no new layer, no restart).
        seq.request(.sunset, look: look, beat: 31, now: 10.5, gridTrusted: false)
        XCTAssertTrue(seq.render(beat: 31, energy: 0.5, now: 10.5).left.rgb.allSatisfy { $0 == LightColor(1, 0, 0) })
    }

    func testEditedBuildAndDropGestureRunTheirTracksWithDipAndQuantisedImpact() {
        let build = SceneLook(custom([steady(.sides, color: .second)], base: .aurora, slot: .aurora))
        let drop = SceneLook(custom([ProgramTrack(stepsPerBeat: 1, lengthBeats: 4, steps: [1, 0, 0, 0], target: .centerOnly,
                                                  attack: 0, hold: 0.1, release: 0.5, color: .third)],
                                    base: .respiro, slot: .respiro))
        var seq = SceneSequencer(scene: .ambra, rate: 0.25)
        seq.request(.aurora, look: build, beat: 100.37, now: 0, gridTrusted: true, rateOverride: 1, forceRestart: true)
        seq.advance(beat: 102, bpm: 125, now: 0.8, gridTrusted: true)
        var f = seq.render(beat: 102, energy: 0.5, now: 0.8)
        XCTAssertEqual(seq.targetScene, .aurora)
        XCTAssertTrue(seq.isRateLocked, "the gesture keeps real beat rate")
        XCTAssertEqual(f.left.rgb[0], LightColor(0, 1, 0)); XCTAssertEqual(f.center.rgb.map(\.peak).max(), 0)
        // Release on beat 2 of the bar: Drop waits for the downbeat at 116, dark just before.
        seq.request(.respiro, look: drop, beat: 114, now: 6.4, gridTrusted: true, rateOverride: 1, forceRestart: true)
        XCTAssertEqual(seq.pendingScene, .respiro)
        XCTAssertTrue(seq.pendingIsDownbeat)
        seq.advance(beat: 115.95, bpm: 125, now: 7.3, gridTrusted: true)
        f = seq.render(beat: 115.95, energy: 0.5, now: 7.3)
        XCTAssertLessThan(f.center.rgb.map(\.peak).max() ?? 1, 0.05, "pre-drop dip")
        seq.advance(beat: 116, bpm: 125, now: 7.35, gridTrusted: true)
        f = seq.render(beat: 116, energy: 0.5, now: 7.35)
        XCTAssertTrue(f.center.rgb.allSatisfy { $0 == LightColor(0, 0, 1) }, "impact from the edited Drop tracks on the downbeat")
        XCTAssertEqual(f.left.rgb[0].peak, 0)
        XCTAssertEqual(seq.patternBeat(beat: 116), 0, "pattern counts from the drop")
        XCTAssertEqual(seq.patternBeat(beat: 117.5), 1.5)
    }

    func testGestureThroughTheEngineUsesTheEditedProgram() {
        let clock = ManualClock()
        let (engine, snap) = makeEngine(clock)
        engine.setSubdivision(.four, immediate: true)
        let build = custom([steady(.centerOnly, color: .first)], base: .aurora, slot: .aurora)
        engine.setBuildDropGesture(true, look: build)
        engine.sync {} // Apply at t = 0 before advancing beyond the fade.
        clock.now = 2; engine.stepForTesting()
        XCTAssertTrue(snap().movementLocked)
        XCTAssertTrue(snap().fixtures[1].rgb.allSatisfy { $0 == LightColor(1, 0, 0) })
        XCTAssertTrue(snap().fixtures[0].isDark && snap().fixtures[2].isDark)
        let drop = custom([steady(.sides, color: .second)], base: .respiro, slot: .respiro)
        engine.setBuildDropGesture(false, look: drop)
        engine.sync {}
        clock.now = 3; engine.stepForTesting()
        XCTAssertEqual(snap().scene, .respiro)
        XCTAssertEqual(snap().fixtures[0].rgb[0], LightColor(0, 1, 0))
        XCTAssertTrue(snap().fixtures[1].isDark)
    }

    func testCancelledPreviewRestoresThePreviousProgramAndNeverArms() {
        let clock = ManualClock()
        let (engine, snap) = makeEngine(clock)
        let saved = custom([steady(.all, color: .second)], base: .pulse)
        engine.setScene(.pulse, look: saved, immediate: true)
        clock.now = 1; engine.stepForTesting()
        XCTAssertTrue(rgb(snap()).allSatisfy { $0 == LightColor(0, 1, 0) })
        engine.beginScenePreview()
        var draft = saved
        draft.program?.tracks = [steady(.centerOnly, color: .third)]
        engine.setCustomScene(draft)
        clock.now = 1.5; engine.stepForTesting()
        XCTAssertTrue(snap().fixtures[1].rgb.allSatisfy { $0 == LightColor(0, 0, 1) }, "live preview of the draft")
        XCTAssertTrue(snap().fixtures[0].isDark)
        engine.finishScenePreview(restore: true)
        engine.sync {}
        clock.now = 2.5; engine.stepForTesting()
        XCTAssertTrue(rgb(snap()).allSatisfy { $0 == LightColor(0, 1, 0) }, "Annulla brings back the saved tracks")
        XCTAssertFalse(snap().armed)
    }

    func testPatternBeatFollowsTheMovementRate() {
        let clock = ManualClock()
        let (engine, snap) = makeEngine(clock)
        engine.setScene(.chase, look: custom([steady(.all)], base: .chase), immediate: true)
        engine.setSubdivision(.two, immediate: true)
        clock.now = 4; engine.stepForTesting()
        let beat = 4 * 2 + LightEngine.outputLatency * 2
        XCTAssertEqual(snap().patternBeat ?? -1, beat * 0.5, accuracy: 1e-9)
    }
}
