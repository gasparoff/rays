import XCTest
@testable import RaysCore

final class RigFrameTests: XCTestCase {
    private func light(_ v: Double, rgb: Int = 1, cob: Int = 1) -> RoleFrame {
        RoleFrame(rgb: Array(repeating: LightColor(v, v / 2, v / 4), count: rgb), cob: Array(repeating: v, count: cob))
    }

    private func frame(groups n: Int) -> RigFrame {
        RigFrame(groups: (0..<n).map { GroupFrame(id: RigGroupID("g\($0)"), light: light(Double($0 + 1) / 10, rgb: $0 + 1)) })
    }

    func testClassicFrameHasLeftCenterRightGroupsInOrder() {
        XCTAssertEqual(RigFrame.black.groups.map(\.id), [.left, .center, .right])
        XCTAssertEqual(RigFrame.black.groups.map(\.id), RigLayout.classic.groups.map(\.id))
        XCTAssertEqual(RigFrame.black.center.rgb.count, RigFrame.centerSegments)
        XCTAssertEqual(RigFrame.black.center.cob.count, RigFrame.centerCOBs)
        let f = RigFrame(left: light(0.1), center: light(0.5, rgb: 6, cob: 3), right: light(0.9))
        XCTAssertEqual(f.groups.map(\.id), [.left, .center, .right])
        XCTAssertEqual(f.groups.map(\.light), [light(0.1), light(0.5, rgb: 6, cob: 3), light(0.9)])
        for role in FixtureRole.allCases { XCTAssertEqual(f.index(of: role.groupID), FixtureRole.allCases.firstIndex(of: role)) }
    }

    func testAccessorsSubscriptAndGroupLookupShareStorage() {
        var f = RigFrame.black
        f.left = light(0.2)
        XCTAssertEqual(f[.left], light(0.2))
        XCTAssertEqual(f[group: .left], light(0.2))
        XCTAssertEqual(f.groups[0].light, light(0.2))

        f[.center].rgb[3] = LightColor(1, 0, 0)
        XCTAssertEqual(f.center.rgb[3], LightColor(1, 0, 0))
        XCTAssertEqual(f.groups[1].light.rgb[3], LightColor(1, 0, 0))

        f[group: .right] = light(0.7)
        XCTAssertEqual(f.right, light(0.7))
        XCTAssertEqual(f[.right], light(0.7))
        f.groups[2].light.cob[0] = 0.3
        XCTAssertEqual(f.right.cob, [0.3])
        XCTAssertEqual(f.groups.count, 3)
    }

    func testFramesWithAnyNumberOfGroupsAreAddressableById() {
        for n in [1, 2, 4, 5] {
            var f = frame(groups: n)
            XCTAssertEqual(f.groups.count, n)
            for i in 0..<n {
                let id = RigGroupID("g\(i)")
                XCTAssertEqual(f.index(of: id), i)
                XCTAssertEqual(f[group: id]?.rgb.count, i + 1)
                f[group: id]?.cob = [1]
                XCTAssertEqual(f.groups[i].light.cob, [1])
            }
            XCTAssertTrue(f.isFinite)
            XCTAssertEqual(f.scaled(0).groups.map(\.id), f.groups.map(\.id))
            XCTAssertEqual(f.mixed(with: f.scaled(0), 1), f.scaled(0))
        }
    }

    func testUnknownGroupsAreHandledSafely() {
        var f = frame(groups: 2)
        XCTAssertNil(f.index(of: .left))
        XCTAssertNil(f[group: RigGroupID("nope")])
        // Classic accessors on a frame without classic groups read empty and ignore writes.
        XCTAssertEqual(f.left, RoleFrame(rgb: [], cob: []))
        XCTAssertEqual(f[.center], RoleFrame(rgb: [], cob: []))
        let before = f
        f.left = light(1)
        f[.right].cob = [1]
        f[.center] = light(1)
        f[group: RigGroupID("nope")] = nil
        XCTAssertEqual(f, before)
        // Setting a new id appends, nil removes.
        f[group: RigGroupID("extra")] = light(0.4)
        XCTAssertEqual(f.groups.map(\.id.rawValue), ["g0", "g1", "extra"])
        f[group: RigGroupID("g0")] = nil
        XCTAssertEqual(f.groups.map(\.id.rawValue), ["g1", "extra"])
        XCTAssertEqual(RigFrame(groups: []).left, RoleFrame(rgb: [], cob: []))
        XCTAssertTrue(RigFrame(groups: []).isFinite)
    }

    func testMixIsMatchedByIdAndKeepsGroupsTheOtherFrameLacks() {
        let a = RigFrame(groups: [GroupFrame(id: .left, light: light(0)), GroupFrame(id: RigGroupID("x"), light: light(0.2))])
        let b = RigFrame(groups: [GroupFrame(id: RigGroupID("y"), light: light(1)), GroupFrame(id: .left, light: light(1))])
        let m = a.mixed(with: b, 0.5)
        XCTAssertEqual(m.groups.map(\.id), a.groups.map(\.id))
        XCTAssertEqual(m.left.cob, [0.5])
        XCTAssertEqual(m[group: RigGroupID("x")], light(0.2))
    }

    func testSanitizedKeepsLayoutAndClassicFallsBackToBlack() {
        var classic = RigFrame.black
        classic.center.cob[1] = .nan
        XCTAssertEqual(classic.sanitized, .black)
        var other = frame(groups: 4)
        other.groups[3].light.rgb[0] = LightColor(.infinity, 0, 0)
        let s = other.sanitized
        XCTAssertEqual(s.groups.map(\.id), other.groups.map(\.id))
        XCTAssertEqual(s.groups.map(\.light.rgb.count), [1, 2, 3, 4])
        XCTAssertTrue(s.groups.allSatisfy { $0.light.rgb.allSatisfy { $0 == .black } && $0.light.cob.allSatisfy { $0 == 0 } })
    }

    /// The 30 Hz path writes into the frame through `left/center/right` and the role subscript. Those
    /// accessors must mutate the stored arrays in place (no copy-on-write copy per write), so a uniquely
    /// owned frame keeps the same buffers across writes.
    func testWritesThroughAccessorsMutateStorageInPlace() {
        func groupsBase(_ f: RigFrame) -> UnsafeRawPointer? { f.groups.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
        func rgbBase(_ f: RigFrame) -> UnsafeRawPointer? { f.center.rgb.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
        func cobBase(_ f: RigFrame) -> UnsafeRawPointer? { f[.left].cob.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }

        var f = RigFrame(left: light(0), center: light(0, rgb: 6, cob: 3), right: light(0))
        // First writes make every buffer uniquely owned by `f`.
        f.center.rgb[0] = LightColor(0, 0, 0)
        f[.left].cob[0] = 0
        let groups = groupsBase(f), rgb = rgbBase(f), cob = cobBase(f)
        for k in 0..<RigFrame.centerSegments { f.center.rgb[k] = LightColor(1, 1, 1) }
        for role in FixtureRole.allCases { f[role].cob[0] = 0.5 }
        f.right.rgb[0] = LightColor(0, 1, 0)
        XCTAssertEqual(groupsBase(f), groups)
        XCTAssertEqual(rgbBase(f), rgb)
        XCTAssertEqual(cobBase(f), cob)
        XCTAssertEqual(f.groups.count, 3)
        XCTAssertEqual(f.center.rgb, Array(repeating: LightColor(1, 1, 1), count: 6))
        XCTAssertEqual(f.left.cob, [0.5])
    }
}
