import XCTest
@testable import LightCore

final class CustomRigLookTests: XCTestCase {
    func testDefaultLookPreservesChoreographyAndCustomColorsReachAllSegments() throws {
        let original = Choreography.render(.chase, SceneContext(beat: 2, energy: 0.8))
        let defaultLook = CustomScene(base: .chase)
        XCTAssertEqual(defaultLook.applyingLook(to: original), original)
        var red = defaultLook
        red.colors = Array(repeating: SceneRGB(r: 1, g: 0, b: 0), count: 3)
        red.warmth = 0
        let input = RigFrame(left: RoleFrame(rgb: [.init(0, 0, 0.6)], cob: [0.1]),
                             center: RoleFrame(rgb: (0..<6).map { $0 % 2 == 0 ? LightColor(0, 0.5, 0) : LightColor(0, 0, 0.8) }, cob: [0.2, 0.1, 0.3]),
                             right: RoleFrame(rgb: [.init(0, 0.4, 0)], cob: [0.1]))
        let styled = red.applyingLook(to: input)
        XCTAssertEqual(styled.center.rgb.count, 6)
        XCTAssertEqual(styled.center.cob, [0, 0, 0])
        for c in styled.left.rgb + styled.center.rgb + styled.right.rgb where max(c.r, c.g, c.b) > 0 {
            XCTAssertGreaterThan(c.r, 0)
            XCTAssertEqual(c.g, 0, accuracy: 0.00001)
            XCTAssertEqual(c.b, 0, accuracy: 0.00001)
        }
        let library = ProfileLibrary()
        let profile = try XCTUnwrap(library.profile(id: "varytec.tri380.25"))
        let zero = DMXComposer.channelValues(profile: profile, levels: FixtureLevels(styled.center), scale: 0)
        XCTAssertTrue(zero.allSatisfy { $0 == 0 })
    }
}
