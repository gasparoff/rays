import Foundation

// Group masters and direct commands (ADR 0005, step 5). The engine resolves them into arrays by
// group position whenever a fader or a command changes, so the 30 Hz path never looks up a group
// id in a dictionary.

/// Live direct commands on rig groups: colour, flash, solo and mute. Performance state only, never
/// saved in scenes or in show.json.
public struct GroupOverrides: Equatable, Sendable {
    /// Replaces the scene's RGB colour of the group and keeps its intensity shape.
    public var colors: [RigGroupID: LightColor]
    /// Groups held at full while the flash is pressed.
    public var flashing: Set<RigGroupID>
    /// While any group of the layout is soloed, every other group is dark.
    public var soloed: Set<RigGroupID>
    /// Muted groups are dark.
    public var muted: Set<RigGroupID>

    public init(
        colors: [RigGroupID: LightColor] = [:], flashing: Set<RigGroupID> = [], soloed: Set<RigGroupID> = [],
        muted: Set<RigGroupID> = []
    ) {
        self.colors = colors
        self.flashing = flashing
        self.soloed = soloed
        self.muted = muted
    }

    public var isEmpty: Bool { colors.isEmpty && flashing.isEmpty && soloed.isEmpty && muted.isEmpty }
}

/// Group masters and overrides resolved against the frame's group order.
///
/// Per frame, in this order (ADR 0005): scene → colour override → flash → per-group master →
/// solo/mute → global master → blackout. `apply(to:)` does the colour override and the flash on the
/// frame; `scale(group:master:)` gives a group's output scale from its master, solo/mute and the
/// global master. Blackout is the composer's last step and zeroes everything, overrides included.
///
/// - A colour override multiplies the override colour by each segment's peak, so a dark segment stays
///   dark: an override never turns a light on. COBs (warm white) are left to the scene.
/// - A flash puts the group's RGB at the override colour (white without one) and its COBs at full,
///   and bypasses the group's own master, as a console flash button does. Mute, solo, the global
///   master and blackout still apply to it.
/// - Strobe, macro and program channels are never involved: the composer writes them as 0.
public struct GroupMix: Equatable, Sendable {
    /// Group order of the frames this mix applies to.
    public let ids: [RigGroupID]
    /// Per-group master, 0…1 (1 for a group without a saved master).
    public let masters: [Double]
    /// Colour override per group, nil for none.
    public let colors: [LightColor?]
    public let flashing: [Bool]
    /// False for a muted group, and for every group not soloed while a solo is on.
    public let audible: [Bool]
    /// Whether `apply(to:)` changes anything (a colour override or a flash is on).
    public let changesFrame: Bool
    /// A group of the layout is soloed: groups outside `ids` are dark too.
    private let soloing: Bool

    public init(ids: [RigGroupID], masters: [RigGroupID: Double] = [:], overrides: GroupOverrides = GroupOverrides()) {
        self.ids = ids
        self.masters = ids.map { id in
            let v = masters[id] ?? 1
            return v.isFinite ? min(1, max(0, v)) : 1
        }
        colors = ids.map { id in overrides.colors[id].map { LightColor($0.r, $0.g, $0.b).clamped } }
        flashing = ids.map { overrides.flashing.contains($0) }
        let soloing = ids.contains { overrides.soloed.contains($0) }
        self.soloing = soloing
        audible = ids.map { !overrides.muted.contains($0) && (!soloing || overrides.soloed.contains($0)) }
        changesFrame = colors.contains { $0 != nil } || flashing.contains(true)
    }

    /// Position of `id`, or nil when the mix has no such group.
    public func index(of id: RigGroupID) -> Int? { ids.firstIndex(of: id) }

    /// The master of the group at position `position` of the frame, or 1 when it is not in the mix.
    public func master(of id: RigGroupID, at position: Int) -> Double {
        guard let i = slot(id, hint: position) else { return 1 }
        return masters[i]
    }

    /// Output scale of the group at mix position `index` before blackout: its master (a flash
    /// bypasses it), solo/mute, then the global `master`. `groupMaster: false` leaves the group
    /// master out (frames already scaled by it, as during the preview restore blend).
    /// A position outside the mix plays at `master`, and is dark while a solo is on.
    public func scale(group index: Int, master: Double, groupMaster: Bool = true) -> Double {
        guard index >= 0, index < ids.count else { return soloing ? 0 : master }
        guard audible[index] else { return 0 }
        return groupMaster && !flashing[index] ? master * masters[index] : master
    }

    /// Colour overrides and flashes, written in place into the frame's buffers. Nothing happens,
    /// and nothing is copied, without an override.
    public func apply(to frame: inout RigFrame) {
        guard changesFrame else { return }
        for g in frame.groups.indices {
            guard let i = slot(frame.groups[g].id, hint: g) else { continue }
            if flashing[i] {
                let c = colors[i] ?? LightColor(1, 1, 1)
                for k in frame.groups[g].light.rgb.indices { frame.groups[g].light.rgb[k] = c }
                for k in frame.groups[g].light.cob.indices { frame.groups[g].light.cob[k] = 1 }
            } else if let c = colors[i] {
                for k in frame.groups[g].light.rgb.indices {
                    let old = frame.groups[g].light.rgb[k]
                    let p = clamp01(old.peak)
                    frame.groups[g].light.rgb[k] = LightColor(c.r * p, c.g * p, c.b * p, old.w)
                }
            }
        }
    }

    @inline(__always)
    private func slot(_ id: RigGroupID, hint: Int) -> Int? {
        if hint >= 0, hint < ids.count, ids[hint] == id { return hint }
        return index(of: id)
    }
}
