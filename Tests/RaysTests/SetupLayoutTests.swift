import XCTest
@testable import RaysControl
@testable import RaysEngine
@testable import RaysOutput

final class SetupLayoutTests: XCTestCase {
    func testEveryControlActionIsInExactlyOneGroup() {
        let grouped = ControlGroup.allCases.flatMap(\.actions)
        XCTAssertEqual(grouped.count, ControlAction.allCases.count)
        XCTAssertEqual(Set(grouped), Set(ControlAction.allCases))
        XCTAssertTrue(ControlGroup.allCases.allSatisfy { !$0.actions.isEmpty })
        XCTAssertEqual(ControlGroup.scenes.actions.prefix(6), [.scene1, .scene2, .scene3, .scene4, .scene5, .scene6])
        XCTAssertEqual(ControlAction.master.setupGroup, .levels)
        XCTAssertEqual(ControlAction.blackout.setupGroup, .show)
        XCTAssertEqual(ControlAction.rateDouble.setupGroup, .speed)
    }

    private func target(verified: Bool, fresh: Bool) -> OutputTarget {
        OutputTarget(ip: IPv4Address(192, 168, 0, 10), name: "ODE", universes: [], verified: verified, fresh: fresh)
    }

    func testOutputIsReadyOnlyWithALiveTarget() {
        var network = NetworkStatus()
        XCTAssertFalse(SetupProgress(network: network, lightsReady: true, controllerConnected: false).outputReady)
        network.target = target(verified: true, fresh: false)
        XCTAssertFalse(SetupProgress(network: network, lightsReady: true, controllerConnected: false).outputReady)
        network.target = target(verified: true, fresh: true)
        XCTAssertTrue(SetupProgress(network: network, lightsReady: true, controllerConnected: false).outputReady)
        network.target = target(verified: false, fresh: false)
        XCTAssertTrue(
            SetupProgress(network: network, lightsReady: true, controllerConnected: false).outputReady,
            "manual IP, sACN and USB targets have no discovery to verify them")
        network.socketError = "closed"
        XCTAssertFalse(SetupProgress(network: network, lightsReady: true, controllerConnected: false).outputReady)
    }

    func testSetupOpensOnTheFirstRequiredStepStillOpen() {
        XCTAssertEqual(SetupProgress(outputReady: false, lightsReady: false, controllerConnected: false).firstOpenStep, .output)
        XCTAssertEqual(SetupProgress(outputReady: true, lightsReady: false, controllerConnected: false).firstOpenStep, .lights)
        XCTAssertEqual(
            SetupProgress(outputReady: true, lightsReady: true, controllerConnected: false).firstOpenStep, .output,
            "the controller is optional")
        let done = SetupProgress(outputReady: true, lightsReady: true, controllerConnected: true)
        XCTAssertEqual(done.isDone(.controller), true)
        XCTAssertNil(done.isDone(.advanced))
    }
}
