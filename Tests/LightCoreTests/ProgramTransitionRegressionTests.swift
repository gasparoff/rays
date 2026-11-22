import XCTest
@testable import RaysCore

final class ProgramTransitionRegressionTests: XCTestCase {
    func testPendingProgramDoesNotChangeTheRunningFactorySceneBeforeItsBeat() {
        var sequencer = SceneSequencer(scene: .ambra)
        let before = sequencer.render(beat: 0.2, energy: 0.5, now: 0.1)
        let track = ProgramTrack(stepsPerBeat: 1, lengthBeats: 4, target: .all, floor: 1, peak: 1)
        let green = SceneRGB(r: 0, g: 1, b: 0)
        let scene = CustomScene(base: .pulse, colors: [green, green, green],
                                program: SceneProgram(tracks: [track]))
        sequencer.request(.pulse, look: SceneLook(scene), beat: 0.2, now: 0.1, gridTrusted: true)
        XCTAssertEqual(sequencer.pendingScene, .pulse)
        XCTAssertEqual(sequencer.targetScene, .ambra)
        XCTAssertEqual(sequencer.render(beat: 0.2, energy: 0.5, now: 0.1), before,
                       "The running factory scene must keep its original look until the quantised launch")
        sequencer.advance(beat: 3, bpm: 120, now: 1.5, gridTrusted: true)
        XCTAssertTrue(sequencer.render(beat: 3, energy: 0.5, now: 1.5).center.rgb.allSatisfy { $0 == LightColor(0, 1, 0) })
    }

    func testTrackDimensionsAreSafeEvenBeforeSanitizingPublicInitializerInput() {
        for (resolution, length) in [(Int.max, Int.max), (-4, 8), (4, -8), (0, 0)] {
            let track = ProgramTrack(stepsPerBeat: resolution, lengthBeats: length)
            XCTAssertTrue(ProgramTrack.resolutions.contains(track.stepsPerBeat))
            XCTAssertTrue(ProgramTrack.lengths.contains(track.lengthBeats))
            XCTAssertEqual(track.steps.count, track.stepCount)
            XCTAssertLessThanOrEqual(track.stepCount, ProgramTrack.maxSteps)
        }
    }
}
