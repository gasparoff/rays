import XCTest
@testable import RaysTempo
@testable import RaysEngine

final class MIDIClockTests: XCTestCase {
    /// Sends `count` clock ticks at `bpm` starting at `t`; returns the events and the next time.
    private func ticks(_ p: inout MIDIClockParser, _ count: Int, bpm: Double, from t: TimeInterval) -> ([MIDIClockParser.Event], TimeInterval) {
        let dt = 60 / bpm / 24
        var events: [MIDIClockParser.Event] = []
        var time = t
        for _ in 0..<count { events += p.receive([0xF8], at: time); time += dt }
        return (events, time)
    }

    func testTempoFrom24PPQNAndBeatsCountedFromStart() throws {
        var p = MIDIClockParser()
        var (events, t) = ticks(&p, 30, bpm: 128, from: 10)
        XCTAssertEqual(events, [], "no beats before Start")
        XCTAssertEqual(try XCTUnwrap(p.bpm), 128, accuracy: 0.01)
        XCTAssertEqual(p.receive([0xFA], at: t), [.start])
        (events, t) = ticks(&p, 24 * 5, bpm: 128, from: t)
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.map { if case let .beat(_, b) = $0 { return b } else { return 0 } }, [1, 2, 3, 4, 1])
        if case let .beat(bpm, _) = events[0] { XCTAssertEqual(try XCTUnwrap(bpm), 128, accuracy: 0.01) }
        XCTAssertEqual(p.receive([0xFC], at: t), [.stop])
        (events, _) = ticks(&p, 48, bpm: 128, from: t)
        XCTAssertEqual(events, [], "stopped")
    }

    func testContinueSongPositionAndInterleavedRealtime() {
        var p = MIDIClockParser()
        // Song Position Pointer = 16 sixteenths (one bar) -> next tick is beat 1 of bar 2.
        XCTAssertEqual(p.receive([0xF2, 16, 0], at: 0), [])
        XCTAssertTrue(p.running)
        XCTAssertEqual(p.ticks, 96)
        var (events, t) = ticks(&p, 1, bpm: 120, from: 0)
        XCTAssertEqual(events, [.beat(bpm: nil, beatInBar: 1)])
        // Six sixteenths = beat 2 of 4 (ticks 36): realtime bytes inside an SPP are ignored by SPP parsing.
        XCTAssertEqual(p.receive([0xF2, 0xFE, 6, 0], at: t), [])
        XCTAssertEqual(p.ticks, 36)
        (events, t) = ticks(&p, 13, bpm: 120, from: t)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first, .beat(bpm: p.bpm, beatInBar: 3))
        XCTAssertEqual(p.receive([0xFC, 0xFB], at: t), [.stop])
        XCTAssertTrue(p.running, "Continue resumes without resetting the position")
    }

    func testGapsResetTheTempoEstimateAndOutOfRangeIsIgnored() {
        var p = MIDIClockParser()
        _ = ticks(&p, 30, bpm: 100, from: 0)
        XCTAssertNotNil(p.bpm)
        _ = p.receive([0xF8], at: 100)
        XCTAssertNil(p.bpm, "a long gap restarts estimation")
        var q = MIDIClockParser()
        _ = ticks(&q, 30, bpm: 1000, from: 0)
        XCTAssertNil(q.bpm, "above 400 BPM is rejected")
    }

    func testTempoSourceSnapshotFollowsTheClock() {
        var now: TimeInterval = 0
        let source = MIDIClockTempoSource(bpm: 90, now: { now })
        XCTAssertEqual(source.capture().bpm, 90)
        XCTAssertFalse(source.capture().isPlaying)
        XCTAssertEqual(source.capture().kind, .midiClock)
        source.receive([0xFA], at: 0)
        let dt = 60.0 / 140 / 24
        for i in 0..<48 { now = Double(i) * dt; source.receive([0xF8], at: now) }
        let s = source.capture()
        XCTAssertTrue(s.isPlaying)
        XCTAssertTrue(s.externalClock)
        XCTAssertEqual(s.bpm, 140, accuracy: 0.05)
        XCTAssertEqual(s.beat, 47.0 / 24, accuracy: 1e-9)
        now += 5
        XCTAssertFalse(source.capture().isPlaying, "stale clock")
        source.setTempo(77)
        XCTAssertEqual(source.capture().bpm, 140, accuracy: 0.05, "the clock keeps owning the tempo")
        XCTAssertTrue(TempoSourceRegistry.builtIn.make(id: "midiclock", bpm: 1) is LocalTempoClock, "not built in: off by default")
        var r = TempoSourceRegistry.builtIn
        r.register(MIDIClockTempoSource.descriptor)
        XCTAssertTrue(r.make(id: "midiclock", bpm: 100) is MIDIClockTempoSource)
    }
}

final class BeatSourceCompatibilityTests: XCTestCase {
    func testMIDIClockIsOptInAndUnknownSourcesFallBackToAuto() throws {
        XCTAssertEqual(Preferences().beatSource, .auto)
        XCTAssertFalse(BeatSource.midiClock.usesProDJLink)
        XCTAssertTrue(BeatSource.auto.usesProDJLink)
        XCTAssertTrue(BeatSource.xdj.usesProDJLink)
        XCTAssertFalse(BeatSource.link.usesProDJLink)
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"beatSource":"midiClock"}"#.utf8))
        XCTAssertEqual(p.beatSource, .midiClock)
        let future = try JSONDecoder().decode(Preferences.self, from: Data(#"{"beatSource":"something-new"}"#.utf8))
        XCTAssertEqual(future.beatSource, .auto)
    }
}
