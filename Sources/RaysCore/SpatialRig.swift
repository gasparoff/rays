import Foundation

// Spatial targets (ADR 0005, step 4): where every light emitter of a rig sits across the stage,
// computed once per layout from the group positions. Program tracks rank, chase and split their
// emitters by these coordinates; on the classic layout they equal the former fixed tables exactly.

/// One light emitter of a rig: an RGB segment or a COB of a group.
public struct StageEmitter: Equatable, Sendable {
    /// Index of the group in `SpatialRig.groups`, which is also its index in the rig's frames.
    public var group: Int
    public var cob: Bool
    /// Segment or COB index in the group's `RoleFrame`.
    public var index: Int
    /// Position across the stage, left → right, on the layout's x scale.
    public var x: Double

    public init(group: Int, cob: Bool, index: Int, x: Double) {
        self.group = group
        self.cob = cob
        self.index = index
        self.x = x
    }
}

/// The emitters of a rig layout ordered across the stage. Built once per layout or patch change, never
/// on the 30 Hz path.
///
/// A group with one RGB segment (or one COB) puts it at the group's x. A group with more spreads them
/// evenly over the open interval `x ± h`, where `h` is the distance to the nearest group at another x
/// (half that distance when the neighbour spreads its own emitters too, so two bars never interleave;
/// 0.5 when the group is alone). Segments run left → right in channel order. A triangle with 6
/// segments and 3 COBs follows the TRI 380 geometry instead (see `RigFrame`): segments along the U path
/// 5,4 (left edge), 3,2 (bottom), 1,0 (right edge), COB 2 bottom-left, 0 on the top spoke, 1 bottom-right.
/// On `RigLayout.classic` this yields L 0, centre segments 1/7…6/7, R 1 and COBs 0, 2/7, 1/2, 5/7, 1.
public struct SpatialRig: Equatable, Sendable {
    /// What a target needs to know about a group.
    public struct Group: Equatable, Sendable {
        public var id: RigGroupID
        public var roles: Set<String>
        public var position: StagePoint
        public var rgbCount: Int
        public var cobCount: Int
    }

    /// Layout groups in layout order (a repeated id keeps only its first group).
    public let groups: [Group]
    /// RGB emitters left → right; equal x keeps layout order, then segment order.
    public let rgb: [StageEmitter]
    /// COB emitters left → right, same ordering.
    public let cob: [StageEmitter]
    /// An all-black frame with one group per layout group, sized like the rig.
    public let black: RigFrame
    /// Rank of each group along x (groups within 1e-6 share a rank).
    public let xRank: [Int]
    /// Number of distinct group x positions.
    public let xPositions: Int

    /// The reference rig: classic layout, centre TRI 380 (6 + 3), side TRI 180 (1 + 1).
    public static let classic = SpatialRig(layout: .classic, sizes: .black)

    /// Positions equal within this distance count as the same place.
    static let tolerance = 1e-6

    /// - Parameters:
    ///   - layout: group ids, positions, shapes and roles.
    ///   - sizes: a frame giving each group's segment and COB counts by id; a group it lacks has none.
    public init(layout: RigLayout, sizes: RigFrame) {
        var seen = Set<RigGroupID>()
        let kept = layout.groups.filter { seen.insert($0.id).inserted }
        let groups = kept.map { g -> Group in
            let light = sizes[group: g.id]
            let x = g.position.x.isFinite ? g.position.x : 0
            let y = g.position.y.isFinite ? g.position.y : 0
            return Group(
                id: g.id, roles: g.roles, position: StagePoint(x: x, y: y), rgbCount: light?.rgb.count ?? 0,
                cobCount: light?.cob.count ?? 0)
        }
        self.groups = groups
        black = RigFrame(groups: groups.map { GroupFrame(id: $0.id, light: .black(rgb: $0.rgbCount, cob: $0.cobCount)) })

        let xs = groups.map(\.position.x)
        let spreads = groups.map { max($0.rgbCount, $0.cobCount) > 1 }
        func halfWidth(_ g: Int) -> Double {
            var h = Double.infinity
            for j in groups.indices where j != g {
                let d = abs(xs[j] - xs[g])
                guard d > Self.tolerance else { continue }
                h = min(h, spreads[j] ? d / 2 : d)
            }
            return h.isFinite ? h : 0.5
        }

        // (emitter, order inside its group) before sorting across the stage.
        var rgb: [(StageEmitter, Int)] = []
        var cob: [(StageEmitter, Int)] = []
        for (g, group) in groups.enumerated() {
            let x = xs[g]
            let nr = group.rgbCount, nc = group.cobCount
            let h = spreads[g] ? halfWidth(g) : 0
            // Slot s of n evenly spaced places inside the open interval x ± h.
            func at(_ slot: Double, of n: Int) -> Double { (x - h) + (2 * h) * (slot + 1) / Double(n + 1) }
            let triangle = kept[g].shape == .triangle && nr == RigFrame.centerSegments && nc == RigFrame.centerCOBs
            if triangle {
                for slot in 0..<nr {
                    rgb.append((StageEmitter(group: g, cob: false, index: nr - 1 - slot, x: at(Double(slot), of: nr)), slot))
                }
                for (order, (index, slot)) in [(2, 1.0), (0, 2.5), (1, 4.0)].enumerated() {
                    cob.append((StageEmitter(group: g, cob: true, index: index, x: at(slot, of: nr)), order))
                }
            } else {
                for i in 0..<nr {
                    rgb.append((StageEmitter(group: g, cob: false, index: i, x: nr == 1 ? x : at(Double(i), of: nr)), i))
                }
                for i in 0..<nc {
                    cob.append((StageEmitter(group: g, cob: true, index: i, x: nc == 1 ? x : at(Double(i), of: nc)), i))
                }
            }
        }
        func acrossStage(_ list: [(StageEmitter, Int)]) -> [StageEmitter] {
            list.sorted { a, b in
                if a.0.x != b.0.x { return a.0.x < b.0.x }
                if a.0.group != b.0.group { return a.0.group < b.0.group }
                return a.1 < b.1
            }.map(\.0)
        }
        self.rgb = acrossStage(rgb)
        self.cob = acrossStage(cob)

        var distinct: [Double] = []
        for x in xs.sorted() where !distinct.contains(where: { abs($0 - x) <= Self.tolerance }) { distinct.append(x) }
        xRank = xs.map { x in distinct.firstIndex { abs($0 - x) <= Self.tolerance } ?? 0 }
        xPositions = distinct.count
    }

    /// Which groups a selection reaches, indexed like `groups`.
    public func picks(_ selection: TrackTarget.Selection) -> [Bool] {
        switch selection {
        case .all:
            return groups.map { _ in true }
        case .role(let role):
            return groups.map { $0.roles.contains(role) }
        case .half(.left):
            // The left half of the x ordering; the middle position of an odd count belongs to neither half.
            return xRank.map { $0 < xPositions / 2 }
        case .half(.right):
            return xRank.map { $0 >= (xPositions + 1) / 2 }
        case .groups(let ids):
            return groups.map { ids.contains($0.id) }
        }
    }
}
