import XCTest
import LightCore

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
}
