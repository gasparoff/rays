import RaysEngine
import XCTest

/// Saved files moved from `Application Support/Light System` (the project's old name) to
/// `Application Support/RAYS`. Nothing may be lost on the way, and an older build must still find them.
final class ConfigDirectoryMigrationTests: XCTestCase {
    private var base: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        base = fileManager.temporaryDirectory.appendingPathComponent("rays-migration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: base)
    }

    private var current: URL { base.appendingPathComponent("RAYS", isDirectory: true) }
    private var legacy: URL { base.appendingPathComponent("Light System", isDirectory: true) }

    func testFreshMachineUsesTheNewFolderWithoutCreatingAnything() {
        XCTAssertEqual(ConfigStore.resolveDirectory(in: base).standardizedFileURL, current.standardizedFileURL)
        XCTAssertFalse(fileManager.fileExists(atPath: current.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacy.path))
    }

    func testLegacyFolderIsMovedWithItsFilesAndLinkedBack() throws {
        try fileManager.createDirectory(at: legacy.appendingPathComponent("Profiles"), withIntermediateDirectories: true)
        let patch = Data("{\"fixtures\":[]}".utf8)
        try patch.write(to: legacy.appendingPathComponent("patch.json"))
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("Profiles/mine.json"))

        let resolved = ConfigStore.resolveDirectory(in: base)

        XCTAssertEqual(resolved.standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("patch.json")), patch)
        XCTAssertTrue(fileManager.fileExists(atPath: current.appendingPathComponent("Profiles/mine.json").path))
        // The old path still leads to the same files, for an older build of the app.
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: legacy.path), "RAYS")
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("patch.json")), patch)
    }

    func testExistingNewFolderWinsAndLegacyFolderIsLeftAlone() throws {
        try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("patch.json"))

        XCTAssertEqual(ConfigStore.resolveDirectory(in: base).standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("patch.json")), Data("old".utf8))
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: legacy.path))
    }

    func testSecondLaunchAfterMigrationIsANoOp() throws {
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("midi.json"))
        _ = ConfigStore.resolveDirectory(in: base)

        XCTAssertEqual(ConfigStore.resolveDirectory(in: base).standardizedFileURL, current.standardizedFileURL)
        XCTAssertTrue(fileManager.fileExists(atPath: current.appendingPathComponent("midi.json").path))
    }

    func testStoreReadsMigratedFiles() throws {
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        var prefs = Preferences()
        prefs.master = 0.4
        try ConfigStore(directory: legacy).savePreferences(prefs)

        let store = ConfigStore(directory: ConfigStore.resolveDirectory(in: base))
        XCTAssertEqual(store.loadPreferences().master, 0.4)
    }
}
