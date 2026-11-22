import XCTest
@testable import LightCore

final class RigAutoSetupTests: XCTestCase {
    func testKnownBenchUpgradesWithoutMovingTheTestedLamp() throws {
        let bench = VarytecRig.tri180Test(), library = ProfileLibrary()
        let rig = try XCTUnwrap(RigAutoSetup.preparedRig(replacing: bench, library: library))
        XCTAssertEqual(rig.fixtures[0].id, bench.fixtures[0].id)
        XCTAssertEqual(rig.fixtures.map(\.address), [8, 24, 16])
        XCTAssertTrue(rig.isConfirmed(library: library))
        XCTAssertTrue(rig.validate(library: library).isEmpty)
    }
    func testFreshRigReadyAndCustomPatchKept() {
        let library = ProfileLibrary()
        XCTAssertEqual(RigAutoSetup.preparedRig(replacing: nil, library: library)?.fixtures.count, 3)
        var custom = VarytecRig.tri180Test()
        custom.fixtures[0].address = 50
        XCTAssertNil(RigAutoSetup.preparedRig(replacing: custom, library: library))
        XCTAssertNil(RigAutoSetup.preparedRig(replacing: VarytecRig.referenceRig(), library: library))
    }
}
