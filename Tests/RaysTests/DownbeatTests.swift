import XCTest
@testable import RaysTempo
@testable import RaysEngine

final class DownbeatTests: XCTestCase {
    func testPressMakesNowFirstBeatAndKeepsFollowingSourceTempo() {
        let clock = ManualClock()
        let source = LocalTempoClock(bpm: 120, now: { clock.now })
        let lights = DownbeatTempoSource(source: source)
        clock.now = 1.375 // Halfway through beat 3; press on the actual music downbeat.
        let original = source.capture()
        lights.setDownbeat()
        XCTAssertEqual(lights.capture().phase, 0, accuracy: 1e-9)
        XCTAssertEqual(source.capture(), original, "a lighting correction must not alter the shared source")
        clock.now += 0.5
        XCTAssertEqual(lights.capture().phase, 1, accuracy: 1e-9)
        source.setTempo(128)
        clock.now += 60.0 / 128
        XCTAssertEqual(lights.capture().phase, 2, accuracy: 1e-9)
        XCTAssertEqual(lights.capture().bpm, 128)
        lights.setDownbeat()
        XCTAssertEqual(lights.capture().phase, 0, accuracy: 1e-9, "a second press replaces the previous alignment")
        XCTAssertEqual(source.capture().phase, 0.75, accuracy: 1e-9)
    }

    func testConsoleMetadataAndCorrectionSurviveNextExternalBeat() {
        let source = ConsoleClock()
        let lights = DownbeatTempoSource(source: source)
        lights.setDownbeat()
        source.value.beat += 1
        source.value.phase = 3
        let next = lights.capture()
        XCTAssertEqual(next.phase, 1, accuracy: 1e-9)
        XCTAssertEqual(next.bpm, 126)
        XCTAssertEqual(next.peers, 2)
        XCTAssertTrue(next.externalClock)
        XCTAssertTrue(next.isPlaying)
        XCTAssertTrue(next.linkEnabled)
        XCTAssertTrue(next.startStopSync)
        XCTAssertEqual(next.kind, .link)
        source.value.beat = .nan
        lights.setDownbeat() // Bad input cannot replace the valid correction.
        source.value.beat = 15
        XCTAssertEqual(lights.capture().phase, 2, accuracy: 1e-9)
    }

    func testEngineShowsFirstBeatWithoutChangingStoppedOrBlackoutState() {
        let clock = ManualClock()
        let source = LocalTempoClock(now: { clock.now })
        let lights = DownbeatTempoSource(source: source)
        let transport = FakeTransport()
        let engine = LightEngine(tempo: lights, transport: transport,
                                 clock: { clock.now }, runsTimer: false)
        engine.setBlackout(true)
        engine.stop()
        var snap = EngineSnapshot()
        engine.onSnapshot = { snap = $0 }
        engine.stepForTesting()
        clock.now = 3.2
        engine.stepForTesting()
        lights.setDownbeat()
        engine.stepForTesting()
        XCTAssertEqual(snap.tempo.phase, 0, accuracy: 1e-9)
        XCTAssertEqual(snap.tempo.bpm, 120)
        XCTAssertTrue(snap.stopped)
        XCTAssertTrue(snap.blackout)
        XCTAssertFalse(snap.armed)
        XCTAssertTrue(transport.dmxPackets.isEmpty)
    }
}

private final class ConsoleClock: TempoSource {
    var value = TempoSnapshot(bpm: 126, beat: 13, phase: 1, isPlaying: true, peers: 2,
                              kind: .link, linkEnabled: true, startStopSync: true, externalClock: true)
    func capture() -> TempoSnapshot { value }
    func setTempo(_ bpm: Double) { XCTFail("alignment must not set the console BPM") }
    func setStartStopSync(_ enabled: Bool) { XCTFail("alignment must not change transport sync") }
}
