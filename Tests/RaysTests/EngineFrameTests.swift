import XCTest
@testable import RaysOutput
@testable import RaysTempo
@testable import RaysCore
@testable import RaysEngine

/// The 30 Hz frame: one tempo capture and one readiness per frame, cached patch data, and the
/// network part of the snapshot refreshed at a low rate but right away after user actions.
final class EngineFrameTests: XCTestCase {
    /// Each capture is a new instant: the beat counts captures and Link peers come and go.
    private final class CountingTempo: TempoSource {
        var captures = 0
        func capture() -> TempoSnapshot {
            captures += 1
            return TempoSnapshot(bpm: 120, beat: Double(captures), phase: 0, peers: captures % 2)
        }
        func setTempo(_ bpm: Double) {}
        func setStartStopSync(_ enabled: Bool) {}
    }

    private func makeEngine(
        tempo: TempoSource? = nil, patch: Patch? = nil, start: Bool = true
    ) -> (LightEngine, FakeTransport, ManualClock) {
        let transport = FakeTransport()
        let clock = ManualClock()
        let engine = LightEngine(
            tempo: tempo ?? LocalTempoClock(bpm: 120, now: { clock.now }), transport: transport,
            interfaces: { [Fixture.lan] }, clock: { clock.now }, runsTimer: false)
        if start { engine.start() }
        if let patch { engine.setPatch(patch) }
        engine.setMaster(1)
        if start { engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) } }
        return (engine, transport, clock)
    }

    private func confirmed(_ fixtures: [PatchedFixture]) -> Patch {
        var patch = Patch(fixtures: fixtures)
        patch.setConfirmed(true, library: ProfileLibrary())
        return patch
    }

    private func onePatch() -> Patch {
        confirmed([.init(label: "A", profileID: "generic.rgb3", universe: 0, address: 1)])
    }

    private func state(_ engine: LightEngine) -> EngineSnapshot {
        var snapshot = EngineSnapshot()
        engine.onSnapshot = { snapshot = $0 }
        engine.stepForTesting()
        return snapshot
    }

    private static let otherNode = Fixture.pollReply(
        ip: IPv4Address(192, 168, 1, 80), shortName: "Other", longName: "Other node", esta: 0, mac: [1, 2, 3, 4, 5, 6])

    func testOneTempoCapturePerFrameAndTheSnapshotDescribesIt() {
        let tempo = CountingTempo()
        let (engine, _, _) = makeEngine(tempo: tempo, patch: onePatch())
        for _ in 0..<4 {
            let before = engine.sync { tempo.captures }
            let s = state(engine)
            XCTAssertEqual(engine.sync { tempo.captures } - before, 1, "one capture per frame")
            XCTAssertEqual(s.tempo.beat, Double(before + 1), "the snapshot shows the frame's tempo")
            XCTAssertEqual(s.gridTrusted, s.tempo.peers > 0, "grid trust comes from the same capture")
        }
    }

    func testSnapshotReadinessMatchesTheFrameTarget() {
        let (engine, _, clock) = makeEngine(patch: onePatch())
        engine.setArmed(true)
        let live = state(engine)
        XCTAssertEqual(live.readiness, .ready)
        XCTAssertEqual(live.network.target?.fresh, true)
        XCTAssertTrue(live.isLive)
        clock.now += 10.5
        let stale = state(engine)
        XCTAssertEqual(stale.readiness, .noDevice)
        XCTAssertEqual(stale.network.target?.fresh, false, "readiness and target come from the same lookup")
        XCTAssertFalse(stale.armed)
        XCTAssertTrue(stale.outputRequested)
    }

    func testNetworkStatusIsThrottledButFollowsUserActionsAtOnce() throws {
        let (engine, transport, clock) = makeEngine(patch: onePatch())
        let first = state(engine)
        XCTAssertEqual(first.network.nodes.count, 1)
        XCTAssertNotNil(first.network.selectedID, "the only ENTTEC node is auto-selected")

        engine.sync { transport.receive?(Self.otherNode, IPv4Address(192, 168, 1, 80)) }
        XCTAssertEqual(state(engine).network.nodes.count, 1, "node lists are not rebuilt every frame")
        engine.rediscover()
        let rediscovered = state(engine)
        XCTAssertEqual(rediscovered.network.nodes.count, 2, "rediscovery refreshes at once")

        let other = try XCTUnwrap(rediscovered.network.nodes.first { $0.ip == IPv4Address(192, 168, 1, 80) }?.id)
        engine.selectNode(other)
        let selected = state(engine)
        XCTAssertEqual(selected.network.selectedID, other)
        XCTAssertEqual(selected.network.target?.ip, IPv4Address(192, 168, 1, 80))

        engine.setManualIP(IPv4Address(192, 168, 1, 99))
        XCTAssertEqual(state(engine).network.manualIP, IPv4Address(192, 168, 1, 99))

        let third = Fixture.pollReply(
            ip: IPv4Address(192, 168, 1, 81), shortName: "Third", longName: "Third node", esta: 0, mac: [1, 2, 3, 4, 5, 7])
        engine.sync { transport.receive?(third, IPv4Address(192, 168, 1, 81)) }
        XCTAssertEqual(state(engine).network.nodes.count, 2)
        clock.now += LightEngine.networkRefreshInterval
        XCTAssertEqual(state(engine).network.nodes.count, 3, "and still at a low rate on its own")
    }

    func testNetworkStatusFollowsDriverChangeAndSocketErrors() {
        let (engine, transport, clock) = makeEngine(patch: onePatch())
        XCTAssertEqual(state(engine).network.nodes.count, 1)
        engine.useOutputDriver("sacn", registry: OutputSettings().registry)
        let sacn = state(engine)
        XCTAssertEqual(engine.outputDriverID, "sacn")
        XCTAssertEqual(sacn.network.nodes, [], "the new driver's status is shown at once")

        engine.useOutputDriver("artnet", registry: OutputSettings().registry)
        engine.shutdown()
        engine.sync { transport.failBind = true }
        engine.start()
        XCTAssertNotNil(state(engine).network.socketError)
        engine.sync { transport.failBind = false }
        clock.now += 3.1
        XCTAssertNil(state(engine).network.socketError, "a reopened socket clears the error")
    }

    func testClosedOutputMessageIsNotArtNetSpecific() {
        let (engine, _, _) = makeEngine(patch: onePatch(), start: false)
        XCTAssertEqual(state(engine).readiness, .socketUnavailable("Output closed"))
    }

    func testVisualsKeepTheirOrderIdsAndStatus() {
        let left = PatchedFixture(label: "L", profileID: "generic.rgb3", universe: 0, address: 4, role: .left)
        let right = PatchedFixture(label: "R1", profileID: "generic.rgb3", universe: 0, address: 1, role: .right)
        let right2 = PatchedFixture(label: "R2", profileID: "generic.rgb3", universe: 0, address: 7, role: .right)
        let (engine, _, _) = makeEngine(patch: confirmed([right, left, right2]))
        let off = state(engine)
        XCTAssertFalse(off.isDemo)
        XCTAssertEqual(off.fixtures.map(\.id), [left.id.uuidString, "preview-center", right.id.uuidString, right2.id.uuidString])
        XCTAssertEqual(off.fixtures.map(\.label), ["L", "TRI 380 · centro", "R1", "R2"])
        XCTAssertEqual(off.fixtures.map(\.role), [.left, .center, .right, .right])
        XCTAssertEqual(off.fixtures.map(\.address), [4, 24, 1, 7])
        XCTAssertEqual(off.fixtures.map(\.status), [.off, .previewOnly, .off, .off])
        XCTAssertEqual(off.fixtures[0].profileID, "generic.rgb3")
        XCTAssertEqual(off.fixtures[1].profileID, "varytec.tri380.25")
        XCTAssertEqual(off.fixtures[1].rgb.count, 6, "the shadow fixture keeps its resolved profile")

        engine.setArmed(true)
        let live = state(engine)
        XCTAssertEqual(live.fixtures.map(\.status), [.live, .previewOnly, .live, .live])
        XCTAssertEqual(live.fixtures.map(\.id), off.fixtures.map(\.id))
    }

    func testVisualsFollowPatchChanges() {
        let (engine, _, _) = makeEngine(patch: nil)
        let demo = state(engine)
        XCTAssertTrue(demo.isDemo)
        XCTAssertEqual(demo.fixtures.map(\.id), ["preview-left", "preview-center", "preview-right"])
        XCTAssertTrue(demo.fixtures.allSatisfy { $0.status == .previewOnly })

        let center = PatchedFixture(label: "C", profileID: "generic.rgbw4", universe: 0, address: 1, role: .center)
        engine.setPatch(confirmed([center]))
        let patched = state(engine)
        XCTAssertEqual(patched.fixtures.map(\.id), ["preview-left", center.id.uuidString, "preview-right"])
        XCTAssertEqual(patched.fixtures[1].profileID, "generic.rgbw4")

        // An invalid patch is not shown: back to the full preview rig.
        engine.setPatch(Patch(fixtures: [.init(label: "X", profileID: "no.such.profile", universe: 0, address: 1)]))
        let invalid = state(engine)
        XCTAssertTrue(invalid.isDemo)
        XCTAssertEqual(invalid.fixtures.map(\.id), ["preview-left", "preview-center", "preview-right"])
    }

    func testItalianTableTranslatesTheDriverNeutralMessage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization/it.lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let table = try XCTUnwrap(plist as? [String: String])
        XCTAssertNotNil(table["Output closed"])
        XCTAssertNil(table["Art-Net socket closed"])
    }
}
