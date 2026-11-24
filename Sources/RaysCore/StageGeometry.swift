import CoreGraphics
import Foundation

/// Geometry of the stage preview (faceted triangular mirrors, six RGB zones, COB strips), computed once
/// per view size and fixture models instead of on every 30 Hz frame. Coordinates are top-left origin, y down.
/// Pure numbers so the renderer and the tests share one source of truth.
public struct StageLayout: Equatable, Sendable {
    /// One triangular mirror facet.
    public struct Facet: Equatable, Sendable {
        public var a: CGPoint, b: CGPoint, c: CGPoint
        /// RGB zone 0…5, clockwise from the top around the fixture centre (clamped to the fixture's zone count when drawn).
        public var segment: Int
        /// Deterministic mirror reflectivity 0…1 (seeded by the facet position).
        public var reflection: Double
    }

    /// One linear COB strip.
    public struct Strip: Equatable, Sendable {
        public var from: CGPoint, to: CGPoint
    }

    /// Geometry of one fixture in the preview.
    public struct Fixture: Equatable, Sendable {
        public var large: Bool
        public var center: CGPoint
        public var width: CGFloat
        public var height: CGFloat
        public var top: CGPoint, left: CGPoint, right: CGPoint
        public var facets: [Facet]
        /// Warm COB strips in DMX order (TRI 380: 3, TRI 180: 1).
        public var strips: [Strip]
        public var labelCenter: CGPoint
        /// Gaussian radius of the coloured halo behind the mirror.
        public var faceGlowRadius: CGFloat { width * 0.09 }
        public var stripWidth: CGFloat { max(3, width * 0.035) }
        public var stripGlowWidth: CGFloat { width * 0.09 }
        public var stripCoreWidth: CGFloat { max(1, width * 0.012) }
    }

    public static let stripGlowRadius: CGFloat = 5

    public var size: CGSize
    public var large: [Bool]
    public var floor: CGFloat
    public var fixtures: [Fixture]

    public static func isLarge(profileID: String?) -> Bool { profileID?.contains("tri380") == true }

    /// Index of the fixture under `point` (view coordinates), for clicking a light in the preview.
    /// The mirror triangle counts, plus a margin of `slop` points around it and its label so small
    /// fixtures stay easy to hit. When two overlap, the nearest centre wins.
    public func fixtureIndex(at point: CGPoint, slop: CGFloat = 8) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, fixture) in fixtures.enumerated() {
            let onFace = Self.distance(point, toTriangle: fixture.top, fixture.left, fixture.right) <= slop
            let onLabel = abs(point.x - fixture.labelCenter.x) <= fixture.width / 2 && abs(point.y - fixture.labelCenter.y) <= 10 + slop
            guard onFace || onLabel else { continue }
            let d = hypot(point.x - fixture.center.x, point.y - fixture.center.y)
            if best == nil || d < best!.distance { best = (index, d) }
        }
        return best?.index
    }

    /// 0 inside the triangle, otherwise the distance to its nearest edge.
    static func distance(_ p: CGPoint, toTriangle a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        func cross(_ o: CGPoint, _ u: CGPoint, _ v: CGPoint) -> CGFloat { (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x) }
        let d1 = cross(p, a, b), d2 = cross(p, b, c), d3 = cross(p, c, a)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        if !(hasNegative && hasPositive) { return 0 }
        func segment(_ u: CGPoint, _ v: CGPoint) -> CGFloat {
            let dx = v.x - u.x, dy = v.y - u.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? min(1, max(0, ((p.x - u.x) * dx + (p.y - u.y) * dy) / length)) : 0
            return hypot(p.x - (u.x + t * dx), p.y - (u.y + t * dy))
        }
        return min(segment(a, b), segment(b, c), segment(c, a))
    }

    public init(size: CGSize, large: [Bool]) {
        self.size = size
        self.large = large
        let count = max(large.count, 1)
        floor = size.height * 0.79
        let floor = self.floor
        fixtures = large.enumerated().map { index, large in
            let maxWidth = min(size.width / CGFloat(count) * 0.82, size.height * 0.79)
            let width = maxWidth * (large ? 1 : 0.65)
            let height = width * 0.866
            let x = size.width * CGFloat(index * 2 + 1) / CGFloat(count * 2)
            return StageLayout.fixture(
                center: CGPoint(x: x, y: floor - height * 0.4), width: width, height: height,
                large: large, labelCenter: CGPoint(x: x, y: floor + 23))
        }
    }

    private static func fixture(center: CGPoint, width w: CGFloat, height h: CGFloat, large: Bool, labelCenter: CGPoint) -> Fixture {
        let top = CGPoint(x: center.x, y: center.y - h * 0.6)
        let left = CGPoint(x: center.x - w / 2, y: center.y + h * 0.4)
        let right = CGPoint(x: center.x + w / 2, y: center.y + h * 0.4)
        let rows = large ? 10 : 7
        func point(_ u: Int, _ v: Int) -> CGPoint {
            let a = CGFloat(u) / CGFloat(rows), b = CGFloat(v) / CGFloat(rows)
            return CGPoint(x: top.x + a * (left.x - top.x) + b * (right.x - top.x), y: top.y + a * h + b * h)
        }
        func facet(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, seed: Int) -> Facet {
            let p = CGPoint(x: (a.x + b.x + c.x) / 3, y: (a.y + b.y + c.y) / 3)
            var angle = atan2(p.x - center.x, -(p.y - center.y))
            if angle < 0 { angle += 2 * .pi }
            return Facet(
                a: a, b: b, c: c, segment: Int(angle / (2 * .pi) * 6) % 6,
                reflection: Double((seed * 37 + 17) % 11) / 10)
        }
        var facets: [Facet] = []
        facets.reserveCapacity(rows * rows)
        for i in 0..<rows {
            for j in 0..<(rows - i) {
                facets.append(facet(point(i, j), point(i + 1, j), point(i, j + 1), seed: i * 31 + j))
                if i + j < rows - 1 { facets.append(facet(point(i + 1, j), point(i, j + 1), point(i + 1, j + 1), seed: i * 17 + j + 100)) }
            }
        }
        let spokes: [(CGPoint, CGPoint)] =
            large
            ? [
                (CGPoint(x: 0, y: -0.10), CGPoint(x: 0, y: -0.43)),
                (CGPoint(x: 0.075, y: 0.02), CGPoint(x: 0.32, y: 0.27)),
                (CGPoint(x: -0.075, y: 0.02), CGPoint(x: -0.32, y: 0.27)),
            ] : [(CGPoint(x: 0, y: -0.27), CGPoint(x: 0, y: 0.23))]
        let strips = spokes.map {
            Strip(
                from: CGPoint(x: center.x + $0.0.x * w, y: center.y + $0.0.y * h),
                to: CGPoint(x: center.x + $0.1.x * w, y: center.y + $0.1.y * h))
        }
        return Fixture(
            large: large, center: center, width: w, height: h, top: top, left: left, right: right,
            facets: facets, strips: strips, labelCenter: labelCenter)
    }

    /// Mirror facet colour: the zone's RGB lifted by a small dark floor and scaled by the facet's reflectivity.
    public static func facetColor(_ rgb: LightColor, reflection: Double) -> (r: Double, g: Double, b: Double) {
        let dark = 0.04 + 0.055 * reflection
        let gain = 0.70 + 0.30 * reflection
        return (min(1, dark + rgb.r * gain), min(1, dark + rgb.g * gain), min(1, dark + rgb.b * gain))
    }

    /// Zone colour for a facet; single-zone fixtures (TRI 180) use their only zone everywhere.
    public static func zoneColor(_ rgb: [LightColor], segment: Int) -> LightColor {
        rgb.isEmpty ? .black : rgb[min(segment, rgb.count - 1)]
    }
}
