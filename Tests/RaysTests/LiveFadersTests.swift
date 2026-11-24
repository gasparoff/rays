import XCTest
@testable import RaysCore
@testable import RaysEngine

/// Faders of the performance panel (ADR 0005, step 8): generated from the patch, arranged by the user.
final class LiveFadersTests: XCTestCase {
    let library = ProfileLibrary()

    private func freePatch(profile: String) -> Patch {
        let groups = [
            RigGroup(id: RigGroupID("bar"), name: "Bar", position: StagePoint(x: 0.5, y: 0.2)),
            RigGroup(id: RigGroupID("dj"), name: "  ", position: StagePoint(x: 0.5, y: 0.8)),
            RigGroup(id: RigGroupID("floor"), name: "Floor", position: StagePoint(x: 0.2, y: 0.5)),
        ]
        return Patch(
            fixtures: [
                PatchedFixture(label: "A", profileID: profile, universe: 1, address: 1, group: RigGroupID("floor")),
                PatchedFixture(label: "B", profileID: profile, universe: 1, address: 10, group: RigGroupID("bar")),
            ],
            layout: RigLayout(groups: groups))
    }

    // MARK: Generated from the rig

    func testClassicRigKeepsTodaysSixFaders() {
        let tri = Patch(fixtures: [PatchedFixture(label: "TRI", profileID: "varytec.tri180.8", universe: 1, address: 1, role: .center)])
        for setup in [LiveFaderSetup.classic, LiveFaderSetup(patch: tri, library: library)] {
            XCTAssertEqual(
                setup.available,
                [.master, .warmLight, .energy, .group(.left), .group(.center), .group(.right)])
            XCTAssertEqual(setup.groups.map(\.name), FixtureRole.allCases.map(\.label))
            XCTAssertEqual(LiveFaderLayout.automatic.visible(in: setup), setup.available)
        }
        XCTAssertEqual(LiveFaderLayout.columns(for: 6), 3, "two rows of three, as before")
    }

    func testFreeLayoutGetsOneFaderPerGroupInLayoutOrder() {
        let setup = LiveFaderSetup(patch: freePatch(profile: "generic.rgbw4"), library: library)
        XCTAssertEqual(
            setup.available,
            [.master, .warmLight, .energy, .group(RigGroupID("bar")), .group(RigGroupID("dj")), .group(RigGroupID("floor"))])
        XCTAssertEqual(setup.name(of: RigGroupID("bar")), "Bar")
        XCTAssertEqual(setup.name(of: RigGroupID("dj")), "dj", "a blank name falls back to the id")
        XCTAssertNil(setup.name(of: .left))
    }

    func testWarmLightOnlyWhenALightHasAWhiteChannel() {
        let rgbOnly = LiveFaderSetup(patch: freePatch(profile: "generic.rgb3"), library: library)
        XCTAssertFalse(rgbOnly.hasWarmLight)
        XCTAssertFalse(rgbOnly.available.contains(.warmLight))
        XCTAssertTrue(LiveFaderSetup(patch: freePatch(profile: "generic.rgbw4"), library: library).hasWarmLight)
        XCTAssertTrue(LiveFaderSetup(patch: .empty, library: library).hasWarmLight, "the empty patch previews the classic rig")
    }

    // MARK: User arrangement

    func testHidingAndReorderingKeepMasterAndPlaceNewGroups() {
        let setup = LiveFaderSetup.classic
        var layout = LiveFaderLayout.automatic
        layout.setHidden(.warmLight, true)
        layout.setHidden(.master, true)
        XCTAssertFalse(layout.isHidden(.master), "master brightness can't be hidden")
        layout.move(.energy, by: 1, in: setup)
        layout.move(.group(.right), by: -5, in: setup)
        XCTAssertEqual(layout.visible(in: setup), [.group(.right), .master, .group(.left), .energy, .group(.center)])
        XCTAssertEqual(layout.all(in: setup).count, 6, "hidden faders stay in the settings list")
        XCTAssertFalse(layout.canMove(.group(.right), by: -1, in: setup))
        XCTAssertFalse(layout.isAutomatic)

        let bigger = LiveFaderSetup(
            hasWarmLight: true, groups: setup.groups + [LiveFaderSetup.Group(id: RigGroupID("new"), name: "New")])
        XCTAssertEqual(
            layout.visible(in: bigger), [.group(.right), .group(RigGroupID("new")), .master, .group(.left), .energy, .group(.center)],
            "a group the order doesn't name follows the group before it")
    }

    func testOrderOfAnotherSetupSurvivesAndMissingFadersAreSkipped() {
        let free = LiveFaderSetup(patch: freePatch(profile: "generic.rgb3"), library: library)
        var layout = LiveFaderLayout.automatic
        layout.move(.group(RigGroupID("floor")), by: -4, in: free)
        XCTAssertEqual(layout.visible(in: free).first, .group(RigGroupID("floor")))
        // On the classic rig the free groups are absent and the classic faders follow in default order.
        XCTAssertEqual(layout.visible(in: .classic), LiveFaderSetup.classic.available)
        layout.move(.group(.left), by: -3, in: .classic)
        XCTAssertEqual(layout.visible(in: .classic).first, .group(.left))
        XCTAssertEqual(layout.visible(in: free).first, .group(RigGroupID("floor")), "the free rig's order is kept")
    }

    func testColumns() {
        XCTAssertEqual((1...12).map(LiveFaderLayout.columns(for:)), [1, 2, 3, 2, 3, 3, 4, 4, 5, 5, 5, 5])
    }

    // MARK: Saving

    func testSavedLayoutRoundTripsAndToleratesBadData() throws {
        var layout = LiveFaderLayout.automatic
        layout.setHidden(.energy, true)
        layout.move(.group(.right), by: -1, in: .classic)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(LiveFaderLayout.decodeSaved(data), layout)

        let old = Data(#"{"order":["group:right","master","bogus","master"],"hidden":["master","warmLight"],"extra":1}"#.utf8)
        let decoded = LiveFaderLayout.decodeSaved(old)
        XCTAssertEqual(decoded.order, ["group:right", "master"], "unknown and duplicate keys are dropped")
        XCTAssertEqual(decoded.hidden, ["warmLight"], "master can't be hidden")
        XCTAssertEqual(LiveFaderLayout.decodeSaved(Data("{}".utf8)), .automatic)
        XCTAssertEqual(LiveFaderLayout.decodeSaved(Data("nonsense".utf8)), .automatic)
        XCTAssertEqual(LiveFaderLayout.decodeSaved(nil), .automatic)
    }

    func testFaderKeysNeverChange() {
        XCTAssertEqual(
            [LiveFader.master, .warmLight, .energy, .group(RigGroupID("g-1"))].map(\.key),
            ["master", "warmLight", "energy", "group:g-1"])
        XCTAssertEqual(LiveFader(key: "group:left"), .group(.left))
        XCTAssertNil(LiveFader(key: "group:"))
        XCTAssertNil(LiveFader(key: "levelLeft"))
    }
}
