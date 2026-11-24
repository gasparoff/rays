import Foundation

/// The rig the engine renders for a patch (ADR 0005, step 6): the groups of the patch layout, their frame
/// sizes, where every patched fixture stands on the stage, and the preview-only lights for the groups
/// nothing is patched to. Built once per patch or library change, never on the 30 Hz path.
///
/// - The frame has one group per layout group, in layout order. A fixture whose group the layout lacks
///   gets a group appended (the classic definition for a classic id), so no patched light goes dark.
/// - On the classic preset (`RigLayout.isClassic`) the frame is the classic one, TRI 380 sizes in the
///   centre whatever is patched, and each fixture's profile resamples it as before: saved scene masks and
///   DMX output stay byte-identical. On any other layout a group has the largest segment and COB counts
///   of the fixtures patched to it; a group without a fixture has the counts of its placeholder light.
public struct PatchRig: Equatable, Sendable {
    /// The groups the frames follow (the patch layout, duplicates dropped, missing groups appended).
    public let layout: RigLayout
    /// Emitter positions and frame sizes, one group per `layout` group.
    public let spatial: SpatialRig
    /// Group index (in `layout.groups` and in every frame) of each patched fixture.
    public let fixtureGroups: [Int]
    /// Stage position of each patched fixture: its group's position plus its offset. Fixtures of a group
    /// without an offset are spread `spread` apart across x, centred on the group.
    public let fixturePositions: [StagePoint]
    /// Classic preset: the classic three-group frame and the reference rig as preview.
    public let isClassic: Bool

    /// Distance across the stage between the fixtures of a group that have no offset.
    public static let spread = 0.06

    /// The rig of the empty patch: the classic preset.
    public static let classic = PatchRig(patch: .empty, library: ProfileLibrary())

    public init(patch: Patch, library base: ProfileLibrary) {
        var seen = Set<RigGroupID>()
        var groups = patch.resolvedLayout.groups.filter { seen.insert($0.id).inserted }
        let ids = patch.groupIDs(library: base)
        for id in ids where seen.insert(id).inserted {
            groups.append(RigLayout.classic.group(id) ?? RigGroup(id: id, name: id.rawValue))
        }
        let layout = RigLayout(groups: groups)
        self.layout = layout
        let index = Dictionary(groups.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let fixtureGroups = ids.map { index[$0] ?? 0 }
        self.fixtureGroups = fixtureGroups
        isClassic = layout.isClassic

        let lib = patch.library(base: base)
        let sizes: RigFrame
        if isClassic {
            sizes = .black
        } else {
            sizes = RigFrame(
                groups: groups.enumerated().map { g, group in
                    let profiles = patch.fixtures.indices.filter { fixtureGroups[$0] == g }
                        .compactMap { lib.profile(id: patch.fixtures[$0].profileID) }
                    let counts = profiles.isEmpty ? [Self.placeholder(for: group.shape)] : profiles
                    let rgb = counts.map(\.rgbSegmentCount).max() ?? 0
                    let cob = counts.map(\.cobCount).max() ?? 0
                    return GroupFrame(id: group.id, light: .black(rgb: rgb, cob: cob))
                })
        }
        spatial = SpatialRig(layout: layout, sizes: sizes)

        var positions: [StagePoint] = []
        positions.reserveCapacity(patch.fixtures.count)
        var placed = Array(repeating: 0, count: groups.count)
        let unplaced = groups.indices.map { g in
            patch.fixtures.indices.filter { fixtureGroups[$0] == g && patch.fixtures[$0].offset == nil }.count
        }
        for (i, fixture) in patch.fixtures.enumerated() {
            let g = fixtureGroups[i]
            let base = groups[g].position
            if let offset = fixture.offset {
                positions.append(StagePoint(x: base.x + offset.x, y: base.y + offset.y))
            } else {
                let k = Double(placed[g]) - Double(unplaced[g] - 1) / 2
                placed[g] += 1
                positions.append(StagePoint(x: base.x + k * Self.spread, y: base.y))
            }
        }
        fixturePositions = positions
    }

    /// Index of the group `id`, or nil.
    public func groupIndex(of id: RigGroupID) -> Int? { layout.groups.firstIndex { $0.id == id } }

    /// Where the frame's emitters sit (`spatial.black` is the all-black frame of this rig).
    public var black: RigFrame { spatial.black }

    // MARK: Preview-only lights

    /// The lights the preview shows for the groups that have no patched fixture (`occupied` false: all
    /// of them), composed into a buffer that is never sent. On the classic preset these are the
    /// reference rig's lights of the missing roles, as before; on any other layout one placeholder per
    /// empty group, drawn with the group's shape. `groups[i]` is the group index of `patch.fixtures[i]`.
    public func shadow(occupied: Bool) -> (patch: Patch, groups: [Int]) {
        let used = occupied ? Set(fixtureGroups) : []
        if isClassic {
            var rig = VarytecRig.referenceRig(universe: 1)
            rig.fixtures.removeAll { used.contains(groupIndex(of: ($0.role ?? .center).groupID) ?? -1) }
            return (rig, rig.fixtures.map { groupIndex(of: ($0.role ?? .center).groupID) ?? 0 })
        }
        var patch = Patch()
        var groups: [Int] = []
        var universe = 1, address = 1
        for (g, group) in layout.groups.enumerated() where !used.contains(g) {
            let profile = Self.placeholder(for: group.shape)
            if address + profile.footprint - 1 > 512 {
                universe += 1
                address = 1
            }
            if profile.id.hasPrefix(Self.placeholderPrefix), !patch.customProfiles.contains(where: { $0.id == profile.id }) {
                patch.customProfiles.append(profile)
            }
            patch.fixtures.append(
                PatchedFixture(
                    id: Self.placeholderID(g), label: group.name, profileID: profile.id, universe: universe, address: address,
                    group: group.id))
            groups.append(g)
            address += profile.footprint
        }
        return (patch, groups)
    }

    static let placeholderPrefix = "preview."

    /// Stable id of the placeholder of group `g` (the preview identifies lights by their visual id).
    static func placeholderID(_ g: Int) -> UUID {
        UUID(uuidString: String(format: "9E5E0000-0000-4000-8000-%012ld", g)) ?? UUID()
    }

    /// The light that stands in for an empty group: the TRI 180 for a triangle, otherwise a preview-only
    /// profile of the shape (a bar with four zones, a strip with eight, a two-cell blinder, an RGBW lamp).
    /// Its channels carry colour and white only: no strobe, macro or program channel exists to light.
    public static func placeholder(for shape: FixtureShape?) -> FixtureProfile {
        let kind = shape ?? .par
        func rgb(_ n: Int) -> [ChannelDefinition] { (0..<n).flatMap { _ in [ChannelDefinition(.red), .init(.green), .init(.blue)] } }
        let channels: [ChannelDefinition]
        let zones: ZoneLayout?
        switch kind {
        case .triangle:
            return VarytecRig.profiles.first { $0.id == "varytec.tri180.8" }!
        case .bar:
            channels = rgb(4)
            zones = .horizontal
        case .strip:
            channels = rgb(8)
            zones = .horizontal
        case .blinder:
            channels = [ChannelDefinition(.blinder), ChannelDefinition(.blinder)]
            zones = .horizontal
        case .par, .wash, .spot, .movingHead, .generic:
            channels = rgb(1) + [ChannelDefinition(.white)]
            zones = nil
        }
        return FixtureProfile(
            id: placeholderPrefix + kind.rawValue, name: kind.rawValue, mode: "preview", notes: "Preview-only placeholder",
            channels: channels, visual: FixtureAppearance(kind: kind, zones: zones))
    }
}
