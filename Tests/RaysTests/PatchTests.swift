import XCTest
@testable import RaysCore
@testable import RaysEngine

final class PatchTests: XCTestCase {
    let lib = ProfileLibrary()
    var rgbw: FixtureProfile { lib.profile(id: "generic.rgbw4")! }

    func testSequentialGroupHasNoIssues() {
        var p = Patch()
        p.addGroup(profile: rgbw, count: 6, startAddress: 1, universe: 0)
        XCTAssertEqual(p.fixtures.map(\.address), [1, 5, 9, 13, 17, 21])
        XCTAssertTrue(p.validate(library: lib).isEmpty)
    }

    func testOverlapDetectedOnlyWithinSameUniverse() {
        var p = Patch(fixtures: [
            PatchedFixture(label: "A", profileID: "generic.rgbw4", universe: 0, address: 1),
            PatchedFixture(label: "B", profileID: "generic.rgbw4", universe: 0, address: 4),
        ])
        XCTAssertEqual(p.validate(library: lib).count, 1)
        p.fixtures[1].universe = 1
        XCTAssertTrue(p.validate(library: lib).isEmpty)
    }

    func test512Boundary() {
        var p = Patch(fixtures: [PatchedFixture(label: "A", profileID: "generic.rgbw4", universe: 0, address: 509)])
        XCTAssertTrue(p.validate(library: lib).isEmpty, "509–512 fits")
        p.fixtures[0].address = 510
        XCTAssertFalse(p.validate(library: lib).isEmpty, "510–513 exceeds the universe")
        p.fixtures[0].address = 0
        XCTAssertFalse(p.validate(library: lib).isEmpty)
        p.fixtures[0].address = 1
        p.fixtures[0].universe = 2
        XCTAssertFalse(p.validate(library: lib).isEmpty, "ODE MK3 has universes 0 and 1 only")
    }

    func testUnknownProfileIsRejected() {
        let p = Patch(fixtures: [PatchedFixture(label: "?", profileID: "varytec.unknown", universe: 0, address: 1)])
        XCTAssertTrue(p.validate(library: lib).first!.message.contains("unknown"))
        let frames = DMXComposer.compose(patch: p, library: lib, colors: [LightColor(1, 1, 1, 1)], master: 1, blackout: false)
        XCTAssertTrue(frames.values.allSatisfy { $0.allSatisfy { $0 == 0 } }, "unknown profile never writes channels")
    }

    func testConfirmationIsInvalidatedByEdits() {
        var p = Patch()
        p.addGroup(profile: rgbw, count: 2, startAddress: 1, universe: 0)
        p.setConfirmed(true, library: lib)
        XCTAssertTrue(p.isConfirmed(library: lib))
        p.fixtures[1].address = 9
        XCTAssertFalse(p.isConfirmed(library: lib))
        p.setConfirmed(true, library: lib)
        p.fixtures[0].profileID = "generic.rgb3"
        XCTAssertFalse(p.isConfirmed(library: lib))
    }

    func testConfirmationInvalidatedByCustomProfileChannelChange() {
        let custom = FixtureProfile(id: "custom.x", name: "X", isGeneric: false, channels: [.init(.red), .init(.constant, value: 255)])
        var p = Patch(fixtures: [PatchedFixture(label: "A", profileID: "custom.x", universe: 0, address: 1)], customProfiles: [custom])
        p.setConfirmed(true, library: lib)
        XCTAssertTrue(p.isConfirmed(library: lib))
        p.customProfiles[0].channels[1].value = 200
        XCTAssertFalse(p.isConfirmed(library: lib))
    }

    func testPersistenceRoundTripIsAtomicJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ls-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        XCTAssertEqual(try store.loadPatch(), .empty)
        var p = Patch()
        p.addGroup(profile: rgbw, count: 3, startAddress: 10, universe: 1)
        p.setConfirmed(true, library: lib)
        try store.savePatch(p)
        XCTAssertEqual(try store.loadPatch(), p)
        var prefs = Preferences()
        prefs.scene = .sunset
        prefs.manualIP = "192.168.0.10"
        try store.savePreferences(prefs)
        XCTAssertEqual(store.loadPreferences(), prefs)
        let json = try String(contentsOf: store.preferencesURL, encoding: .utf8)
        XCTAssertFalse(json.contains("armed"), "armed state is never persisted")
    }

    func testPreferencesToleratesMissingKeys() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"scene":"pulse"}"#.utf8))
        XCTAssertEqual(prefs.scene, .pulse)
        XCTAssertEqual(prefs.master, Preferences().master)
    }

    func testNoDefaultRealPatch() {
        XCTAssertTrue(Patch.empty.fixtures.isEmpty)
    }
}
