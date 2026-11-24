import Foundation

/// Light for one rig group in a `RigFrame`: the group's id and the frame its fixtures show.
public struct GroupFrame: Equatable, Sendable {
    public var id: RigGroupID
    public var light: RoleFrame

    public init(id: RigGroupID, light: RoleFrame) {
        self.id = id
        self.light = light
    }
}

/// One choreography frame for the whole rig, one `GroupFrame` per rig group in layout order (ADR 0005).
///
/// The classic layout is `left`, `center`, `right`: centre TRI 380 (6 RGB segments + 3 COBs) and the
/// two side TRI 180 (1 RGB group + 1 COB each). `left/center/right` and the `FixtureRole` subscript
/// read and write that storage in place, so the 30 Hz path keeps mutating preallocated arrays.
///
/// Centre geometry (unverified on hardware, fixed only through the profile's segment order):
/// segments 0,1 = right edge top→bottom, 2,3 = bottom edge right→left, 4,5 = left edge
/// bottom→top; COB k sits on the spoke towards the vertex where edge k starts (top, bottom-right,
/// bottom-left), so 0→1→2 is clockwise.
public struct RigFrame: Equatable, Sendable {
    public static let centerSegments = 6, centerCOBs = 3

    /// Groups in layout order. Lookup by id is a linear scan (layouts hold a handful of groups);
    /// with duplicate ids the first one wins.
    public var groups: [GroupFrame]

    public init(groups: [GroupFrame]) { self.groups = groups }

    /// The classic three-group frame.
    public init(left: RoleFrame, center: RoleFrame, right: RoleFrame) {
        groups = [
            GroupFrame(id: .left, light: left),
            GroupFrame(id: .center, light: center),
            GroupFrame(id: .right, light: right),
        ]
    }

    public static let black = RigFrame(
        left: .black(rgb: 1, cob: 1),
        center: .black(rgb: centerSegments, cob: centerCOBs),
        right: .black(rgb: 1, cob: 1))

    /// Index of the group `id`, or nil when the frame has no such group.
    public func index(of id: RigGroupID) -> Int? {
        var i = 0
        while i < groups.count {
            if groups[i].id == id { return i }
            i += 1
        }
        return nil
    }

    /// The light of group `id`; nil when the frame has no such group. Setting a new id appends a
    /// group, setting nil removes it.
    public subscript(group id: RigGroupID) -> RoleFrame? {
        get { index(of: id).map { groups[$0].light } }
        set {
            switch (index(of: id), newValue) {
            case (let i?, let light?): groups[i].light = light
            case (let i?, nil): groups.remove(at: i)
            case (nil, let light?): groups.append(GroupFrame(id: id, light: light))
            case (nil, nil): break
            }
        }
    }

    public var left: RoleFrame {
        _read { yield light(at: slot(.left, hint: 0)) }
        _modify { yield &self[classic: .left, hint: 0] }
    }

    public var center: RoleFrame {
        _read { yield light(at: slot(.center, hint: 1)) }
        _modify { yield &self[classic: .center, hint: 1] }
    }

    public var right: RoleFrame {
        _read { yield light(at: slot(.right, hint: 2)) }
        _modify { yield &self[classic: .right, hint: 2] }
    }

    /// Compatibility access by classic role. A frame without that group reads as an empty
    /// `RoleFrame` and ignores writes, so code still written for three roles never crashes.
    public subscript(role: FixtureRole) -> RoleFrame {
        _read {
            switch role {
            case .left: yield left
            case .center: yield center
            case .right: yield right
            }
        }
        _modify {
            switch role {
            case .left: yield &left
            case .center: yield &center
            case .right: yield &right
            }
        }
    }

    /// Mixes each group with the group of the same id in `o`; a group `o` lacks is kept as it is.
    /// The result has this frame's groups, in this frame's order.
    public func mixed(with o: RigFrame, _ t: Double) -> RigFrame {
        var out = self
        for i in out.groups.indices {
            let id = out.groups[i].id
            let j: Int? = i < o.groups.count && o.groups[i].id == id ? i : o.index(of: id)
            if let j { out.groups[i].light = out.groups[i].light.mixed(with: o.groups[j].light, t) }
        }
        return out
    }

    public func scaled(_ k: Double) -> RigFrame {
        var out = self
        for i in out.groups.indices { out.groups[i].light = out.groups[i].light.scaled(k) }
        return out
    }

    public var isFinite: Bool { groups.allSatisfy(\.light.isFinite) }

    /// Replaces anything non-finite with black and clamps to 0...1. A non-finite classic frame becomes
    /// `.black`; any other layout keeps its groups and sizes, all black.
    public var sanitized: RigFrame {
        guard isFinite else {
            if groups.map(\.id) == [.left, .center, .right] { return .black }
            return RigFrame(
                groups: groups.map { GroupFrame(id: $0.id, light: .black(rgb: $0.light.rgb.count, cob: $0.light.cob.count)) })
        }
        return scaled(1)
    }

    // MARK: - Storage lookup

    private static let missing = RoleFrame(rgb: [], cob: [])

    /// Index of `id`, checking the classic position `hint` first so the classic frame never scans.
    @inline(__always)
    private func slot(_ id: RigGroupID, hint: Int) -> Int? {
        if hint < groups.count, groups[hint].id == id { return hint }
        return index(of: id)
    }

    private func light(at i: Int?) -> RoleFrame {
        guard let i else { return Self.missing }
        return groups[i].light
    }

    /// In-place access to a classic group; writes to a missing group go to a discarded scratch frame.
    private subscript(classic id: RigGroupID, hint hint: Int) -> RoleFrame {
        get { light(at: slot(id, hint: hint)) }
        _modify {
            if let i = slot(id, hint: hint) {
                yield &groups[i].light
            } else {
                var scratch = Self.missing
                yield &scratch
            }
        }
    }
}
