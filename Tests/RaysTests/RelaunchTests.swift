import XCTest
@testable import RaysEngine

/// "Restart now" opens a new copy that names the one it replaces.
final class RelaunchTests: XCTestCase {
    func testTheNewCopyFindsTheProcessItReplaces() {
        let args = ["/Applications/RAYS.app/Contents/MacOS/LightSystem"] + Relaunch.arguments(replacing: 4242)
        XCTAssertEqual(Relaunch.replacedProcess(in: args), 4242)
    }

    func testAnOrdinaryLaunchReplacesNothing() {
        XCTAssertNil(Relaunch.replacedProcess(in: ["LightSystem"]))
        XCTAssertNil(Relaunch.replacedProcess(in: ["LightSystem", "-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertNil(Relaunch.replacedProcess(in: ["LightSystem", Relaunch.argument]))
        XCTAssertNil(Relaunch.replacedProcess(in: ["LightSystem", Relaunch.argument, "abc"]))
        XCTAssertNil(Relaunch.replacedProcess(in: ["LightSystem", Relaunch.argument, "0"]))
    }
}
