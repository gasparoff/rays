import XCTest
import RaysCore

/// Validates every community fixture profile in `Profiles/` so contributors get a
/// clear failure before review.
final class CommunityProfilesTests: XCTestCase {
    private var profilesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LightCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
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
        let expected = ["varytec.event-par-ip65-4ch": 4, "varytec.event-par-ip65-7ch": 7, "varytec.event-par-ip65-9ch": 9,
                        "varytec.pad7-rgbwa-5ch": 5, "varytec.pad7-rgbwa-6ch": 6, "varytec.pad7-rgbwa-9ch": 9,
                        "varytec.pad7-rgbwauv-6ch": 6, "varytec.pad7-rgbwauv-7ch": 7, "varytec.pad7-rgbwauv-10ch": 10]
        for (id, footprint) in expected {
            XCTAssertEqual(byID[id]?.footprint, footprint, id)
            XCTAssertEqual(byID[id]?.isVerified, false, id)
        }
    }
}
