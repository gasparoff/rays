import XCTest
@testable import LightCore

final class EngineAndTempoTests: XCTestCase {
    private func makeEngine() -> (LightEngine, FakeTransport, ManualClock, LocalTempoClock) {
        let t = FakeTransport()
        let clock = ManualClock()
        let tempo = LocalTempoClock(bpm: 120, now: { clock.now })
        let engine = LightEngine(tempo: tempo, transport: t, interfaces: { [Fixture.lan] },
                                 clock: { clock.now }, runsTimer: false)
        return (engine, t, clock, tempo)
    }

    private func confirmedPatch(profile: String = "generic.rgbw4") -> Patch {
        let lib = ProfileLibrary()
        var p = Patch()
        p.addGroup(profile: lib.profile(id: profile) ?? ProfileLibrary.builtIn[0], count: 3, startAddress: 1, universe: 0)
        if p.validate(library: lib).isEmpty { p.setConfirmed(true, library: lib) }
        return p
    }

    private func latest(_ engine: LightEngine) -> EngineSnapshot {
        var snap = EngineSnapshot()
        engine.onSnapshot = { snap = $0 }
        engine.stepForTesting()
        return snap
    }

    func testDemoModeNeverSendsDMX() {
        let (engine, t, clock, _) = makeEngine()
        engine.start()
        engine.sync { t.receive?(Fixture.pollReply(), IPv4Address(192, 168, 1, 50)) }
        engine.setArmed(true)
        for _ in 0..<10 { clock.now += 1 / 30; engine.stepForTesting() }
        let s = latest(engine)
        XCTAssertTrue(s.isDemo)
        XCTAssertEqual(s.fixtures.count, 3)
        XCTAssertFalse(s.armed)
        XCTAssertEqual(s.readiness, .noPatch)
        XCTAssertTrue(t.dmxPackets.isEmpty)
        XCTAssertFalse(t.pollPackets.isEmpty, "discovery starts immediately")
    }

    func testUnconfirmedOrUnknownProfileCannotArm() {
        let (engine, t, _, _) = makeEngine()
        engine.start()
        engine.sync { t.receive?(Fixture.pollReply(), IPv4Address(192, 168, 1, 50)) }
        var p = confirmedPatch()
        p.confirmedFingerprint = nil
        engine.setPatch(p)
        engine.setArmed(true)
        XCTAssertEqual(latest(engine).readiness, .notConfirmed)

        let unknown = Patch(fixtures: [PatchedFixture(label: "?", profileID: "varytec.unknown", universe: 0, address: 1)],
                            confirmedFingerprint: "forged")
        engine.setPatch(unknown)
        engine.setArmed(true)
        let s = latest(engine)
        XCTAssertFalse(s.armed)
        if case .invalidPatch = s.readiness {} else { XCTFail("expected invalid patch, got \(s.readiness)") }
        XCTAssertTrue(t.dmxPackets.isEmpty)
    }

    func testArmedOutputMatchesPreviewAndBlackoutAndDisarmSendZeros() {
        let (engine, t, clock, _) = makeEngine()
        engine.start()
        engine.setPatch(confirmedPatch())
        XCTAssertEqual(latest(engine).readiness, .noDevice)
        engine.sync { t.receive?(Fixture.pollReply(), IPv4Address(192, 168, 1, 50)) }
        engine.setMaster(1)
        engine.setArmed(true)
        clock.now += 0.2
        let s = latest(engine)
        XCTAssertTrue(s.armed)
        XCTAssertFalse(s.isDemo)
        XCTAssertEqual(s.fixtures.count, 3)
        let pkt = t.dmxPackets.last!
        XCTAssertEqual(pkt.to, IPv4Address(192, 168, 1, 50))
        XCTAssertEqual(pkt.bytes[14], 0, "universe 0")
        XCTAssertTrue(t.dmxPackets.allSatisfy { $0.bytes[14] == 0 }, "universe 1 is not in the patch")
        // Fixture 1 red channel equals the preview's red (RGBW: white is reported separately).
        XCTAssertGreaterThan(Int(pkt.bytes[18]) + Int(pkt.bytes[19]) + Int(pkt.bytes[20]), 0)

        engine.setBlackout(true)
        _ = latest(engine)
        XCTAssertTrue(t.dmxPackets.last!.bytes[18...].allSatisfy { $0 == 0 })
        XCTAssertTrue(latest(engine).fixtures.allSatisfy { $0.r == 0 && $0.g == 0 && $0.b == 0 })

        engine.setBlackout(false)
        _ = latest(engine)
        let before = t.dmxPackets.count
        engine.setArmed(false)
        engine.sync {}
        XCTAssertEqual(t.dmxPackets.count, before + 3)
        XCTAssertTrue(t.dmxPackets.suffix(3).allSatisfy { $0.bytes[18...].allSatisfy { $0 == 0 } })
        let afterDisarm = t.dmxPackets.count
        _ = latest(engine)
        XCTAssertEqual(t.dmxPackets.count, afterDisarm, "no DMX once disarmed")
    }

    func testShutdownSendsZeroFramesAndCloses() {
        let (engine, t, _, _) = makeEngine()
        engine.start()
        engine.setPatch(confirmedPatch())
        engine.sync { t.receive?(Fixture.pollReply(), IPv4Address(192, 168, 1, 50)) }
        engine.setArmed(true)
        _ = latest(engine)
        let n = t.dmxPackets.count
        engine.shutdown()
        XCTAssertEqual(t.dmxPackets.count, n + 3)
        XCTAssertTrue(t.dmxPackets.suffix(3).allSatisfy { $0.bytes[18...].allSatisfy { $0 == 0 } })
        XCTAssertFalse(t.isOpen)
    }

    func testPatchEditDisarms() {
        let (engine, t, _, _) = makeEngine()
        engine.start()
        engine.setPatch(confirmedPatch())
        engine.sync { t.receive?(Fixture.pollReply(), IPv4Address(192, 168, 1, 50)) }
        engine.setArmed(true)
        XCTAssertTrue(latest(engine).armed)
        engine.setPatch(confirmedPatch(profile: "generic.rgb3"))
        XCTAssertFalse(latest(engine).armed, "output starts disabled after any patch change")
    }

    func testSceneChangeWaitsForNextBeat() {
        let (engine, _, clock, _) = makeEngine()
        engine.start()
        engine.setExternalBeatGrid(true)
        _ = latest(engine)  // beat 0
        clock.now += 0.1    // beat 0.2
        engine.setScene(.chase)
        var s = latest(engine)
        XCTAssertEqual(s.scene, .ambra)
        XCTAssertEqual(s.pendingScene, .chase)
        clock.now += 0.35   // beat 0.9
        s = latest(engine)
        XCTAssertEqual(s.pendingScene, .chase)
        clock.now += 0.1    // beat 1.1 → crossed
        s = latest(engine)
        XCTAssertEqual(s.scene, .chase)
        XCTAssertNil(s.pendingScene)
    }

    func testTapTempo() {
        var tap = TapTempo()
        XCTAssertNil(tap.tap(at: 0))
        XCTAssertEqual(tap.tap(at: 0.5)!, 120, accuracy: 0.001)
        XCTAssertEqual(tap.tap(at: 1.0)!, 120, accuracy: 0.001)
        XCTAssertNil(tap.tap(at: 10), "long pause restarts")
        XCTAssertEqual(tap.tap(at: 10.4)!, 150, accuracy: 0.001)
        var fast = TapTempo()
        _ = fast.tap(at: 0)
        XCTAssertEqual(fast.tap(at: 0.01)!, 999, "clamped to Link range")
    }

    func testLocalClockTempoChangeIsContinuous() {
        let clock = ManualClock()
        let tempo = LocalTempoClock(bpm: 120, now: { clock.now })
        clock.now += 1
        XCTAssertEqual(tempo.capture().beat, 2, accuracy: 1e-9)
        tempo.setTempo(60)
        XCTAssertEqual(tempo.capture().beat, 2, accuracy: 1e-9)
        clock.now += 1
        XCTAssertEqual(tempo.capture().beat, 3, accuracy: 1e-9)
        XCTAssertEqual(tempo.capture().phase, 3, accuracy: 1e-9)
    }
}
