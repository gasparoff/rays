import Foundation

// Rig layout data model (ADR 0005, step 2): groups of fixtures at free positions on the stage, and the
// drawing appearance of a fixture profile. Pure data: nothing in the 30 Hz path reads it yet, so the
// classic rig renders exactly as before.

/// Stable identifier of a rig group. The classic layout uses "left", "center" and "right"; groups the
/// user creates get unique ids. Stored as a bare JSON string.
public struct RigGroupID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let left = RigGroupID("left")
    public static let center = RigGroupID("center")
    public static let right = RigGroupID("right")

    /// A new unique id for a group the user creates.
    public static func unique() -> RigGroupID { RigGroupID("g-" + UUID().uuidString) }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension FixtureRole {
    /// The classic layout group this role stands for.
    public var groupID: RigGroupID { RigGroupID(rawValue) }

    /// The role of a classic group id; nil for any other group.
    public init?(groupID: RigGroupID) { self.init(rawValue: groupID.rawValue) }
}

/// A point on the stage canvas. Group positions are normalised 0…1 (x: left → right, y: back → front);
/// fixture offsets are relative to their group. Layout data only: it never changes a DMX byte.
public struct StagePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = StagePoint(x: 0, y: 0)

    /// Non-finite coordinates fall back to 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? 0
        let y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? 0
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }

    private enum CodingKeys: String, CodingKey { case x, y }
}

/// How a fixture is drawn in the preview.
public enum FixtureShape: String, Codable, CaseIterable, Sendable {
    case triangle, par, bar, wash, spot, movingHead, strip, blinder, generic

    /// Unknown kinds (e.g. from a newer version) decode as `generic` instead of failing the profile.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FixtureShape(rawValue: raw) ?? .generic
    }
}

/// Order in which a fixture's RGB zones (segments, in channel order) are laid out when drawn.
public enum ZoneLayout: Hashable, Sendable {
    /// Left → right (bars, strips).
    case horizontal
    /// Top → bottom.
    case vertical
    /// Facets around the centre, clockwise from the top (triangles, rings).
    case radial
    /// Rows of `columns` zones, left → right then top → bottom.
    case grid(columns: Int)

    /// Names accepted for the `zones` key of a profile's `visual`.
    public static let names = ["horizontal", "vertical", "radial", "grid"]

    public var name: String {
        switch self {
        case .horizontal: return "horizontal"
        case .vertical: return "vertical"
        case .radial: return "radial"
        case .grid: return "grid"
        }
    }

    /// nil for an unknown name, or a grid without at least one column.
    public init?(name: String, columns: Int? = nil) {
        switch name {
        case "horizontal": self = .horizontal
        case "vertical": self = .vertical
        case "radial": self = .radial
        case "grid":
            guard let columns, columns >= 1 else { return nil }
            self = .grid(columns: columns)
        default: return nil
        }
    }
}

/// Drawing appearance of a fixture profile: the optional `"visual"` key, e.g.
/// `"visual": {"kind": "bar", "zones": "horizontal"}` or `{"kind": "wash", "zones": "grid", "columns": 4}`.
/// Without it the appearance is inferred from the channels (`FixtureProfile.appearance`).
/// Never part of the patch fingerprint and never affects DMX.
public struct FixtureAppearance: Codable, Hashable, Sendable {
    public var kind: FixtureShape
    /// nil: a single zone, or the renderer's default order for the kind.
    public var zones: ZoneLayout?

    public init(kind: FixtureShape, zones: ZoneLayout? = nil) {
        self.kind = kind
        self.zones = zones
    }

    /// Inferred from the channel map: repeated RGB groups are zones in channel order (a bar), a single
    /// RGB group is a PAR, white/blinder channels alone are a blinder; anything else falls back to a PAR.
    public static func inferred(rgbSegments: Int, cobs: Int) -> FixtureAppearance {
        if rgbSegments >= 2 { return FixtureAppearance(kind: .bar, zones: .horizontal) }
        if rgbSegments == 1 { return FixtureAppearance(kind: .par) }
        if cobs >= 2 { return FixtureAppearance(kind: .blinder, zones: .horizontal) }
        if cobs == 1 { return FixtureAppearance(kind: .blinder) }
        return FixtureAppearance(kind: .par)
    }

    /// Tolerant: a missing or unknown kind is `generic`, unknown zones are nil.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(FixtureShape.self, forKey: .kind)) ?? .generic
        let columns = (try? c.decodeIfPresent(Int.self, forKey: .columns)) ?? nil
        zones = ((try? c.decodeIfPresent(String.self, forKey: .zones)) ?? nil).flatMap { ZoneLayout(name: $0, columns: columns) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(zones?.name, forKey: .zones)
        if case .grid(let columns) = zones { try c.encode(columns, forKey: .columns) }
    }

    private enum CodingKeys: String, CodingKey { case kind, zones, columns }
}

extension FixtureProfile {
    /// How the preview draws this profile: the declared `visual`, otherwise inferred from the channels.
    public var appearance: FixtureAppearance {
        visual ?? FixtureAppearance.inferred(rgbSegments: rgbSegmentCount, cobs: cobCount)
    }

    /// The profile as the patch fingerprint sees it: drawing data removed.
    var withoutVisual: FixtureProfile {
        var p = self
        p.visual = nil
        return p
    }
}

/// A named position on the stage holding any number of patched fixtures.
public struct RigGroup: Codable, Equatable, Sendable {
    public var id: RigGroupID
    /// User-given, editable.
    public var name: String
    /// Colour of the group's label and selection in the UI.
    public var labelColor: SceneRGB
    /// Drawing default for placeholders; real fixtures are drawn from their profile.
    public var shape: FixtureShape?
    /// Free position on the stage canvas, normalised 0…1.
    public var position: StagePoint
    /// Drawing hints only (degrees, factor); never affect DMX.
    public var rotation: Double
    public var scale: Double
    /// Tags scenes can target ("center", "side", "accent"…).
    public var roles: Set<String>
    /// Per-group intensity master 0…1.
    public var master: Double

    public init(
        id: RigGroupID, name: String, labelColor: SceneRGB = SceneRGB(r: 1, g: 1, b: 1), shape: FixtureShape? = nil,
        position: StagePoint = StagePoint(x: 0.5, y: 0.5), rotation: Double = 0, scale: Double = 1,
        roles: Set<String> = [], master: Double = 1
    ) {
        self.id = id; self.name = name; self.labelColor = labelColor; self.shape = shape
        self.position = position; self.rotation = rotation; self.scale = scale
        self.roles = roles; self.master = master
    }

    /// Tolerant: only `id` is required; anything missing, unknown or non-finite falls back to the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(RigGroupID.self, forKey: .id)
        let d = RigGroup(id: id, name: id.rawValue)
        func number(_ key: CodingKeys, _ fallback: Double) -> Double {
            let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
            return v.isFinite ? v : fallback
        }
        self.id = id
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? d.name
        labelColor = ((try? c.decodeIfPresent(SceneRGB.self, forKey: .labelColor)) ?? nil)?.clamped ?? d.labelColor
        shape = (try? c.decodeIfPresent(FixtureShape.self, forKey: .shape)) ?? nil
        position = (try? c.decodeIfPresent(StagePoint.self, forKey: .position)) ?? d.position
        rotation = number(.rotation, d.rotation)
        scale = number(.scale, d.scale)
        roles = Set((try? c.decodeIfPresent([String].self, forKey: .roles)) ?? [])
        master = min(1, max(0, number(.master, d.master)))
    }

    /// Roles are written sorted so saved files are stable.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(labelColor, forKey: .labelColor)
        try c.encodeIfPresent(shape, forKey: .shape)
        try c.encode(position, forKey: .position)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(scale, forKey: .scale)
        try c.encode(roles.sorted(), forKey: .roles)
        try c.encode(master, forKey: .master)
    }

    private enum CodingKeys: String, CodingKey { case id, name, labelColor, shape, position, rotation, scale, roles, master }
}

/// The ordered groups of a rig. `Patch.layout` nil means `.classic`.
public struct RigLayout: Codable, Equatable, Sendable {
    public var groups: [RigGroup]

    public init(groups: [RigGroup]) { self.groups = groups }

    /// Today's three positions: left (0, 0.5), center (0.5, 0.5), right (1, 0.5), drawn as triangles.
    public static let classic = RigLayout(groups: [
        RigGroup(
            id: .left, name: FixtureRole.left.label, labelColor: SceneRGB(r: 0.35, g: 0.65, b: 1), shape: .triangle,
            position: StagePoint(x: 0, y: 0.5), roles: ["side"]),
        RigGroup(
            id: .center, name: FixtureRole.center.label, labelColor: SceneRGB(r: 1, g: 0.7, b: 0.25), shape: .triangle,
            position: StagePoint(x: 0.5, y: 0.5), roles: ["center"]),
        RigGroup(
            id: .right, name: FixtureRole.right.label, labelColor: SceneRGB(r: 1, g: 0.35, b: 0.55), shape: .triangle,
            position: StagePoint(x: 1, y: 0.5), roles: ["side"]),
    ])

    /// True when the layout has exactly the classic group ids in the classic order (names, colours and
    /// positions may have been edited).
    public var isClassic: Bool { groups.map(\.id) == RigLayout.classic.groups.map(\.id) }

    public func group(_ id: RigGroupID) -> RigGroup? { groups.first { $0.id == id } }

    /// Tolerant: a missing list is empty; groups that fail to decode are skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([Lenient<RigGroup>].self, forKey: .groups)) ?? nil
        groups = raw?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case groups }
}

/// Decodes an element without failing the surrounding array.
private struct Lenient<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension Patch {
    /// The layout to use: the stored one, or the classic three positions for patches saved without one.
    public var resolvedLayout: RigLayout { layout ?? .classic }

    /// Group of every fixture: its explicit group, otherwise the classic group of its role
    /// (explicit or guessed by `roles(library:)`).
    public func groupIDs(library base: ProfileLibrary) -> [RigGroupID] {
        zip(fixtures, roles(library: base)).map { fixture, role in fixture.group ?? role.groupID }
    }
}
