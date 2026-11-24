import XCTest
@testable import RaysCore
@testable import RaysEngine

/// The countdown ring on a queued scene: 0 on the press, 1 when it starts, never past the time limit.
final class SceneCountdownTests: XCTestCase {
    func testDropCountsDownToTheNextDownbeat() throws {
        var seq = SceneSequencer(scene: .ambra)
        seq.advance(beat: 1, bpm: 120, now: 0, gridTrusted: true)
        XCTAssertNil(seq.pendingProgress(beat: 1, now: 0))
        seq.request(.respiro, beat: 1, now: 0, gridTrusted: true)
        XCTAssertEqual(seq.pendingScene, .respiro)

        // Drop is anchored at beat 4 with a 0.25-beat dip: the countdown runs from 1 to 3.75.
        XCTAssertEqual(try XCTUnwrap(seq.pendingProgress(beat: 1, now: 0)), 0, accuracy: 1e-9)
        let middle = try XCTUnwrap(seq.pendingProgress(beat: 2.375, now: 0.6875))
        XCTAssertEqual(middle, 0.5, accuracy: 1e-9)
        seq.advance(beat: 3.5, bpm: 120, now: 1.25, gridTrusted: true)
        XCTAssertGreaterThan(try XCTUnwrap(seq.pendingProgress(beat: 3.5, now: 1.25)), middle)

        seq.advance(beat: 3.8, bpm: 120, now: 1.4, gridTrusted: true)
        XCTAssertNil(seq.pendingScene)
        XCTAssertNil(seq.pendingProgress(beat: 3.8, now: 1.4), "No ring once the scene has started")
    }

    func testWallClockLimitFillsTheRingWhenTheGridIsSlow() throws {
        var seq = SceneSequencer(scene: .ambra)
        seq.advance(beat: 1, bpm: 120, now: 0, gridTrusted: true)
        seq.request(.respiro, beat: 1, now: 0, gridTrusted: true)
        let late = try XCTUnwrap(seq.pendingProgress(beat: 1.1, now: SceneSequencer.maxPendingSeconds * 0.9))
        XCTAssertEqual(late, 0.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(seq.pendingProgress(beat: .nan, now: 100)), 1)
    }

    func testImmediateScenesNeverShowACountdown() {
        var seq = SceneSequencer(scene: .pulse)
        seq.advance(beat: 1.5, bpm: 120, now: 0, gridTrusted: true)
        seq.request(.ambra, beat: 1.5, now: 0, gridTrusted: true)
        XCTAssertNil(seq.pendingProgress(beat: 1.5, now: 0))
    }

    /// Controls are keyed on `controlState`: the countdown value must not re-lay them out every frame.
    func testControlStateKeepsOnlyWhetherACountdownIsRunning() {
        var a = EngineSnapshot()
        var b = EngineSnapshot()
        a.pendingProgress = 0.2
        b.pendingProgress = 0.7
        XCTAssertEqual(a.controlState, b.controlState)
        b.pendingProgress = nil
        XCTAssertNotEqual(a.controlState, b.controlState)
    }
}
