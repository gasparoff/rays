import CoreGraphics
import Foundation

/// How the preview draws one fixture: its profile's appearance plus the zone and white-emitter counts
/// that the DMX snapshot fills. Built from `FixtureProfile.appearance`, never re-inferred here.
public struct StageFixtureSpec: Equatable, Sendable {
    public var appearance: FixtureAppearance
    /// RGB zones in channel order (`FixtureVisual.rgb`).
    public var zones: Int
    /// White / COB emitters in channel order (`FixtureVisual.cob`).
    public var cobs: Int
    /// Triangles only: the TRI 380 mirror (larger, three COB spokes) instead of the TRI 180.
    public var large: Bool
    /// Position on the stage canvas (`FixtureVisual.position`); nil keeps the classic row.
    public var position: StagePoint?

    public init(appearance: FixtureAppearance, zones: Int, cobs: Int, large: Bool = false, position: StagePoint? = nil) {
        self.appearance = appearance
        self.zones = max(0, zones)
        self.cobs = max(0, cobs)
        self.large = large
        self.position = position
    }

    public init(profile: FixtureProfile) {
        self.init(
            appearance: profile.appearance, zones: profile.rgbSegmentCount, cobs: profile.cobCount,
            large: StageLayout.isLarge(profileID: profile.id))
    }

    /// The Varytec mirrors as earlier versions drew them: TRI 380 (six zones, three COBs) or TRI 180.
    public static func triangle(large: Bool) -> StageFixtureSpec {
        StageFixtureSpec(appearance: VarytecRig.triangle, zones: large ? 6 : 1, cobs: large ? 3 : 1, large: large)
    }

    /// A light whose profile is unknown: a generic lamp with as many zones as the snapshot carries.
    public static func unknown(zones: Int, cobs: Int) -> StageFixtureSpec {
        StageFixtureSpec(appearance: FixtureAppearance(kind: .generic), zones: zones, cobs: cobs)
    }
}

/// Geometry of the stage preview, computed once per view size and fixture models instead of on every
/// 30 Hz frame. Every fixture is drawn the way it looks: faceted triangular mirrors with COB spokes, PARs
/// with their LED array, bars and strips with their pixels, LED panels, moving heads on their yoke,
/// blinder cells. Each RGB zone is coloured from the DMX snapshot in the order the profile declares.
/// Coordinates are top-left origin, y down. Pure numbers so the renderer and the tests share one source of truth.
public struct StageLayout: Equatable, Sendable {
    /// One coloured element: a mirror facet, an LED, a pixel or a blinder cell.
    public struct Facet: Equatable, Sendable {
        /// Closed polygon (three points for mirror facets).
        public var points: [CGPoint]
        /// RGB zone, in the profile's channel order (clamped to the fixture's zone count when drawn).
        public var segment: Int
        /// White emitter mixed into this element (RGBW LEDs, blinder cells); nil when it has none.
        public var cob: Int?
        /// Deterministic reflectivity 0…1 (seeded by the element position).
        public var reflection: Double

        public var a: CGPoint { points[0] }
        public var b: CGPoint { points[1] }
        public var c: CGPoint { points[2] }
    }

    /// One linear COB strip.
    public struct Strip: Equatable, Sendable {
        public var from: CGPoint, to: CGPoint
    }

    /// Geometry of one fixture in the preview.
    public struct Fixture: Equatable, Sendable {
        public var kind: FixtureShape
        public var large: Bool
        public var center: CGPoint
        public var width: CGFloat
        public var height: CGFloat
        /// Triangle corners for the mirrors; for other kinds the top centre and bottom corners of the body.
        public var top: CGPoint, left: CGPoint, right: CGPoint
        /// The lit body: mirror frame, lens housing, bar or panel. Selection outlines it.
        public var outline: [CGPoint]
        /// Dark mechanical parts drawn behind the body (moving head yoke and base, PAR bracket).
        public var hardware: [[CGPoint]]
        public var facets: [Facet]
        /// Warm COB strips in DMX order (triangles: TRI 380 three, TRI 180 one).
        public var strips: [Strip]
        public var labelCenter: CGPoint
        /// Gaussian radius of the coloured halo behind the body.
        public var faceGlowRadius: CGFloat { max(width, height) * 0.09 }
        public var stripWidth: CGFloat { max(3, width * 0.035) }
        public var stripGlowWidth: CGFloat { width * 0.09 }
        public var stripCoreWidth: CGFloat { max(1, width * 0.012) }
    }

    public static let stripGlowRadius: CGFloat = 5

    public var size: CGSize
    public var specs: [StageFixtureSpec]
    public var floor: CGFloat
    public var fixtures: [Fixture]

    /// Size class of the Varytec mirrors, which share one appearance: the TRI 380 is drawn larger.
    public static func isLarge(profileID: String?) -> Bool { profileID?.contains("tri380") == true }

    /// Index of the fixture under `point` (view coordinates), for clicking a light in the preview.
    /// The body and its mechanical parts count, plus a margin of `slop` points around them and the label so
    /// small fixtures stay easy to hit. When two overlap, the nearest centre wins.
    public func fixtureIndex(at point: CGPoint, slop: CGFloat = 8) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, fixture) in fixtures.enumerated() {
            let onBody = ([fixture.outline] + fixture.hardware).contains { Self.distance(point, toPolygon: $0) <= slop }
            let onLabel =
                abs(point.x - fixture.labelCenter.x) <= max(fixture.width, 40) / 2 && abs(point.y - fixture.labelCenter.y) <= 10 + slop
            guard onBody || onLabel else { continue }
            let d = hypot(point.x - fixture.center.x, point.y - fixture.center.y)
            if best.map({ d < $0.distance }) ?? true { best = (index, d) }
        }
        return best?.index
    }

    /// 0 inside the triangle, otherwise the distance to its nearest edge.
    static func distance(_ p: CGPoint, toTriangle a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        distance(p, toPolygon: [a, b, c])
    }

    /// 0 inside the closed polygon (even-odd rule), otherwise the distance to its nearest edge.
    static func distance(_ p: CGPoint, toPolygon points: [CGPoint]) -> CGFloat {
        guard !points.isEmpty else { return .infinity }
        var inside = false
        var nearest = CGFloat.infinity
        var j = points.count - 1
        for i in points.indices {
            let u = points[j], v = points[i]
            if (v.y > p.y) != (u.y > p.y), p.x < (u.x - v.x) * (p.y - v.y) / (u.y - v.y) + v.x { inside.toggle() }
            let dx = v.x - u.x, dy = v.y - u.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? min(1, max(0, ((p.x - u.x) * dx + (p.y - u.y) * dy) / length)) : 0
            nearest = min(nearest, hypot(p.x - (u.x + t * dx), p.y - (u.y + t * dy)))
            j = i
        }
        return inside ? 0 : nearest
    }

    /// One fixture per spec, left to right on a common floor, each in its own slot of the width.
    ///
    /// When every spec has a `position`, fixtures stand at their stage positions instead: x spans the
    /// row's extent (first to last slot centre) from the leftmost to the rightmost position, and y moves
    /// the floor line up for the back of the stage (y 0) and down for the front (y 1), around the row's floor.
    public init(size: CGSize, specs: [StageFixtureSpec]) {
        self.size = size
        self.specs = specs
        let count = max(specs.count, 1)
        floor = size.height * 0.79
        let floor = self.floor
        let slot = min(size.width / CGFloat(count) * 0.82, size.height * 0.79)
        let points = specs.compactMap(\.position)
        let placed = !specs.isEmpty && points.count == specs.count
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let margin = 1 / CGFloat(count * 2)
        fixtures = specs.enumerated().map { index, spec in
            guard placed, let p = spec.position else {
                let x = size.width * CGFloat(index * 2 + 1) / CGFloat(count * 2)
                return StageLayout.fixture(spec, x: x, floor: floor, slot: slot, maxHeight: size.height * 0.72)
            }
            let t = maxX - minX > 1e-9 && p.x.isFinite ? CGFloat((p.x - minX) / (maxX - minX)) : 0.5
            let depth = p.y.isFinite ? CGFloat(min(1, max(0, p.y))) : 0.5
            let x = size.width * (margin + t * (1 - 2 * margin))
            let line = floor + (depth - 0.5) * size.height * 0.16
            return StageLayout.fixture(spec, x: x, floor: line, slot: slot, maxHeight: size.height * 0.72)
        }
    }

    /// The classic row of Varytec mirrors (`true`: TRI 380).
    public init(size: CGSize, large: [Bool]) {
        self.init(size: size, specs: large.map(StageFixtureSpec.triangle(large:)))
    }

    public var large: [Bool] { fixtures.map(\.large) }

    // MARK: Zones

    /// Default zone order of a kind when the profile declares none.
    static func defaultZones(_ kind: FixtureShape, zones: Int) -> ZoneLayout {
        switch kind {
        case .bar, .strip, .blinder: return .horizontal
        case .wash: return .grid(columns: max(1, Int(Double(zones).squareRoot().rounded(.up))))
        case .triangle, .par, .spot, .movingHead, .generic: return .radial
        }
    }

    /// Zone 0..<zones of a point of the body: by x, by y, by angle clockwise from the top, or by grid cell.
    /// `unit` is the point's position inside the body's box (0…1 on both axes).
    static func zone(at unit: CGPoint, of zones: Int, _ order: ZoneLayout) -> Int {
        guard zones > 1 else { return 0 }
        func cell(_ t: CGFloat, _ n: Int) -> Int { min(n - 1, max(0, Int(t * CGFloat(n)))) }
        switch order {
        case .horizontal: return cell(unit.x, zones)
        case .vertical: return cell(unit.y, zones)
        case .radial:
            var angle = atan2(unit.x - 0.5, -(unit.y - 0.5))
            if angle < 0 { angle += 2 * .pi }
            return Int(angle / (2 * .pi) * CGFloat(zones)) % zones
        case .grid(let columns):
            let columns = min(max(1, columns), zones)
            let rows = (zones + columns - 1) / columns
            return min(zones - 1, cell(unit.y, rows) * columns + cell(unit.x, columns))
        }
    }

    /// White emitter mixed into element `element` of zone `segment`: one per zone when the counts match,
    /// spread evenly over the zones when there are fewer whites, and over the elements when there are more.
    static func cob(forZone segment: Int, element: Int, zones: Int, cobs: Int) -> Int? {
        guard cobs > 0 else { return nil }
        if cobs > max(zones, 1) { return element % cobs }
        return min(cobs - 1, segment * cobs / max(zones, 1))
    }

    // MARK: Shapes

    private static func reflection(_ seed: Int) -> Double { Double((seed * 37 + 17) % 11) / 10 }

    static func circle(_ c: CGPoint, _ r: CGFloat, sides: Int = 24) -> [CGPoint] {
        (0..<sides).map { i in
            let a = CGFloat(i) / CGFloat(sides) * 2 * .pi
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
    }

    static func rect(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    private static func fixture(_ spec: StageFixtureSpec, x: CGFloat, floor: CGFloat, slot: CGFloat, maxHeight: CGFloat) -> Fixture {
        let kind = spec.appearance.kind
        let order = spec.appearance.zones ?? defaultZones(kind, zones: spec.zones)
        let labelCenter = CGPoint(x: x, y: floor + 23)
        if kind == .triangle {
            let width = slot * (spec.large ? 1 : 0.65)
            let height = width * 0.866
            return triangle(
                spec, order: order, center: CGPoint(x: x, y: floor - height * 0.4), width: width, height: height,
                labelCenter: labelCenter)
        }
        // Natural proportions of each kind, scaled down when the stage is too low.
        var (width, height): (CGFloat, CGFloat)
        switch kind {
        case .par: (width, height) = (slot * 0.5, slot * 0.5 * 1.12)
        case .spot, .movingHead: (width, height) = (slot * 0.5, slot * 0.5 * 1.3)
        case .bar: (width, height) = (slot * 0.95, max(10, slot * 0.95 * 0.13))
        case .strip: (width, height) = (slot * 0.95, max(7, slot * 0.95 * 0.055))
        case .wash: (width, height) = (slot * 0.62, slot * 0.62 * 0.72)
        case .blinder:
            let cells = max(1, spec.cobs), columns = min(cells, 4), rows = (cells + columns - 1) / columns
            let cell = slot * 0.95 / CGFloat(max(columns, 2))
            (width, height) = (cell * CGFloat(columns), cell * CGFloat(rows))
        case .triangle, .generic: (width, height) = (slot * 0.42, slot * 0.42)
        }
        if height > maxHeight {
            width *= maxHeight / height
            height = maxHeight
        }
        let box = CGRect(x: x - width / 2, y: floor - height, width: width, height: height)
        let parts = body(kind, spec: spec, order: order, box: box)
        return Fixture(
            kind: kind, large: false, center: CGPoint(x: box.midX, y: box.midY), width: width, height: height,
            top: CGPoint(x: box.midX, y: box.minY), left: CGPoint(x: box.minX, y: box.maxY), right: CGPoint(x: box.maxX, y: box.maxY),
            outline: parts.outline, hardware: parts.hardware, facets: parts.facets, strips: [], labelCenter: labelCenter)
    }

    /// LEDs on a hexagonal pattern filling a disc, centre first.
    private static func ledDisc(
        _ c: CGPoint, radius: CGFloat, rings: Int, spec: StageFixtureSpec, order: ZoneLayout, seed: Int
    ) -> [Facet] {
        let pitch = radius / (CGFloat(rings) + 0.5)
        let dot = pitch * 0.4
        var facets: [Facet] = []
        for ring in 0...rings {
            let count = ring == 0 ? 1 : ring * 6
            for i in 0..<count {
                let angle = CGFloat(i) / CGFloat(count) * 2 * .pi - .pi / 2
                let p = CGPoint(x: c.x + CGFloat(ring) * pitch * cos(angle), y: c.y + CGFloat(ring) * pitch * sin(angle))
                let unit = CGPoint(x: (p.x - c.x) / (2 * radius) + 0.5, y: (p.y - c.y) / (2 * radius) + 0.5)
                let segment = zone(at: unit, of: spec.zones, order)
                facets.append(
                    Facet(
                        points: circle(p, dot, sides: 12), segment: segment,
                        cob: cob(forZone: segment, element: facets.count, zones: spec.zones, cobs: spec.cobs),
                        reflection: reflection(seed + ring * 13 + i)))
            }
        }
        return facets
    }

    /// Rectangular grid of LEDs or pixels inside `area`.
    private static func ledGrid(
        _ area: CGRect, columns: Int, rows: Int, square: Bool, spec: StageFixtureSpec, order: ZoneLayout
    ) -> [Facet] {
        let pitchX = area.width / CGFloat(columns), pitchY = area.height / CGFloat(rows)
        var facets: [Facet] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let p = CGPoint(x: area.minX + (CGFloat(column) + 0.5) * pitchX, y: area.minY + (CGFloat(row) + 0.5) * pitchY)
                let unit = CGPoint(x: (CGFloat(column) + 0.5) / CGFloat(columns), y: (CGFloat(row) + 0.5) / CGFloat(rows))
                let segment = zone(at: unit, of: spec.zones, order)
                let size = min(pitchX, pitchY)
                let points =
                    square
                    ? rect(CGRect(x: p.x - pitchX * 0.42, y: p.y - pitchY * 0.38, width: pitchX * 0.84, height: pitchY * 0.76))
                    : circle(p, size * 0.36, sides: 12)
                facets.append(
                    Facet(
                        points: points, segment: segment,
                        cob: cob(forZone: segment, element: facets.count, zones: spec.zones, cobs: spec.cobs),
                        reflection: reflection(row * 29 + column)))
            }
        }
        return facets
    }

    private static func body(
        _ kind: FixtureShape, spec: StageFixtureSpec, order: ZoneLayout, box: CGRect
    ) -> (outline: [CGPoint], hardware: [[CGPoint]], facets: [Facet]) {
        let w = box.width, h = box.height
        switch kind {
        case .par:
            // Round can with its LED array, hanging from a bracket.
            let r = w / 2
            let c = CGPoint(x: box.midX, y: box.maxY - r)
            let bracket = [
                CGPoint(x: c.x - r * 1.08, y: c.y), CGPoint(x: c.x - r * 1.08, y: box.minY), CGPoint(x: c.x + r * 1.08, y: box.minY),
                CGPoint(x: c.x + r * 1.08, y: c.y), CGPoint(x: c.x + r * 0.98, y: c.y), CGPoint(x: c.x + r * 0.98, y: box.minY + h * 0.05),
                CGPoint(x: c.x - r * 0.98, y: box.minY + h * 0.05), CGPoint(x: c.x - r * 0.98, y: c.y),
            ]
            return (circle(c, r, sides: 40), [bracket], ledDisc(c, radius: r * 0.8, rings: 3, spec: spec, order: order, seed: 0))
        case .spot, .movingHead:
            // Head on a yoke over its base; a spot has one lens, a moving head an LED array.
            let r = w * 0.36
            let c = CGPoint(x: box.midX, y: box.minY + r + h * 0.02)
            let base = rect(CGRect(x: box.midX - w * 0.38, y: box.maxY - h * 0.16, width: w * 0.76, height: h * 0.16))
            let armTop = c.y, armBottom = box.maxY - h * 0.16
            let left = rect(CGRect(x: c.x - r - w * 0.1, y: armTop, width: w * 0.08, height: armBottom - armTop))
            let right = rect(CGRect(x: c.x + r + w * 0.02, y: armTop, width: w * 0.08, height: armBottom - armTop))
            let foot = rect(CGRect(x: c.x - r - w * 0.1, y: armBottom - w * 0.06, width: 2 * r + w * 0.2, height: w * 0.06))
            let facets =
                kind == .spot
                ? [
                    Facet(
                        points: circle(c, r * 0.62, sides: 32), segment: 0,
                        cob: cob(forZone: 0, element: 0, zones: spec.zones, cobs: spec.cobs),
                        reflection: 0.8)
                ]
                : ledDisc(c, radius: r * 0.82, rings: 2, spec: spec, order: order, seed: 7)
            return (circle(c, r, sides: 40), [base, left, right, foot], facets)
        case .bar, .strip:
            let inset = h * (kind == .bar ? 0.2 : 0.18)
            let area = box.insetBy(dx: inset, dy: inset)
            let pixels = max(spec.zones, 1)
            let perZone = max(1, Int((CGFloat(kind == .bar ? 12 : 32) / CGFloat(pixels)).rounded(.up)))
            let count = min(pixels * perZone, Int(area.width / max(2, area.height * 0.7)) / pixels * pixels)
            let columns = max(pixels, count)
            return (rect(box), [], ledGrid(area, columns: columns, rows: 1, square: kind == .strip, spec: spec, order: order))
        case .wash:
            let area = box.insetBy(dx: w * 0.07, dy: h * 0.09)
            return (rect(box), [], ledGrid(area, columns: 8, rows: 6, square: false, spec: spec, order: order))
        case .blinder:
            // Round COB cells in a panel, coloured by their own white emitter (and RGB zones if any).
            let cells = max(1, spec.cobs), columns = min(cells, 4)
            let pitch = w / CGFloat(columns)
            var facets: [Facet] = []
            for i in 0..<cells {
                let p = CGPoint(x: box.minX + (CGFloat(i % columns) + 0.5) * pitch, y: box.minY + (CGFloat(i / columns) + 0.5) * pitch)
                let unit = CGPoint(x: (p.x - box.minX) / w, y: (p.y - box.minY) / h)
                facets.append(
                    Facet(
                        points: circle(p, pitch * 0.36, sides: 28), segment: zone(at: unit, of: spec.zones, order),
                        cob: spec.cobs > 0 ? i : nil, reflection: reflection(i)))
            }
            let cups = facets.map { circle(StageLayout.centroid($0.points), pitch * 0.45, sides: 28) }
            return (rect(box), cups, facets)
        case .triangle, .generic:
            let r = w * 0.32
            let c = CGPoint(x: box.midX, y: box.midY)
            return (
                rect(box), [],
                [
                    Facet(
                        points: circle(c, r, sides: 32), segment: 0, cob: cob(forZone: 0, element: 0, zones: spec.zones, cobs: spec.cobs),
                        reflection: 0.6)
                ]
            )
        }
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Faceted triangular mirror with its RGB zones around the centre and its COB spokes.
    private static func triangle(
        _ spec: StageFixtureSpec, order: ZoneLayout, center: CGPoint, width w: CGFloat, height h: CGFloat, labelCenter: CGPoint
    ) -> Fixture {
        let large = spec.large
        let top = CGPoint(x: center.x, y: center.y - h * 0.6)
        let left = CGPoint(x: center.x - w / 2, y: center.y + h * 0.4)
        let right = CGPoint(x: center.x + w / 2, y: center.y + h * 0.4)
        let rows = large ? 10 : 7
        // Radial zones turn around the mirror centre, as the six TRI 380 segments do.
        let zones = max(1, spec.zones)
        func point(_ u: Int, _ v: Int) -> CGPoint {
            let a = CGFloat(u) / CGFloat(rows), b = CGFloat(v) / CGFloat(rows)
            return CGPoint(x: top.x + a * (left.x - top.x) + b * (right.x - top.x), y: top.y + a * h + b * h)
        }
        func facet(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, seed: Int) -> Facet {
            let p = CGPoint(x: (a.x + b.x + c.x) / 3, y: (a.y + b.y + c.y) / 3)
            let segment: Int
            if case .radial = order {
                // Angle around the mirror centre (not the box centre).
                var angle = atan2(p.x - center.x, -(p.y - center.y))
                if angle < 0 { angle += 2 * .pi }
                segment = Int(angle / (2 * .pi) * CGFloat(zones)) % zones
            } else {
                segment = zone(at: CGPoint(x: (p.x - left.x) / w, y: (p.y - top.y) / h), of: zones, order)
            }
            return Facet(points: [a, b, c], segment: segment, cob: nil, reflection: reflection(seed))
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
            kind: .triangle, large: large, center: center, width: w, height: h, top: top, left: left, right: right,
            outline: [top, left, right], hardware: [], facets: facets, strips: strips, labelCenter: labelCenter)
    }

    /// Mirror facet colour: the zone's RGB lifted by a small dark floor and scaled by the facet's reflectivity.
    public static func facetColor(_ rgb: LightColor, reflection: Double) -> (r: Double, g: Double, b: Double) {
        let dark = 0.04 + 0.055 * reflection
        let gain = 0.70 + 0.30 * reflection
        return (min(1, dark + rgb.r * gain), min(1, dark + rgb.g * gain), min(1, dark + rgb.b * gain))
    }

    /// Warm white of a COB or the W of an RGBW LED, added to the element's RGB.
    public static let warmWhite = LightColor(1, 0.78, 0.5)

    /// Colour of one element: its zone's RGB plus its white emitter, shaded by its reflectivity.
    public static func elementColor(_ facet: Facet, rgb: [LightColor], cob: [Double]) -> (r: Double, g: Double, b: Double) {
        let base = zoneColor(rgb, segment: facet.segment)
        let white = facet.cob.map { $0 < cob.count ? cob[$0] : 0 } ?? 0
        let lit = LightColor(
            min(1, base.r + white * warmWhite.r), min(1, base.g + white * warmWhite.g), min(1, base.b + white * warmWhite.b))
        return facetColor(lit, reflection: facet.reflection)
    }

    /// Zone colour for a facet; single-zone fixtures (TRI 180) use their only zone everywhere.
    public static func zoneColor(_ rgb: [LightColor], segment: Int) -> LightColor {
        rgb.isEmpty ? .black : rgb[min(segment, rgb.count - 1)]
    }
}
