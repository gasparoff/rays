import Foundation
import XCTest

@testable import RaysCore

/// Rig layout data model (ADR 0005, step 2): ids, groups, the classic preset, fixture appearance,
/// and saved-file compatibility of patches and profiles.
final class RigLayoutTests: XCTestCase {
    /// patch.json as written before groups existed: explicit and automatic roles, a custom profile.
    let oldPatchJSON = #"""
        {
          "confirmedFingerprint" : "0123456789abcdef",
          "customProfiles" : [
            {
              "channels" : [ { "kind" : "red", "value" : 0 }, { "kind" : "green", "value" : 0 }, { "kind" : "blue", "value" : 0 } ],
              "id" : "custom.rgb",
              "isGeneric" : false,
              "isVerified" : false,
              "manufacturer" : "Acme",
              "mode" : "3 CH",
              "name" : "RGB",
              "notes" : ""
            }
          ],
          "fixtures" : [
            {
              "address" : 8,
              "id" : "B0DC4F2C-E823-43C0-AB87-232DE4A330D1",
              "label" : "TRI 180 · left",
              "profileID" : "varytec.tri180.8",
              "role" : "left",
              "universe" : 1
            },
            {
              "address" : 24,
              "id" : "2B9C6A57-3E58-4F5B-9B0D-6A1C7E2F4D10",
              "label" : "TRI 380",
              "profileID" : "varytec.tri380.25",
              "universe" : 1
            },
            {
              "address" : 100,
              "id" : "7D1E2F3A-4B5C-4D6E-8F70-8192A3B4C5D6",
              "label" : "Bar",
              "profileID" : "custom.rgb",
              "role" : "right",
              "universe" : 0
            }
          ]
        }
        """#

    func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    // MARK: Saved-file compatibility

    func testOldPatchDecodesUnchangedAsTheClassicLayout() throws {
        let patch = try JSONDecoder().decode(Patch.self, from: Data(oldPatchJSON.utf8))
        XCTAssertEqual(patch.fixtures.count, 3)
        XCTAssertEqual(patch.fixtures.map(\.role), [.left, nil, .right])
        XCTAssertEqual(patch.fixtures.map(\.address), [8, 24, 100])
        XCTAssertEqual(patch.customProfiles.map(\.id), ["custom.rgb"])
        XCTAssertNil(patch.customProfiles[0].visual)
        XCTAssertEqual(patch.confirmedFingerprint, "0123456789abcdef")
        XCTAssertNil(patch.layout)
        XCTAssertEqual(patch.resolvedLayout, .classic)
        XCTAssertTrue(patch.fixtures.allSatisfy { $0.group == nil && $0.offset == nil })
        // Missing groups follow the (explicit or guessed) role.
        XCTAssertEqual(patch.groupIDs(library: ProfileLibrary()), [.left, .center, .right])
    }

    func testWritersKeepTheOldKeysWhileTheNewFieldsAreUnset() throws {
        let patch = try JSONDecoder().decode(Patch.self, from: Data(oldPatchJSON.utf8))
        let object = try encodedObject(patch)
        XCTAssertEqual(Set(object.keys), ["fixtures", "customProfiles", "confirmedFingerprint"])
        let fixtures = try XCTUnwrap(object["fixtures"] as? [[String: Any]])
        XCTAssertEqual(Set(fixtures[0].keys), ["id", "label", "profileID", "universe", "address", "role"])
        XCTAssertEqual(Set(fixtures[1].keys), ["id", "label", "profileID", "universe", "address"])
        let profiles = try XCTUnwrap(object["customProfiles"] as? [[String: Any]])
        XCTAssertNil(profiles[0]["visual"])
        XCTAssertEqual(try JSONDecoder().decode(Patch.self, from: JSONEncoder().encode(patch)), patch)
    }

    func testNewFieldsRoundTrip() throws {
        var patch = try JSONDecoder().decode(Patch.self, from: Data(oldPatchJSON.utf8))
        let bar = RigGroup(
            id: RigGroupID("g-bar"), name: "Bar", labelColor: SceneRGB(r: 0, g: 1, b: 0.5), shape: .bar,
            position: StagePoint(x: 0.25, y: 0.8), rotation: 15, scale: 1.5, roles: ["side", "accent"], master: 0.7)
        patch.layout = RigLayout(groups: RigLayout.classic.groups + [bar])
        patch.fixtures[2].group = bar.id
        patch.fixtures[2].offset = StagePoint(x: -0.05, y: 0.1)
        patch.customProfiles[0].visual = FixtureAppearance(kind: .wash, zones: .grid(columns: 4))
        let decoded = try JSONDecoder().decode(Patch.self, from: JSONEncoder().encode(patch))
        XCTAssertEqual(decoded, patch)
        XCTAssertEqual(decoded.layout?.group(bar.id), bar)
        XCTAssertEqual(decoded.groupIDs(library: ProfileLibrary()), [.left, .center, bar.id])
        XCTAssertFalse(decoded.resolvedLayout.isClassic)
    }

    func testMalformedNewFieldsNeverLoseThePatch() throws {
        let json = #"""
            {
              "customProfiles" : [
                { "channels" : [ { "kind" : "red", "value" : 0 } ], "id" : "c.x", "isGeneric" : false, "isVerified" : false,
                  "manufacturer" : "A", "mode" : "1", "name" : "X", "notes" : "", "visual" : "bar" }
              ],
              "fixtures" : [
                { "address" : 1, "id" : "B0DC4F2C-E823-43C0-AB87-232DE4A330D1", "label" : "A", "profileID" : "c.x",
                  "universe" : 0, "group" : 42, "offset" : "near" }
              ],
              "layout" : { "groups" : [ { "name" : "no id" }, { "id" : "ok", "master" : 7, "roles" : [ "side" ] } ] }
            }
            """#
        let patch = try JSONDecoder().decode(Patch.self, from: Data(json.utf8))
        XCTAssertEqual(patch.fixtures.count, 1)
        XCTAssertNil(patch.fixtures[0].group)
        XCTAssertNil(patch.fixtures[0].offset)
        XCTAssertNil(patch.customProfiles[0].visual)
        XCTAssertEqual(patch.layout?.groups.map(\.id), [RigGroupID("ok")], "the group without an id is skipped")
        XCTAssertEqual(patch.layout?.groups.first?.master, 1, "masters are clamped to 0…1")
        XCTAssertEqual(patch.layout?.groups.first?.name, "ok")

        let broken = #"{ "customProfiles" : [], "fixtures" : [], "layout" : [ 1, 2 ] }"#
        XCTAssertNil(try JSONDecoder().decode(Patch.self, from: Data(broken.utf8)).layout)
    }

    func testFingerprintIgnoresLayoutGroupsOffsetsAndVisuals() throws {
        let library = ProfileLibrary()
        let patch = try JSONDecoder().decode(Patch.self, from: Data(oldPatchJSON.utf8))
        var edited = patch
        edited.layout = .classic
        edited.fixtures[0].group = .center
        edited.fixtures[0].offset = StagePoint(x: 0.1, y: 0.2)
        edited.customProfiles[0].visual = FixtureAppearance(kind: .bar, zones: .horizontal)
        XCTAssertEqual(edited.fingerprint(library: library), patch.fingerprint(library: library))
        // The built-in Varytec profiles declare a triangle visual; FingerprintRegressionTests pins the
        // confirmed TRI 180 fingerprint, so the visual must stay out of it.
        XCTAssertNotNil(library.profile(id: "varytec.tri180.8")?.visual)
    }

    // MARK: Layout

    func testClassicLayoutIsTodaysThreePositions() {
        let classic = RigLayout.classic
        XCTAssertEqual(classic.groups.map(\.id), [.left, .center, .right])
        XCTAssertEqual(classic.groups.map(\.id), FixtureRole.allCases.map(\.groupID))
        XCTAssertEqual(classic.groups.map(\.position), [StagePoint(x: 0, y: 0.5), StagePoint(x: 0.5, y: 0.5), StagePoint(x: 1, y: 0.5)])
        XCTAssertEqual(classic.groups.map(\.roles), [["side"], ["center"], ["side"]])
        XCTAssertTrue(classic.groups.allSatisfy { $0.shape == .triangle && $0.master == 1 && $0.scale == 1 && $0.rotation == 0 })
        XCTAssertTrue(classic.isClassic)
        XCTAssertEqual(classic.group(.center)?.name, FixtureRole.center.label)
        XCTAssertNil(classic.group(RigGroupID("missing")))
        for role in FixtureRole.allCases { XCTAssertEqual(FixtureRole(groupID: role.groupID), role) }
        XCTAssertNil(FixtureRole(groupID: RigGroupID("g-1")))
        XCTAssertNotEqual(RigGroupID.unique(), RigGroupID.unique())
    }

    func testGroupJSONIsStableAndTolerant() throws {
        let group = RigGroup(id: RigGroupID("g"), name: "G", roles: ["side", "accent", "center"])
        let object = try encodedObject(group)
        XCTAssertEqual(object["roles"] as? [String], ["accent", "center", "side"], "roles are written sorted")
        XCTAssertEqual(object["id"] as? String, "g", "ids are bare strings")
        XCTAssertNil(object["shape"])

        let minimal = try JSONDecoder().decode(RigGroup.self, from: Data(#"{ "id" : "x" }"#.utf8))
        XCTAssertEqual(minimal, RigGroup(id: RigGroupID("x"), name: "x"))
        let odd = #"{ "id" : "y", "shape" : "laser", "position" : { "x" : 0.2 }, "scale" : "big", "labelColor" : { "r" : 2 } }"#
        let decoded = try JSONDecoder().decode(RigGroup.self, from: Data(odd.utf8))
        XCTAssertEqual(decoded.shape, .generic)
        XCTAssertEqual(decoded.position, StagePoint(x: 0.2, y: 0))
        XCTAssertEqual(decoded.scale, 1)
        XCTAssertEqual(decoded.labelColor, SceneRGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(try JSONDecoder().decode(RigLayout.self, from: Data("{}".utf8)).groups, [])
    }

    // MARK: Appearance

    func testVisualKeyDecodesAndEncodes() throws {
        func decode(_ json: String) throws -> FixtureAppearance {
            try JSONDecoder().decode(FixtureAppearance.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{ "kind" : "bar", "zones" : "horizontal" }"#), FixtureAppearance(kind: .bar, zones: .horizontal))
        XCTAssertEqual(try decode(#"{ "kind" : "movingHead" }"#), FixtureAppearance(kind: .movingHead))
        XCTAssertEqual(try decode(#"{ "kind" : "wash", "zones" : "grid", "columns" : 4 }"#).zones, .grid(columns: 4))
        XCTAssertNil(try decode(#"{ "kind" : "wash", "zones" : "grid" }"#).zones, "a grid needs columns")
        XCTAssertNil(try decode(#"{ "kind" : "bar", "zones" : "spiral" }"#).zones)
        XCTAssertEqual(try decode(#"{ "kind" : "laser" }"#).kind, .generic, "unknown kinds from newer versions")
        XCTAssertEqual(try decode("{}").kind, .generic)

        let grid = try encodedObject(FixtureAppearance(kind: .wash, zones: .grid(columns: 3)))
        XCTAssertEqual(grid["kind"] as? String, "wash")
        XCTAssertEqual(grid["zones"] as? String, "grid")
        XCTAssertEqual(grid["columns"] as? Int, 3)
        XCTAssertEqual(Set(try encodedObject(FixtureAppearance(kind: .par)).keys), ["kind"])
        for zones in [ZoneLayout.horizontal, .vertical, .radial, .grid(columns: 2)] {
            let look = FixtureAppearance(kind: .strip, zones: zones)
            XCTAssertEqual(try JSONDecoder().decode(FixtureAppearance.self, from: JSONEncoder().encode(look)), look)
            XCTAssertTrue(ZoneLayout.names.contains(zones.name))
        }
    }

    func testAppearanceIsInferredFromTheChannels() {
        func profile(_ kinds: [ChannelKind], visual: FixtureAppearance? = nil) -> FixtureProfile {
            FixtureProfile(id: "t", name: "T", channels: kinds.map { ChannelDefinition($0) }, visual: visual)
        }
        let rgb: [ChannelKind] = [.red, .green, .blue]
        XCTAssertEqual(profile([.dimmer] + rgb + [.white, .ignore]).appearance, FixtureAppearance(kind: .par))
        XCTAssertEqual(profile(rgb + rgb + rgb).appearance, FixtureAppearance(kind: .bar, zones: .horizontal))
        XCTAssertEqual(profile([.blinder]).appearance, FixtureAppearance(kind: .blinder))
        XCTAssertEqual(profile([.dimmer, .blinder, .blinder]).appearance, FixtureAppearance(kind: .blinder, zones: .horizontal))
        XCTAssertEqual(profile([.dimmer]).appearance, FixtureAppearance(kind: .par), "fallback")
        let declared = FixtureAppearance(kind: .spot)
        XCTAssertEqual(profile(rgb + rgb, visual: declared).appearance, declared, "a declared visual wins")
        XCTAssertEqual(ProfileLibrary().profile(id: "varytec.tri380.25")?.appearance, FixtureAppearance(kind: .triangle, zones: .radial))
    }
}
