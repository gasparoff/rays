import XCTest
@testable import RaysCore
@testable import RaysEngine

final class ControlStateTests: XCTestCase {
    private func snapshot() -> EngineSnapshot {
        var value = EngineSnapshot()
        value.fixtures = [FixtureVisual(id: "c", label: "Centro", profileID: "varytec-tri380-25ch", role: .center,
            universe: 0, address: 24, rgb: [LightColor(1, 0, 0)], cob: [1], status: .off)]
        return value
    }

    func testLightingFramesDoNotInvalidateControls() {
        let first = snapshot()
        var next = first
        next.tempo.beat = 127.5
        next.tempo.phase = 3.5
        next.patternBeat = 12.5
        next.framesSent = 300
        next.fixtures[0].rgb = [LightColor(0, 0, 1)]
        next.fixtures[0].cob = [0.2]
        XCTAssertEqual(first.controlState, next.controlState)
        XCTAssertNotEqual(first.fixtures, next.fixtures, "rendering still receives the unmodified frame")
    }

    func testRigChangesReachStaticTargetOverlay() {
        let first = snapshot()
        var next = first
        next.fixtures[0].profileID = "varytec-tri180-8ch"
        XCTAssertNotEqual(first.controlState, next.controlState)
        next = first
        next.fixtures[0].role = .left
        XCTAssertNotEqual(first.controlState, next.controlState)
        next = first
        next.fixtures[0].label = "Centro nuovo"
        XCTAssertNotEqual(first.controlState, next.controlState)
        next = first
        next.fixtures.removeAll()
        XCTAssertNotEqual(first.controlState, next.controlState)
    }

    func testTempoSafetyAndSceneChangesStillReachControls() {
        let first = snapshot()
        let changes: [(inout EngineSnapshot) -> Void] = [
            { $0.blackout = true }, { $0.armed = true }, { $0.outputRequested = true }, { $0.sending = true },
            { $0.tempo.bpm = 138 }, { $0.tempo.peers = 1 }, { $0.scene = .respiro },
            { $0.sceneLook = ClubSceneBank.scene(for: .ambra) }, { $0.pendingScene = .chase },
            { $0.master = 0 }, { $0.stopped = true }, { $0.accentActive = true },
            { $0.network.socketError = "offline" }
        ]
        for change in changes {
            var next = first
            change(&next)
            XCTAssertNotEqual(first.controlState, next.controlState)
        }
    }

    /// Setup observes only `controlState` changes, so everything it shows must invalidate the key.
    func testSetupStatusReachesControls() {
        let first = snapshot()
        let changes: [(inout EngineSnapshot) -> Void] = [
            { $0.readiness = .ready },
            { $0.isTesting = true },
            { $0.blackout = true },
            { $0.network.selectedID = "node" },
            { $0.network.diagnosis = ["No ENTTEC"] },
            { $0.network.sendError = "send failed" },
            { $0.tempo.bpm = 128 },
        ]
        for change in changes {
            var next = first
            change(&next)
            XCTAssertNotEqual(first.controlState, next.controlState)
        }
    }
}
