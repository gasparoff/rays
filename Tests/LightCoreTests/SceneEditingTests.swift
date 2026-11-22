import XCTest
@testable import RaysCore

final class SceneEditingTests: XCTestCase {
    // MARK: Timeline

    func testMixedResolutionsShareOneBeatAxisAndRepeatsMapToTheStoredStep() {
        // Pulse-like rows: quarters over 4 beats, eighths over 4 beats, eighths over 1 beat.
        let tracks = [ProgramTrack(stepsPerBeat: 1, lengthBeats: 4), ProgramTrack(stepsPerBeat: 2, lengthBeats: 4),
                      ProgramTrack(stepsPerBeat: 2, lengthBeats: 1), ProgramTrack(stepsPerBeat: 4, lengthBeats: 8)]
        XCTAssertEqual(RhythmViewport.totalBeats(tracks), 8)
        let view = RhythmViewport(start: 0, span: 4, total: 8)

        let quarters = view.cells(stepsPerBeat: 1, lengthBeats: 4)
        XCTAssertEqual(quarters.map(\.source), [0, 1, 2, 3])
        XCTAssertEqual(quarters.map(\.beat), [0, 1, 2, 3])

        let hat = view.cells(stepsPerBeat: 2, lengthBeats: 1)
        XCTAssertEqual(hat.count, 8, "a 1-beat cycle is shown four times in one bar, not stretched")
        XCTAssertEqual(hat.map(\.source), [0, 1, 0, 1, 0, 1, 0, 1])
        XCTAssertEqual(hat.map(\.repetition), [0, 0, 1, 1, 2, 2, 3, 3])
        XCTAssertEqual(hat[3].beat, 1.5, accuracy: 1e-12)
        XCTAssertEqual(hat[3].width, 0.5, accuracy: 1e-12)

        let sixteenths = view.cells(stepsPerBeat: 4, lengthBeats: 8)
        XCTAssertEqual(sixteenths.count, 16)
        XCTAssertEqual(sixteenths.last?.source, 15)
        XCTAssertEqual(sixteenths.filter(\.onBeat).map(\.source), [0, 4, 8, 12])
    }

    func testSecondPageContinuesTheCycleOrWrapsShorterCycles() {
        let view = RhythmViewport(start: 4, span: 4, total: 8)
        XCTAssertEqual(view.page, 1)
        XCTAssertEqual(view.cells(stepsPerBeat: 4, lengthBeats: 8).first?.source, 16, "beat 5 of an 8-beat cycle")
        let fourBeats = view.cells(stepsPerBeat: 1, lengthBeats: 4)
        XCTAssertEqual(fourBeats.map(\.source), [0, 1, 2, 3])
        XCTAssertEqual(fourBeats.map(\.repetition), [1, 1, 1, 1])
        XCTAssertEqual(view.sourceStep(atFraction: 0.99, stepsPerBeat: 2, lengthBeats: 8), 15)
        XCTAssertEqual(view.sourceStep(atFraction: 0.99, stepsPerBeat: 2, lengthBeats: 2), 3)
        XCTAssertEqual(view.sourceStep(atFraction: 0, stepsPerBeat: 4, lengthBeats: 1), 0)
        XCTAssertNil(view.sourceStep(atFraction: 1, stepsPerBeat: 1, lengthBeats: 4))
        XCTAssertNil(view.sourceStep(atFraction: -0.01, stepsPerBeat: 1, lengthBeats: 4))
    }

    func testViewportStaysOnWholePagesInsideTheTimeline() {
        var view = RhythmViewport(start: 12, span: 4, total: 16)
        XCTAssertEqual(view.start, 12)
        view.update(span: 8)
        XCTAssertEqual(view.span, 8)
        XCTAssertEqual(view.start, 8, "the start snaps to the page that contained it")
        view.update(total: 4)
        XCTAssertEqual(view.span, 4, "the span never exceeds the timeline")
        XCTAssertEqual(view.start, 0)
        XCTAssertEqual(view.spanChoices, [4])
        view.update(total: 16, span: 16)
        XCTAssertEqual(view.pageCount, 1)
        view.update(span: 5)
        XCTAssertEqual(view.span, 4, "unknown spans fall back to the nearest smaller choice")
    }

    func testPlayheadUsesTheCommonTimelineAndHidesOnOtherPages() {
        let view = RhythmViewport(start: 4, span: 4, total: 8)
        XCTAssertEqual(try XCTUnwrap(view.playheadFraction(patternBeat: 13)), 0.25, accuracy: 1e-12)  // 13 mod 8 = 5
        XCTAssertNil(view.playheadFraction(patternBeat: 2))
        XCTAssertEqual(try XCTUnwrap(view.playheadFraction(patternBeat: -2)), 0.5, accuracy: 1e-12)    // −2 mod 8 = 6
        XCTAssertNil(view.playheadFraction(patternBeat: nil))
        XCTAssertNil(view.playheadFraction(patternBeat: .nan))
    }

    // MARK: Painting

    func testClickCyclesAndDragPaintsOneValueWithoutDoubleCycling() {
        XCTAssertEqual(StepPaint.next(after: 0), 1)
        XCTAssertEqual(StepPaint.next(after: 1), 0.5)
        XCTAssertEqual(StepPaint.next(after: 0.5), 0)
        XCTAssertEqual(StepPaint.next(after: 0.3), 0, "any soft level counts as soft")

        var steps: [Double] = [0, 1, 0.5, 0, 0, 0, 0, 0]
        var stroke = StepPaint.Stroke(first: 0, current: steps[0])
        XCTAssertTrue(stroke.paint(0, in: &steps))
        XCTAssertTrue(stroke.paint(1, in: &steps) == false, "already strong: unchanged")
        XCTAssertTrue(stroke.paint(2, in: &steps))
        XCTAssertFalse(stroke.paint(0, in: &steps), "coming back over the first cell does not cycle it again")
        XCTAssertFalse(stroke.paint(99, in: &steps))
        XCTAssertEqual(steps, [1, 1, 1, 0, 0, 0, 0, 0])
        XCTAssertEqual(stroke.touched, [0, 1, 2])

        var erase = StepPaint.Stroke(first: 2, current: 0.5)
        XCTAssertEqual(erase.value, 0)
        _ = erase.paint(2, in: &steps); _ = erase.paint(1, in: &steps)
        XCTAssertEqual(steps, [1, 0, 0, 0, 0, 0, 0, 0])
    }

    // MARK: Envelope

    func testEnvelopeHandlesStayInBoundsAndKeepFloorBelowPeak() {
        let track = ProgramTrack(stepsPerBeat: 2, lengthBeats: 4, steps: [1, 0, 0, 0, 0, 0, 0, 0],
                                 attack: 0.1, hold: 0.08, release: 0.5, floor: 0.1, peak: 0.8, color: .third)
        var t = EnvelopeHandle.attackStart.drag(track, time: -9, level: 0.95)
        XCTAssertEqual(t.attack, ProgramTrack.maxAttack)
        XCTAssertEqual(t.floor, 0.8, "the floor stops at the peak")
        t = EnvelopeHandle.attackStart.drag(track, time: 0.4, level: -1)
        XCTAssertEqual(t.attack, 0, "the attack ends on the hit and cannot start after it")
        XCTAssertEqual(t.floor, 0)

        t = EnvelopeHandle.hit.drag(track, time: 3, level: 0.05)
        XCTAssertEqual(t.peak, 0.05)
        XCTAssertEqual(t.floor, 0.05, "lowering the peak lowers a higher floor")
        XCTAssertEqual(t.attack, track.attack, "the hit handle never moves in time")

        t = EnvelopeHandle.holdEnd.drag(track, time: 0.333, level: 1.4)
        XCTAssertEqual(t.hold, 0.33)
        XCTAssertEqual(t.peak, 1)

        t = EnvelopeHandle.releaseEnd.drag(track, time: 100, level: 0.2)
        XCTAssertEqual(t.release, ProgramTrack.maxRelease)
        XCTAssertEqual(t.floor, 0.2)
        t = EnvelopeHandle.releaseEnd.drag(track, time: 0, level: 0.2)
        XCTAssertEqual(t.release, 0, "the release is measured after the hold")

        let p = EnvelopeHandle.releaseEnd.position(of: track)
        XCTAssertEqual(p.time, 0.58, accuracy: 1e-12)
        XCTAssertEqual(p.level, 0.1)
        // Nothing but the envelope changes.
        var other = EnvelopeHandle.holdEnd.drag(track, time: 0.2, level: 0.7)
        other.hold = track.hold; other.peak = track.peak
        XCTAssertEqual(other, track.sanitized)
    }

    func testShapePresetsOnlyChangeTimesAndAreRecognised() {
        let track = ProgramTrack(name: "Colpi", sound: .bass, stepsPerBeat: 2, lengthBeats: 4,
                                 steps: [1, 0, 0, 1, 0, 0, 1, 0], offset: 0.05, target: .centerOnly, motion: .chase,
                                 spread: 0.25, attack: 0.37, hold: 0.2, release: 1.1, floor: 0.12, peak: 0.9,
                                 color: .cycle, blend: .add, softFollowsEnergy: false, riseBeats: 8)
        XCTAssertNil(HitShapePreset.matching(track))
        for preset in HitShapePreset.allCases {
            var t = preset.apply(to: track)
            XCTAssertEqual(HitShapePreset.matching(t), preset)
            XCTAssertEqual(t.attack, preset.times.attack)
            t.attack = track.attack; t.hold = track.hold; t.release = track.release
            XCTAssertEqual(t, track.sanitized, "\(preset.title) must not touch levels, colour, rhythm or target")
        }
        XCTAssertEqual(track.withFloor(2).floor, 0.9)
        XCTAssertEqual(track.withPeak(0.05).floor, 0.05)
        XCTAssertEqual(track.withPeak(0.5).floor, 0.12)
    }

    // MARK: History

    func testHistoryCoalescesContinuousEditsAndIsBounded() {
        var h = EditHistory<Int>(limit: 3, coalesceWindow: 1)
        var state = 0
        func edit(_ to: Int, key: String?, at t: Double) { h.record(state, key: key, at: t); state = to }

        edit(1, key: "slider", at: 0)
        edit(2, key: "slider", at: 0.3)
        edit(3, key: "slider", at: 0.6)
        XCTAssertEqual(h.undoStack, [0], "one drag is one undo step")
        edit(4, key: "slider", at: 2.0)
        XCTAssertEqual(h.undoStack, [0, 3], "a pause starts a new step")
        edit(5, key: nil, at: 2.1)
        edit(6, key: nil, at: 2.2)
        XCTAssertEqual(h.undoStack, [3, 4, 5], "bounded: the oldest step is dropped")

        state = h.undo(current: state)!
        XCTAssertEqual(state, 5)
        XCTAssertTrue(h.canRedo)
        edit(7, key: "slider", at: 2.3)
        XCTAssertFalse(h.canRedo, "a new edit clears redo")
        edit(8, key: "slider", at: 2.4)
        XCTAssertEqual(h.undoStack, [3, 4, 5], "same key after undo still coalesces with its own stroke")

        state = h.undo(current: state)!
        XCTAssertEqual(state, 5)
        state = h.redo(current: state)!
        XCTAssertEqual(state, 8)
        state = h.undo(current: state)!
        state = h.undo(current: state)!
        state = h.undo(current: state)!
        XCTAssertEqual(state, 3)
        XCTAssertNil(h.undo(current: state))
        XCTAssertEqual(h.redoStack.count, 3)

        edit(9, key: "name", at: 3)
        h.breakCoalescing()
        edit(10, key: "name", at: 3.1)
        XCTAssertEqual(h.undoStack.suffix(2), [3, 9])
    }

    func testUndoRestoresWholeSceneIncludingDeletedTrackIdentity() {
        let start = ClubSceneBank.scene(for: .pulse)
        var draft = start
        var h = EditHistory<CustomScene>()
        h.record(draft, key: nil, at: 0)
        draft.program?.tracks.remove(at: 1)
        h.record(draft, key: nil, at: 1)
        draft.colors[0] = SceneRGB(r: 0, g: 0, b: 0)
        draft = h.undo(current: draft)!
        draft = h.undo(current: draft)!
        XCTAssertEqual(draft, start, "ids, steps and every other field come back unchanged")
    }
}
