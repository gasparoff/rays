import XCTest
@testable import RaysTempo
@testable import RaysEngine

final class ScenePreviewTests: XCTestCase {
    func testCancelRestoresStoppedShowWithoutArmingOutput() {
        let clock = ManualClock(), transport = FakeTransport()
        // Start the timeline at 0: stop() runs asynchronously and may read the clock before the
        // first step, so a jump back from ManualClock's default 1000 s would freeze the Stop fade.
        clock.now = 0
        let tempo = LocalTempoClock(bpm: 120, now: { clock.now })
        let engine = LightEngine(tempo: tempo, transport: transport, interfaces: { [Fixture.lan] }, clock: { clock.now }, runsTimer: false)
        var snapshot = EngineSnapshot()
        engine.onSnapshot = { snapshot = $0 }
        engine.start()
        engine.stop()
        clock.now = 1; engine.stepForTesting()
        XCTAssertTrue(snapshot.stopped)
        engine.beginScenePreview()
        engine.setScene(.chase, immediate: true)
        clock.now = 1.5; engine.stepForTesting()
        XCTAssertFalse(snapshot.stopped)
        engine.finishScenePreview(restore: true)
        clock.now = 2; engine.stepForTesting()
        XCTAssertTrue(snapshot.stopped)
        clock.now = 2.4; engine.stepForTesting()
        XCTAssertTrue(snapshot.fixtures.allSatisfy(\.isDark))
        XCTAssertFalse(snapshot.armed)
        XCTAssertTrue(transport.dmxPackets.isEmpty)
        engine.shutdown()
    }
}
