import XCTest
import RaysCore

/// Validates every community fixture profile in `Profiles/` so contributors get a
/// clear failure before review.
final class CommunityProfilesTests: XCTestCase {
    private var profilesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RaysTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    func testCommunityProfilesDecodeAndAreSane() throws {
        let result = ProfileLibrary.loadProfiles(in: profilesDirectory)
        XCTAssertEqual(result.errors, [], "Invalid JSON in Profiles/")
        XCTAssertFalse(result.profiles.isEmpty, "Profiles/ should contain at least the example profile")

        var ids = Set(ProfileLibrary.builtIn.map(\.id))
        for profile in result.profiles {
            XCTAssertEqual(profile.problems, [], profile.id)
            XCTAssertTrue(ids.insert(profile.id).inserted, "Duplicate profile id \(profile.id)")
            XCTAssertFalse(profile.name.isEmpty, "\(profile.id): name is empty")
            XCTAssertFalse(profile.manufacturer.isEmpty, "\(profile.id): manufacturer is empty")
            XCTAssertFalse(profile.mode.isEmpty, "\(profile.id): mode is empty")
        }
    }

    /// The optional `visual` key: an object with a known `kind`, known `zones`, and `columns` (≥ 1) only for a grid.
    func testVisualKeyIsValidWhenPresent() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: profilesDirectory, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
        let kinds = Set(FixtureShape.allCases.map(\.rawValue))
        var checked = 0
        for file in files {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            let entries = (json as? [[String: Any]]) ?? [(json as? [String: Any]) ?? [:]]
            for entry in entries {
                guard let raw = entry["visual"] else { continue }
                let name = file.lastPathComponent
                guard let visual = raw as? [String: Any] else {
                    XCTFail("\(name): visual must be an object")
                    continue
                }
                checked += 1
                XCTAssertTrue(Set(visual.keys).isSubset(of: ["kind", "zones", "columns"]), "\(name): unknown visual key")
                XCTAssertTrue(kinds.contains(visual["kind"] as? String ?? ""), "\(name): unknown visual kind")
                if let zones = visual["zones"] {
                    let zoneName = zones as? String ?? ""
                    XCTAssertTrue(ZoneLayout.names.contains(zoneName), "\(name): unknown zones")
                    if zoneName == "grid" {
                        XCTAssertGreaterThanOrEqual(visual["columns"] as? Int ?? 0, 1, "\(name): a grid needs columns")
                    } else {
                        XCTAssertNil(visual["columns"], "\(name): columns only apply to a grid")
                    }
                } else {
                    XCTAssertNil(visual["columns"], "\(name): columns only apply to a grid")
                }
                let profile = try JSONDecoder().decode(FixtureProfile.self, from: JSONSerialization.data(withJSONObject: entry))
                XCTAssertNotNil(profile.visual, name)
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 1, "the bar example declares its visual")
    }

    /// Every bundled profile gets a sensible preview appearance, declared or inferred from its channels.
    func testEveryBundledProfileHasASensibleAppearance() {
        let par = FixtureAppearance(kind: .par)
        let expected: [String: FixtureAppearance] = [
            "generic.rgb3": par, "generic.rgbw4": par, "generic.drgb4": par, "generic.drgbw5": par,
            "varytec.tri180.5": VarytecRig.triangle, "varytec.tri180.8": VarytecRig.triangle,
            "varytec.tri380.5": VarytecRig.triangle, "varytec.tri380.25": VarytecRig.triangle,
            "community.generic.bar-2zone-rgb-6ch": FixtureAppearance(kind: .bar, zones: .horizontal),
            "community.generic.par-drgba-5ch": par, "community.generic.par-drgbwa-6ch": par,
            "community.generic.par-drgbwauv-7ch": par, "community.generic.par-rgba-4ch": par,
            "community.generic.par-rgbw-6ch": par, "community.generic.par-rgbwa-5ch": par,
            "varytec.event-par-ip65-4ch": par, "varytec.event-par-ip65-7ch": par, "varytec.event-par-ip65-9ch": par,
            "varytec.pad7-rgbwa-5ch": par, "varytec.pad7-rgbwa-6ch": par, "varytec.pad7-rgbwa-9ch": par,
            "varytec.pad7-rgbwauv-10ch": par, "varytec.pad7-rgbwauv-6ch": par, "varytec.pad7-rgbwauv-7ch": par,
        ]
        let all = ProfileLibrary.builtIn + ProfileLibrary.loadProfiles(in: profilesDirectory).profiles
        let listed = all.filter { !$0.id.hasPrefix("ofl.") }
        XCTAssertEqual(Set(listed.map(\.id)), Set(expected.keys), "add new bundled profiles to this list")
        for profile in listed { XCTAssertEqual(profile.appearance, expected[profile.id], profile.id) }
        for profile in all {
            let look = profile.appearance
            XCTAssertNotEqual(look.kind, .generic, profile.id)
            if profile.rgbSegmentCount >= 2 { XCTAssertNotNil(look.zones, "\(profile.id): zones in channel order") }
            if profile.visual == nil && profile.rgbSegmentCount == 1 { XCTAssertEqual(look, par, profile.id) }
        }
    }

    /// Strobe, programme, sound and UV channels are mapped to `ignore` and must never leave 0,
    /// whatever the scene asks for; every light channel must respond.
    func testIgnoredChannelsStayAtZeroAndLightChannelsRespond() {
        let profiles = ProfileLibrary.loadProfiles(in: profilesDirectory).profiles
        for profile in profiles {
            let full = DMXComposer.channelValues(profile: profile, color: LightColor(1, 1, 1, 1), master: 1)
            XCTAssertEqual(full.count, profile.footprint, profile.id)
            for (i, ch) in profile.channels.enumerated() {
                if ch.kind == .ignore { XCTAssertEqual(full[i], 0, "\(profile.id) ch \(i + 1)") }
                if [.dimmer, .red, .green, .blue, .white].contains(ch.kind) {
                    XCTAssertGreaterThan(full[i], 0, "\(profile.id) ch \(i + 1) \(ch.kind)")
                }
            }
        }
    }

    /// Footprints documented in the Varytec manuals (unverified on hardware).
    func testVarytecManualFootprints() {
        let byID = Dictionary(uniqueKeysWithValues: ProfileLibrary.loadProfiles(in: profilesDirectory).profiles.map { ($0.id, $0) })
        let expected = [
            "varytec.event-par-ip65-4ch": 4, "varytec.event-par-ip65-7ch": 7, "varytec.event-par-ip65-9ch": 9,
            "varytec.pad7-rgbwa-5ch": 5, "varytec.pad7-rgbwa-6ch": 6, "varytec.pad7-rgbwa-9ch": 9,
            "varytec.pad7-rgbwauv-6ch": 6, "varytec.pad7-rgbwauv-7ch": 7, "varytec.pad7-rgbwauv-10ch": 10,
        ]
        for (id, footprint) in expected {
            XCTAssertEqual(byID[id]?.footprint, footprint, id)
            XCTAssertEqual(byID[id]?.isVerified, false, id)
        }
    }

    func testOpenFixtureLibraryImportsAreAttributedUnverifiedAndOrganisedByBrand() throws {
        let ofl = profilesDirectory.appendingPathComponent("ofl", isDirectory: true)
        let result = ProfileLibrary.loadProfiles(in: ofl)
        XCTAssertEqual(result.errors, [])
        XCTAssertGreaterThan(result.profiles.count, 100)
        for p in result.profiles {
            XCTAssertTrue(p.id.hasPrefix("ofl."), p.id)
            XCTAssertFalse(p.isVerified, p.id)
            XCTAssertFalse(p.isGeneric, p.id)
            XCTAssertTrue(p.notes.contains("Open Fixture Library (MIT"), p.id)
            let kinds = Set(p.channels.map(\.kind))
            XCTAssertTrue(kinds.isSuperset(of: [.red, .green, .blue]), p.id)
            XCTAssertFalse(kinds.contains(.blinder), p.id)
        }
        let brands = try FileManager.default.contentsOfDirectory(atPath: ofl.path).filter { !$0.hasPrefix(".") }
        XCTAssertGreaterThanOrEqual(brands.count, 10)
    }

    func testLoaderReadsSubfoldersAndReportsRelativePaths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = dir.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = FixtureProfile(id: "acme.x", name: "X", manufacturer: "Acme", channels: [.init(.red), .init(.green), .init(.blue)])
        try JSONEncoder().encode(profile).write(to: sub.appendingPathComponent("x.json"))
        try Data("{".utf8).write(to: sub.appendingPathComponent("broken.json"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let r = ProfileLibrary.loadProfiles(in: dir)
        XCTAssertEqual(r.profiles.map(\.id), ["acme.x"])
        XCTAssertEqual(r.errors.count, 1)
        XCTAssertTrue(r.errors[0].hasPrefix("acme/broken.json"), r.errors[0])
    }
}
