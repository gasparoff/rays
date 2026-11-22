import XCTest
@testable import LightCore

final class SceneMiniatureTests: XCTestCase {
    func testDifferentTrackCyclesRepeatOnOneBeatAxisAndSignedOffsetWraps() {
        let short = ProgramTrack(name: "Hat", stepsPerBeat: 2, lengthBeats: 1, steps: [0, 1], offset: 0.1)
        let long = ProgramTrack(name: "Phrase", stepsPerBeat: 1, lengthBeats: 8,
                                steps: [1, 0, 0, 0, 0, 0, 0, 0], offset: -0.25)
        let scene = CustomScene(program: SceneProgram(tracks: [short, long]))
        let layout = SceneMiniatureLayout(scene: .ambra, look: scene)
        XCTAssertEqual(layout.span, 8)
        XCTAssertEqual(layout.lanes[0].marks.count, 8)
        for (i, mark) in layout.lanes[0].marks.enumerated() {
            XCTAssertEqual(mark.beat, Double(i) + 0.6, accuracy: 1e-9)
        }
        XCTAssertEqual(layout.lanes[1].marks.map(\.beat), [7.75], "Anticipated first hit belongs at the end of the preceding cycle")
        XCTAssertEqual(scene.program?.tracks, [short, long], "The miniature must not rewrite the saved rhythm")
    }

    func testMutedWarmTracksKeepTheirStructureAndWarmColourIndependentOfPalette() {
        let warm = ProgramTrack(name: "COB", enabled: false, stepsPerBeat: 1, lengthBeats: 4,
                                steps: [1, 0.5, 0, 0], target: TrackTarget(color: false, warm: true))
        let green = SceneRGB(r: 0, g: 1, b: 0)
        let scene = CustomScene(colors: [green, green, green], program: SceneProgram(tracks: [warm]))
        let lane = SceneMiniatureLayout(scene: .ambra, look: scene).lanes[0]
        XCTAssertFalse(lane.enabled)
        XCTAssertEqual(lane.marks.map(\.level), [1, 0.5])
        XCTAssertGreaterThan(lane.color.r, lane.color.b)
        XCTAssertNotEqual(lane.color, green)
    }

    func testOriginalScenesUseActualRoleEnvelopesAndThePlayingPhraseAnchor() {
        let source = CustomScene(base: .aurora, energy: 0.4)
        let layout = SceneMiniatureLayout(scene: .aurora, look: source, windowStart: 1008, phraseAnchor: 1004, energy: 0.4)
        XCTAssertFalse(layout.usesTracks)
        XCTAssertEqual(layout.lanes.count, 3)
        let expected = SceneLook(source).render(.aurora, SceneContext(beat: 1012, phrase: 8, energy: 0.4))
        for (i, role) in FixtureRole.allCases.enumerated() {
            let frame = expected[role]
            let level = max(frame.rgb.map(\.peak).max() ?? 0, frame.cob.max() ?? 0)
            XCTAssertEqual(layout.lanes[i].waveform[24], level, accuracy: 1e-9)
        }
        XCTAssertNil(source.program, "Opening a legacy overview is not a conversion to editable tracks")
    }

    func testCursorUsesEnginePatternTimeAndNeverInventsAStoppedOrEarlyDropPosition() {
        XCTAssertEqual(SceneMiniatureLayout.cursor(beat: 20, scene: .pulse, span: 16), 0.25)
        XCTAssertEqual(SceneMiniatureLayout.cursor(beat: -1, scene: .ambra, span: 16), 15.0 / 16)
        XCTAssertNil(SceneMiniatureLayout.cursor(beat: nil, scene: .pulse, span: 16))
        XCTAssertNil(SceneMiniatureLayout.cursor(beat: -0.1, scene: .respiro, span: 16))
        XCTAssertNil(SceneMiniatureLayout.cursor(beat: .nan, scene: .pulse, span: 16))
        XCTAssertNil(SceneMiniatureLayout.cursor(beat: 1, scene: .pulse, span: 0))
    }

    func testCurrentLookDoesNotJumpToQueuedSceneBeforeTheQuantisedLaunch() {
        let playing = CustomScene(base: .pulse)
        let queued = ClubSceneBank.scene(for: .chase)
        var seq = SceneSequencer(scene: .pulse)
        seq.setLook(SceneLook(playing))
        seq.advance(beat: 0.2, bpm: 120, now: 0, gridTrusted: true)
        seq.request(.chase, look: SceneLook(queued), beat: 0.2, now: 0, gridTrusted: true)
        XCTAssertEqual(seq.currentSceneLook?.id, playing.id)
        XCTAssertEqual(seq.pendingScene, .chase)
        seq.advance(beat: 1.1, bpm: 120, now: 0.45, gridTrusted: true)
        XCTAssertEqual(seq.currentSceneLook?.id, queued.id)
        XCTAssertEqual(seq.targetScene, .chase)
    }
}
