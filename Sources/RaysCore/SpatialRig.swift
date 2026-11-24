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
    /// How each group takes its light from a classic frame that lacks it (see `fitting`); empty on a
    /// layout with exactly the classic group ids.
    let fills: [Fill]

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
        fills = Self.fills(groups: groups, rgb: self.rgb, cob: self.cob)
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

// MARK: - Frames of the rig (ADR 0005, step 6)

extension SpatialRig {
    /// One emitter of the classic frame: group index and segment or COB index.
    struct Slot: Equatable, Sendable {
        var group: Int
        var index: Int
    }

    /// How a group the classic choreographies do not know is lit.
    enum Fill: Equatable, Sendable {
        /// Resampled from the classic group at this index: role "center", or "side" by x.
        case role(Int)
        /// Every emitter takes the classic emitter nearest to it across the stage.
        case nearest(rgb: [Slot], cob: [Slot])
    }

    /// Fills of a layout other than the classic ids. A group tagged with the centre role follows the centre
    /// light, a side group the left or right light by x; any other group samples the classic emitters by
    /// position, so the built-in choreographies keep moving across the stage on any layout.
    static func fills(groups: [Group], rgb: [StageEmitter], cob: [StageEmitter]) -> [Fill] {
        let classicIDs: [RigGroupID] = [.left, .center, .right]
        guard groups.map(\.id) != classicIDs else { return [] }
        let source = SpatialRig.classic
        func nearest(_ x: Double, in list: [StageEmitter]) -> Slot {
            var best = list[0]
            for e in list where abs(e.x - x) < abs(best.x - x) { best = e }
            return Slot(group: best.group, index: best.index)
        }
        func slots(_ emitters: [StageEmitter], group g: Int, count: Int, source list: [StageEmitter]) -> [Slot] {
            var out = Array(repeating: Slot(group: 0, index: 0), count: count)
            for e in emitters where e.group == g && e.index < count { out[e.index] = nearest(e.x, in: list) }
            return out
        }
        return groups.enumerated().map { g, group in
            if group.roles.contains(TrackTarget.centerRole) { return .role(1) }
            if group.roles.contains(TrackTarget.sideRole) { return .role(group.position.x <= 0.5 ? 0 : 2) }
            return .nearest(
                rgb: slots(rgb, group: g, count: group.rgbCount, source: source.rgb),
                cob: slots(cob, group: g, count: group.cobCount, source: source.cob))
        }
    }

    /// Whether `frame` already has this rig's groups, in order, with their segment and COB counts.
    public func matches(_ frame: RigFrame) -> Bool {
        guard frame.groups.count == groups.count else { return false }
        var i = 0
        while i < groups.count {
            let light = frame.groups[i].light
            if frame.groups[i].id != groups[i].id || light.rgb.count != groups[i].rgbCount || light.cob.count != groups[i].cobCount {
                return false
            }
            i += 1
        }
        return true
    }

    /// `frame` in this rig's shape: one group per rig group, sized like the rig.
    ///
    /// A frame that already has the shape is returned as it is (the classic rig with a classic
    /// choreography frame: nothing is copied). Otherwise a group the frame has is resampled to the rig's
    /// counts (averaged or repeated, as `FixtureLevels.resampled`); a group it lacks is filled from a
    /// classic frame by role or position (see `fills`), and stays black when `frame` is not classic.
    public func fitting(_ frame: RigFrame) -> RigFrame {
        if matches(frame) { return frame }
        let classic = SpatialRig.classic.matches(frame)
        var out = black
        for g in groups.indices {
            let rgbCount = groups[g].rgbCount, cobCount = groups[g].cobCount
            if let j = frame.index(of: groups[g].id) {
                out.groups[g].light = Self.resampled(frame.groups[j].light, rgb: rgbCount, cob: cobCount)
                continue
            }
            guard classic, g < fills.count else { continue }
            switch fills[g] {
            case .role(let j):
                out.groups[g].light = Self.resampled(frame.groups[j].light, rgb: rgbCount, cob: cobCount)
            case .nearest(let rgbSlots, let cobSlots):
                for (k, s) in rgbSlots.enumerated() { out.groups[g].light.rgb[k] = frame.groups[s.group].light.rgb[s.index] }
                for (k, s) in cobSlots.enumerated() { out.groups[g].light.cob[k] = frame.groups[s.group].light.cob[s.index] }
            }
        }
        return out
    }

    private static func resampled(_ light: RoleFrame, rgb: Int, cob: Int) -> RoleFrame {
        if light.rgb.count == rgb && light.cob.count == cob { return light }
        let levels = FixtureLevels(light).resampled(rgbCount: rgb, cobCount: cob)
        return RoleFrame(rgb: levels.rgb, cob: levels.cob)
    }
}
