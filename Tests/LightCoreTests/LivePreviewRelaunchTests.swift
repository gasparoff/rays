import XCTest
@testable import LightCore

/// Editor previews and re-selecting the same custom scene go through
/// `setCustomScene(_:relaunchingIfStoppedAs:)`. The decision "stopped → launch, playing → new look"
/// belongs to the engine queue, never to a UI snapshot that can lag one or two frames behind.
final class LivePreviewRelaunchTests: XCTestCase {
    private func look(_ name: String, _ color: SceneRGB, base: SceneID) -> CustomScene {
        CustomScene(name: name, base: base, colors: [color, color, color])
    }

    private func makeEngine(_ clock: ManualClock) -> (LightEngine, () -> EngineSnapshot) {
        let engine = LightEngine(tempo: LocalTempoClock(bpm: 120, now: { clock.now }), transport: FakeTransport(),
                                 clock: { clock.now }, runsTimer: false)
        engine.setExternalBeatGrid(true) // trusted grid: phrase scenes wait for a downbeat
        var snap = EngineSnapshot()
        engine.onSnapshot = { snap = $0 }
        return (engine, { snap })
    }

    func testEditsRightAfterAPhraseLaunchNeverReArmThePhrase() throws {
        let clock = ManualClock()
        let (engine, snap) = makeEngine(clock)
        let red = look("A", SceneRGB(r: 1, g: 0, b: 0), base: .respiro)
        engine.setScene(.ambra, immediate: true)
        engine.stop()
        clock.now = 10.3; engine.stepForTesting()
        XCTAssertTrue(snap().stopped)

        engine.setCustomScene(red, relaunchingIfStoppedAs: .respiro)
        clock.now = 10.35; engine.stepForTesting()
        XCTAssertFalse(snap().stopped, "a stopped show launches the edited scene")
        XCTAssertTrue(snap().scene == .respiro || snap().pendingScene == .respiro)
        // Wait for the launch, then keep editing. The first edit lands most of a beat later, as after a main-thread
        // stall: a UI snapshot from before the launch would still say "stopped" at that point.
        while snap().pendingScene != nil { clock.now += 0.05; engine.stepForTesting() }
        XCTAssertEqual(snap().scene, .respiro)
        let launchedAt = clock.now
        let pattern = try XCTUnwrap(snap().patternBeat)
        for step in 1...12 {
            let edit = look("A", SceneRGB(r: 1, g: Double(step) / 12, b: 0), base: .respiro)
            engine.setCustomScene(edit, relaunchingIfStoppedAs: .respiro)
            let elapsed = 0.4 + Double(step - 1) * 0.1
            clock.now = launchedAt + elapsed
            engine.stepForTesting()
            XCTAssertNil(snap().pendingScene, "no new launch is queued by a live edit")
            XCTAssertEqual(try XCTUnwrap(snap().patternBeat), pattern + elapsed * 2, accuracy: 1e-6,
                           "the phrase keeps running (120 BPM: 2 beats per second)")
        }
        XCTAssertEqual(snap().sceneLook?.colors.first, SceneRGB(r: 1, g: 1, b: 0), "the newest look plays")
    }

    func testEditWhileStoppedLaunchesWithThatLookAndEditWhilePlayingOnlyChangesTheLook() throws {
        let clock = ManualClock()
        let (engine, snap) = makeEngine(clock)
        let blue = look("B", SceneRGB(r: 0, g: 0, b: 1), base: .chase)
        engine.setScene(.chase, look: blue, immediate: true)
        clock.now = 1; engine.stepForTesting()
        let pattern = try XCTUnwrap(snap().patternBeat)

        let green = look("B", SceneRGB(r: 0, g: 1, b: 0), base: .chase)
        engine.setCustomScene(green, relaunchingIfStoppedAs: .chase)
        clock.now = 1.25; engine.stepForTesting()
        XCTAssertEqual(snap().sceneLook?.colors.first, SceneRGB(r: 0, g: 1, b: 0))
        XCTAssertNil(snap().pendingScene)
        XCTAssertEqual(try XCTUnwrap(snap().patternBeat), pattern + 0.5, accuracy: 1e-6, "no restart while playing")

        engine.stop()
        clock.now = 4; engine.stepForTesting()
        XCTAssertTrue(snap().stopped)
        engine.setCustomScene(blue, relaunchingIfStoppedAs: .chase)
        while snap().pendingScene != nil || snap().stopped { clock.now += 0.05; engine.stepForTesting(); if clock.now > 8 { break } }
        XCTAssertFalse(snap().stopped, "an edit while stopped starts the scene again, as before")
        XCTAssertEqual(snap().scene, .chase)
        XCTAssertEqual(snap().sceneLook?.colors.first, SceneRGB(r: 0, g: 0, b: 1))
    }
}
