import Foundation
import XCTest
@testable import LightCore

final class OutputActivityTests: XCTestCase {
    func testFramesAndReconnectsKeepOneActivityUntilOutputIsSwitchedOff() {
        var began = 0
        var ended = 0
        let token = NSObject()
        let activity = OutputActivity(begin: { began += 1; return token }, end: {
            XCTAssertTrue(($0 as AnyObject) === token)
            ended += 1
        })
        activity.update(active: false)
        XCTAssertEqual(began, 0, "Preview-only use must allow idle sleep")
        for _ in 0..<1800 { activity.update(active: true) }
        XCTAssertEqual(began, 1, "30 Hz snapshots must not allocate a new activity each frame")
        XCTAssertEqual(ended, 0, "An active session remains protected when its window is hidden")
        activity.update(active: false)
        activity.update(active: false)
        XCTAssertEqual(ended, 1)
        activity.update(active: true)
        XCTAssertEqual(began, 2, "An explicitly restarted session acquires a fresh activity")
        activity.stop()
        activity.stop()
        XCTAssertEqual(ended, 2)
    }

    func testActivityIsReleasedWhenOwnerIsDestroyed() {
        var ended = 0
        var activity: OutputActivity? = OutputActivity(begin: { NSObject() }, end: { _ in ended += 1 })
        activity?.update(active: true)
        activity = nil
        XCTAssertEqual(ended, 1)
    }

    func testPowerOptionsAllowDisplaySleepWithoutRequestingMaximumTimerPrecision() {
        XCTAssertTrue(OutputActivity.options.contains(.idleSystemSleepDisabled))
        XCTAssertFalse(OutputActivity.options.contains(.idleDisplaySleepDisabled))
        XCTAssertTrue(OutputActivity.options.intersection(.latencyCritical).isEmpty)
    }
}
