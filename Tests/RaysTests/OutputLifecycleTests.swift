import XCTest
@testable import RaysOutput
@testable import RaysTempo
@testable import RaysCore
@testable import RaysEngine

final class OutputLifecycleTests: XCTestCase {
    private func rig(universes: [Int] = [0]) -> (LightEngine, FakeTransport, ManualClock) {
        let transport = FakeTransport()
        let clock = ManualClock()
        let source = LocalTempoClock(bpm: 120, now: { clock.now })
        let engine = LightEngine(tempo: source, transport: transport, interfaces: { [Fixture.lan] },
                                 clock: { clock.now }, runsTimer: false)
        var patch = Patch(fixtures: universes.map {
            .init(label: "Test U\($0)", profileID: "generic.rgb3", universe: $0, address: 1)
        })
        patch.setConfirmed(true, library: ProfileLibrary())
        engine.start(); engine.setPatch(patch); engine.setMaster(1)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        return (engine, transport, clock)
    }

    private func state(_ engine: LightEngine) -> EngineSnapshot {
        var snapshot = EngineSnapshot()
        engine.onSnapshot = { snapshot = $0 }
        engine.stepForTesting()
        return snapshot
    }

    func testDiagnosticUsesValidatedOutputAndAutomaticallyBlacksOut() {
        let (engine, transport, clock) = rig()
        engine.runDiagnostic(.init(1, 0, 0), duration: 5)
        let test = state(engine)
        XCTAssertTrue(test.armed)
        XCTAssertTrue(test.isTesting)
        XCTAssertEqual(Array(transport.dmxPackets.last!.bytes[18..<21]), [255, 0, 0])
        clock.now += 5.1
        let done = state(engine)
        XCTAssertFalse(done.armed)
        XCTAssertFalse(done.isTesting)
        XCTAssertTrue(transport.dmxPackets.suffix(3).allSatisfy { $0.bytes[18...].allSatisfy { $0 == 0 } })
    }

    func testBlackoutImmediatelyCancelsDiagnostic() {
        let (engine, transport, _) = rig()
        engine.runDiagnostic(.init(0, 1, 0))
        XCTAssertTrue(state(engine).isTesting)
        engine.setBlackout(true)
        let black = state(engine)
        XCTAssertTrue(black.blackout)
        XCTAssertFalse(black.isTesting)
        XCTAssertFalse(black.armed, "Cancelling a diagnostic must preserve the original off state")
        XCTAssertTrue(transport.dmxPackets.last!.bytes[18...].allSatisfy { $0 == 0 })
        engine.setBlackout(false)
        XCTAssertFalse(state(engine).armed, "Clearing blackout must not arm a cancelled diagnostic")
    }

    func testDiagnosticIsIgnoredDuringBlackout() {
        let (engine, transport, clock) = rig()
        engine.setArmed(true)
        engine.setBlackout(true)
        XCTAssertTrue(state(engine).blackout)
        engine.runDiagnostic(.init(1, 1, 1), duration: 5)
        let during = state(engine)
        XCTAssertTrue(during.blackout, "A diagnostic must never clear blackout")
        XCTAssertFalse(during.isTesting)
        XCTAssertTrue(transport.dmxPackets.last!.bytes[18...].allSatisfy { $0 == 0 })
        clock.now += 5.1
        let after = state(engine)
        XCTAssertTrue(after.blackout)
        XCTAssertTrue(after.armed, "The output the user turned on stays on, still blacked out")
        XCTAssertTrue(transport.dmxPackets.last!.bytes[18...].allSatisfy { $0 == 0 })
    }

    func testDiagnosticIsIgnoredDuringBlackoutWithOutputOff() {
        let (engine, transport, _) = rig()
        engine.setBlackout(true)
        let sentBefore = transport.dmxPackets.count
        engine.runDiagnostic(.init(1, 0, 0))
        let s = state(engine)
        XCTAssertTrue(s.blackout)
        XCTAssertFalse(s.armed, "A diagnostic during blackout must not arm the output")
        XCTAssertFalse(s.isTesting)
        XCTAssertTrue(transport.dmxPackets.dropFirst(sentBefore).allSatisfy { $0.bytes[18...].allSatisfy { $0 == 0 } })
    }

    func testStaleNodePausesAndAttemptsFinalZeroFrame() {
        let (engine, transport, clock) = rig()
        engine.setArmed(true)
        XCTAssertTrue(state(engine).armed)
        clock.now += 11
        let lost = state(engine)
        XCTAssertFalse(lost.armed)
        XCTAssertTrue(lost.outputRequested, "A temporary outage must retain the user's output request")
        XCTAssertEqual(lost.readiness, .noDevice)
        XCTAssertTrue(transport.dmxPackets.last!.bytes[18...].allSatisfy { $0 == 0 })
    }

    func testReturningNodeAutomaticallyResumesAtItsNewIP() {
        let (engine, transport, clock) = rig()
        engine.setArmed(true)
        XCTAssertTrue(state(engine).isLive)
        clock.now += 11
        XCTAssertFalse(state(engine).isLive)
        let pausedCount = transport.dmxPackets.count
        _ = state(engine)
        XCTAssertEqual(transport.dmxPackets.count, pausedCount, "No continuing DMX while disconnected")
        let ip = IPv4Address(192, 168, 1, 75)
        engine.sync { transport.receive?(Fixture.pollReply(ip: ip), ip) }
        XCTAssertTrue(state(engine).isLive)
        XCTAssertEqual(transport.dmxPackets.last?.to, ip)
    }

    func testExplicitOffDuringOutageCancelsReconnection() {
        let (engine, transport, clock) = rig()
        engine.setArmed(true)
        XCTAssertTrue(state(engine).isLive)
        clock.now += 11
        XCTAssertFalse(state(engine).armed)
        engine.setOutputRequested(false)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        let count = transport.dmxPackets.count
        let off = state(engine)
        XCTAssertFalse(off.outputRequested)
        XCTAssertFalse(off.armed)
        XCTAssertEqual(transport.dmxPackets.count, count)
    }

    func testSavedRequestWaitsForDiscoveryWithoutNeedingAButton() {
        let (engine, transport, clock) = rig()
        clock.now += 11
        engine.setOutputRequested(true)
        let pending = state(engine)
        XCTAssertTrue(pending.outputRequested)
        XCTAssertFalse(pending.armed)
        XCTAssertTrue(transport.dmxPackets.isEmpty)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        XCTAssertTrue(state(engine).isLive)
    }

    func testUnrelatedNodeDoesNotResumeSelectedDevice() {
        let (engine, transport, clock) = rig()
        engine.setArmed(true)
        _ = state(engine)
        clock.now += 11
        _ = state(engine)
        engine.sync {
            transport.receive?(Fixture.pollReply(ip: .init(192, 168, 1, 80), mac: [1, 2, 3, 4, 5, 6]), .init(192, 168, 1, 80))
        }
        XCTAssertFalse(state(engine).armed)
        XCTAssertTrue(state(engine).outputRequested)
    }

    func testReconnectionDoesNotClearBlackoutOrSendDiagnosticColor() {
        let (engine, transport, clock) = rig()
        engine.setArmed(true)
        engine.runDiagnostic(.init(1, 0, 0), duration: 10)
        XCTAssertTrue(state(engine).isTesting)
        clock.now += 11
        _ = state(engine)
        engine.setBlackout(true)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        let resumed = state(engine)
        XCTAssertTrue(resumed.isLive)
        XCTAssertTrue(resumed.blackout)
        XCTAssertFalse(resumed.isTesting)
        XCTAssertTrue(transport.dmxPackets.last!.bytes[18...].allSatisfy { $0 == 0 })
    }

    func testPatchChangeCancelsPendingOutputRequest() {
        let (engine, transport, clock) = rig()
        engine.setArmed(true)
        _ = state(engine)
        clock.now += 11
        _ = state(engine)
        engine.setPatch(.empty)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        let count = transport.dmxPackets.count
        let off = state(engine)
        XCTAssertFalse(off.outputRequested)
        XCTAssertFalse(off.armed)
        XCTAssertEqual(off.readiness, .noPatch)
        XCTAssertEqual(transport.dmxPackets.count, count)
    }

    func testBindFailureRetriesWithoutBusyLoopAndRecovers() {
        let (engine, transport, clock) = rig()
        engine.shutdown()
        engine.sync { transport.failBind = true }
        engine.start()
        engine.setOutputRequested(true)
        let offline = state(engine)
        XCTAssertFalse(offline.armed)
        XCTAssertNotNil(offline.network.socketError)
        engine.sync { transport.failBind = false }
        clock.now += 1
        _ = state(engine)
        engine.sync { XCTAssertFalse(transport.isOpen, "Retry at most once per poll interval") }
        clock.now += 2.1
        let recovered = state(engine)
        engine.sync { XCTAssertTrue(transport.isOpen) }
        XCTAssertNil(recovered.network.socketError)
        XCTAssertTrue(recovered.isLive)
    }

    func testSleepWakeRetainsOutputIntentAndRediscovers() {
        let (engine, transport, clock) = rig()
        engine.setArmed(true)
        XCTAssertTrue(state(engine).isLive)
        engine.suspend()
        engine.sync { XCTAssertFalse(transport.isOpen) }
        clock.now += 30
        engine.resume()
        XCTAssertFalse(state(engine).armed)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        XCTAssertTrue(state(engine).isLive)
    }

    func testDiagnosticFromOffDoesNotCreateAReconnectionRequest() {
        let (engine, transport, clock) = rig()
        engine.runDiagnostic(.init(1, 0, 0))
        XCTAssertFalse(state(engine).outputRequested)
        clock.now += 11
        _ = state(engine)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        XCTAssertFalse(state(engine).armed)
        XCTAssertFalse(state(engine).outputRequested)
    }

    func testOutputIntentPersistsAndOlderPreferencesStillDecode() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"scene":"pulse"}"#.utf8))
        XCTAssertFalse(old.outputEnabled)
        XCTAssertFalse(old.blackout)
        var prefs = old
        prefs.outputEnabled = true
        prefs.blackout = true
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs)), prefs)
        prefs.outputEnabled = false
        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs)).outputEnabled)
    }

    func testEveryPatchedUniverseMustBeSubscribed() {
        let (engine, transport, clock) = rig(universes: [0, 1])
        clock.now += 0.1
        // Both bind pages now advertise only universe zero.
        engine.sync { transport.receive?(Fixture.pollReply(swOut: [0], portTypes: [0x80]), .init(192, 168, 1, 50)) }
        engine.setArmed(true)
        let snapshot = state(engine)
        XCTAssertFalse(snapshot.armed)
        XCTAssertEqual(snapshot.readiness, .noMatchingUniverse)
        XCTAssertTrue(transport.dmxPackets.isEmpty)
    }

    func testSACNConfiguredPortIsNotAnArtNetSubscriber() throws {
        var bytes = Fixture.pollReply()
        bytes[182] = 1 // GoodOutput bit0 means sACN conversion.
        let reply = try ArtPollReply.parse(bytes)
        XCTAssertEqual(reply.outputPorts.map(\.portAddress), [PortAddress(1)!])
    }
}

final class OutputSettingsTests: XCTestCase {
    func testOldPreferencesKeepArtNetAndSettingsRoundTrip() throws {
        let old = #"{"master":0.4,"outputEnabled":true}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(old.utf8))
        XCTAssertEqual(prefs.output.driverID, "artnet")
        XCTAssertEqual(prefs.output, OutputSettings())
        XCTAssertEqual(Preferences(), Preferences(), "defaults must stay comparable (no random CID)")

        var s = OutputSettings()
        s.driverID = "sacn"
        s.sacn.mode = .unicast
        s.sacn.unicastIP = IPv4Address(10, 0, 0, 9)
        s.sacn.priority = 150
        s.sacn.cid = UUID()
        s.dmxUSBPro.devicePath = "/dev/cu.usbserial-X"
        var p = Preferences(); p.output = s
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p)).output, s)

        let partial = #"{"output":{"driverID":"dmxusbpro","sacn":{"priority":250,"universeOffset":7}}}"#
        let q = try JSONDecoder().decode(Preferences.self, from: Data(partial.utf8))
        XCTAssertEqual(q.output.driverID, "dmxusbpro")
        XCTAssertEqual(q.output.sacn.priority, 200)
        XCTAssertEqual(q.output.sacn.universeOffset, 1)
        XCTAssertNil(q.output.dmxUSBPro.devicePath)
    }

    func testRegistryFromSettingsBuildsEveryDriverAndUnknownFallsBackToArtNet() {
        let r = OutputSettings().registry
        XCTAssertEqual(Set(r.descriptors.map(\.id)), ["artnet", "sacn", "dmxusbpro"])
        XCTAssertTrue(r.make(id: "sacn", transport: FakeTransport(), interfaces: { [] }) is SACNDriver)
        XCTAssertTrue(r.make(id: "dmxusbpro", transport: FakeTransport(), interfaces: { [] }) is DMXUSBProDriver)
        XCTAssertTrue(r.make(id: "nope", transport: FakeTransport(), interfaces: { [] }) is ArtNetController)
    }

    func testSwitchingDriverDisarmsAndSendsBlackOnTheOldDriver() throws {
        let t = FakeTransport()
        let clock = ManualClock()
        let engine = LightEngine(tempo: LocalTempoClock(), transport: t, interfaces: { [Fixture.lan] },
                                 clock: { clock.now }, runsTimer: false)
        engine.start()
        XCTAssertEqual(engine.outputDriverID, "artnet")
        engine.useOutputDriver("sacn", registry: OutputSettings().registry)
        XCTAssertEqual(engine.outputDriverID, "sacn")
        XCTAssertTrue(t.isOpen, "the new driver is opened while the engine runs")
        engine.useOutputDriver("artnet", registry: OutputSettings().registry)
        XCTAssertEqual(engine.outputDriverID, "artnet")
        engine.stop()
    }
}
