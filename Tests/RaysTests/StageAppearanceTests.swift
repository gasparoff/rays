import CoreGraphics
import XCTest
@testable import RaysCore

/// The preview draws every light the way it looks, zone by zone in the order its profile declares.
final class StageAppearanceTests: XCTestCase {
    private let size = CGSize(width: 1400, height: 460)

    private var profilesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    private func spec(_ kind: FixtureShape, zones: Int = 1, cobs: Int = 0, order: ZoneLayout? = nil) -> StageFixtureSpec {
        StageFixtureSpec(appearance: FixtureAppearance(kind: kind, zones: order), zones: zones, cobs: cobs)
    }

    func testEveryKindHasABodyItsZonesAndCanBeClicked() {
        let specs = [
            spec(.par, zones: 1, cobs: 1), spec(.bar, zones: 4), spec(.strip, zones: 8), spec(.wash, zones: 4), spec(.spot),
            spec(.movingHead, zones: 3), spec(.blinder, cobs: 2), spec(.generic), StageFixtureSpec.triangle(large: true),
        ]
        let layout = StageLayout(size: size, specs: specs)
        XCTAssertEqual(layout.fixtures.map(\.kind), specs.map(\.appearance.kind))
        for (index, (fixture, spec)) in zip(layout.fixtures, specs).enumerated() {
            XCTAssertGreaterThanOrEqual(fixture.outline.count, 3, "\(fixture.kind)")
            XCTAssertEqual(Set(fixture.facets.map(\.segment)), Set(0..<max(1, spec.zones)), "\(fixture.kind) shows every zone")
            XCTAssertEqual(layout.fixtureIndex(at: fixture.center), index, "\(fixture.kind)")
            XCTAssertEqual(layout.fixtureIndex(at: fixture.labelCenter), index, "label of \(fixture.kind)")
            XCTAssertLessThanOrEqual(fixture.outline.map(\.y).max()!, layout.floor + 0.001, "\(fixture.kind) stands on the floor")
            for point in fixture.outline + fixture.hardware.flatMap({ $0 }) {
                XCTAssertTrue(point.x >= 0 && point.x <= size.width && point.y >= 0, "\(fixture.kind) stays on the stage")
            }
        }
        XCTAssertNil(layout.fixtureIndex(at: CGPoint(x: 2, y: 2)))
    }

    func testMovingHeadYokeAndBaseCountWhenClicking() {
        let layout = StageLayout(size: size, specs: [spec(.movingHead, zones: 1)])
        let head = layout.fixtures[0]
        XCTAssertEqual(head.hardware.count, 4)
        let base = StageLayout.centroid(head.hardware[0])
        XCTAssertGreaterThan(StageLayout.distance(base, toPolygon: head.outline), 20, "the base is below the head")
        XCTAssertEqual(layout.fixtureIndex(at: base), 0)
    }

    func testBarAndStripZonesRunLeftToRightInChannelOrder() {
        let layout = StageLayout(size: size, specs: [spec(.bar, zones: 3), spec(.strip, zones: 5)])
        for fixture in layout.fixtures {
            let byX = fixture.facets.sorted { StageLayout.centroid($0.points).x < StageLayout.centroid($1.points).x }.map(\.segment)
            XCTAssertEqual(byX, byX.sorted(), "\(fixture.kind)")
            XCTAssertEqual(byX.first, 0)
        }
    }

    func testDeclaredZoneOrderIsFollowed() {
        // A 2×2 grid panel: zone 0 top left, 1 top right, 2 bottom left, 3 bottom right.
        let wash = StageLayout(size: size, specs: [spec(.wash, zones: 4, order: .grid(columns: 2))]).fixtures[0]
        func zone(atUnit x: CGFloat, _ y: CGFloat) -> Int? {
            let target = CGPoint(x: wash.left.x + x * wash.width, y: wash.top.y + y * wash.height)
            return wash.facets.min {
                hypot(StageLayout.centroid($0.points).x - target.x, StageLayout.centroid($0.points).y - target.y)
                    < hypot(StageLayout.centroid($1.points).x - target.x, StageLayout.centroid($1.points).y - target.y)
            }?.segment
        }
        XCTAssertEqual([zone(atUnit: 0.1, 0.1), zone(atUnit: 0.9, 0.1), zone(atUnit: 0.1, 0.9), zone(atUnit: 0.9, 0.9)], [0, 1, 2, 3])

        // The same bar drawn with vertical zones would put them top to bottom: with one row they collapse to zone 0.
        XCTAssertEqual(StageLayout.zone(at: CGPoint(x: 0.9, y: 0.1), of: 2, .vertical), 0)
        XCTAssertEqual(StageLayout.zone(at: CGPoint(x: 0.9, y: 0.9), of: 2, .vertical), 1)
        // Radial: clockwise from the top.
        XCTAssertEqual(StageLayout.zone(at: CGPoint(x: 0.5, y: 0), of: 4, .radial), 0)
        XCTAssertEqual(StageLayout.zone(at: CGPoint(x: 1, y: 0.5), of: 4, .radial), 1)
        XCTAssertEqual(StageLayout.zone(at: CGPoint(x: 0.5, y: 1), of: 4, .radial), 2)
        XCTAssertEqual(StageLayout.zone(at: CGPoint(x: 0, y: 0.5), of: 4, .radial), 3)
        XCTAssertEqual(StageLayout.zone(at: CGPoint(x: 0.7, y: 0.2), of: 1, .grid(columns: 3)), 0)
    }

    func testWhiteEmittersMixIntoTheirElements() {
        XCTAssertNil(StageLayout.cob(forZone: 0, element: 0, zones: 2, cobs: 0))
        XCTAssertEqual((0..<4).map { StageLayout.cob(forZone: $0, element: 0, zones: 4, cobs: 4) }, [0, 1, 2, 3])
        XCTAssertEqual((0..<4).map { StageLayout.cob(forZone: $0, element: 0, zones: 4, cobs: 2) }, [0, 0, 1, 1])
        XCTAssertEqual((0..<3).map { StageLayout.cob(forZone: 0, element: $0, zones: 1, cobs: 3) }, [0, 1, 2])

        let led = StageLayout.Facet(points: [.zero, .zero, .zero], segment: 0, cob: 0, reflection: 1)
        let dark = StageLayout.elementColor(led, rgb: [.black], cob: [0])
        let warm = StageLayout.elementColor(led, rgb: [.black], cob: [1])
        XCTAssertEqual(dark.r, 0.095, accuracy: 1e-12)
        XCTAssertEqual(warm.r, 1, accuracy: 1e-12)
        XCTAssertGreaterThan(warm.g, warm.b, "warm white, not cold")
        let mirror = StageLayout.Facet(points: [.zero, .zero, .zero], segment: 0, cob: nil, reflection: 1)
        XCTAssertEqual(
            StageLayout.elementColor(mirror, rgb: [.black], cob: [1]).r, 0.095, accuracy: 1e-12, "mirrors keep white on the strips")
    }

    /// Every bundled profile is drawn with its own kind, all its zones and all its white emitters.
    func testEveryBundledProfileIsDrawnWithAllItsZonesAndWhites() {
        let all = ProfileLibrary.builtIn + ProfileLibrary.loadProfiles(in: profilesDirectory).profiles
        XCTAssertFalse(all.isEmpty)
        for profile in all {
            let spec = StageFixtureSpec(profile: profile)
            XCTAssertEqual(spec.appearance, profile.appearance, profile.id)
            let fixture = StageLayout(size: size, specs: [spec]).fixtures[0]
            XCTAssertEqual(fixture.kind, profile.appearance.kind, profile.id)
            XCTAssertEqual(Set(fixture.facets.map(\.segment)), Set(0..<max(1, profile.rgbSegmentCount)), profile.id)
            guard profile.cobCount > 0, fixture.kind != .spot, fixture.kind != .generic else { continue }
            if fixture.kind == .triangle {
                XCTAssertGreaterThanOrEqual(fixture.strips.count, profile.cobCount, profile.id)
            } else {
                XCTAssertEqual(Set(fixture.facets.compactMap(\.cob)), Set(0..<profile.cobCount), profile.id)
            }
        }
    }

    func testVarytecMirrorsKeepTheirSize() {
        let byID = Dictionary(uniqueKeysWithValues: ProfileLibrary.builtIn.map { ($0.id, $0) })
        let tri380 = StageFixtureSpec(profile: byID["varytec.tri380.25"]!)
        let tri180 = StageFixtureSpec(profile: byID["varytec.tri180.8"]!)
        XCTAssertEqual(tri380, .triangle(large: true))
        XCTAssertEqual(tri180, .triangle(large: false))
        let layout = StageLayout(size: CGSize(width: 990, height: 460), specs: [tri180, tri380, tri180])
        XCTAssertEqual(layout, StageLayout(size: CGSize(width: 990, height: 460), large: [false, true, false]))
    }

    func testPolygonDistance() {
        let square = StageLayout.rect(CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(StageLayout.distance(CGPoint(x: 5, y: 5), toPolygon: square), 0)
        XCTAssertEqual(StageLayout.distance(CGPoint(x: 13, y: 5), toPolygon: square), 3, accuracy: 1e-9)
        XCTAssertEqual(StageLayout.distance(CGPoint(x: 13, y: 14), toPolygon: square), 5, accuracy: 1e-9)
        XCTAssertEqual(StageLayout.distance(.zero, toPolygon: []), .infinity)
    }
}
