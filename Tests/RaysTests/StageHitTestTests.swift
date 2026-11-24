import CoreGraphics
import XCTest
@testable import RaysCore

/// Clicking a light in the stage preview selects it.
final class StageHitTestTests: XCTestCase {
    private let layout = StageLayout(size: CGSize(width: 990, height: 460), large: [false, true, false])

    func testCentresAndLabelsSelectTheirFixture() {
        for (index, fixture) in layout.fixtures.enumerated() {
            XCTAssertEqual(layout.fixtureIndex(at: fixture.center), index)
            XCTAssertEqual(layout.fixtureIndex(at: fixture.labelCenter), index, "label of \(index)")
            let nearTop = CGPoint(x: fixture.top.x, y: fixture.top.y - 4)
            XCTAssertEqual(layout.fixtureIndex(at: nearTop), index, "just above the apex is within the margin")
        }
    }

    func testEmptyStageSelectsNothing() {
        XCTAssertNil(layout.fixtureIndex(at: CGPoint(x: 2, y: 2)))
        let left = layout.fixtures[0], center = layout.fixtures[1]
        let gap = CGPoint(x: (left.right.x + center.left.x) / 2, y: left.top.y)
        XCTAssertNil(layout.fixtureIndex(at: gap))
        XCTAssertNil(StageLayout(size: CGSize(width: 400, height: 200), large: []).fixtureIndex(at: CGPoint(x: 200, y: 100)))
    }

    func testTriangleDistance() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0), c = CGPoint(x: 0, y: 10)
        XCTAssertEqual(StageLayout.distance(CGPoint(x: 2, y: 2), toTriangle: a, b, c), 0)
        XCTAssertEqual(StageLayout.distance(CGPoint(x: 5, y: -3), toTriangle: a, b, c), 3, accuracy: 1e-9)
        XCTAssertEqual(StageLayout.distance(CGPoint(x: -3, y: -4), toTriangle: a, b, c), 5, accuracy: 1e-9)
    }
}
