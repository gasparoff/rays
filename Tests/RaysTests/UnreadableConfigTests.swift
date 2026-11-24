import RaysControl
import RaysEngine
import XCTest

/// A damaged `midi.json` or `preferences.json` used to load as defaults and be overwritten by the
/// next save, losing learned mappings and output settings without a word. It is now copied aside
/// and reported.
final class UnreadableConfigTests: XCTestCase {
    private var directory: URL!
    private var store: ConfigStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rays-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ConfigStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let damaged = Data("{\"bindings\": [ this is not JSON".utf8)

    func testMissingFilesLoadDefaultsWithoutAnIssue() {
        var issue: String?
        XCTAssertEqual(store.loadMIDIMap(issue: &issue), MIDIMap())
        XCTAssertNil(issue)
        XCTAssertEqual(store.loadPreferences(issue: &issue), Preferences())
        XCTAssertNil(issue)
    }

    func testValidFilesLoadWithoutAnIssue() throws {
        var map = MIDIMap()
        map.learnFromAllInputs = true
        try store.saveMIDIMap(map)
        var prefs = Preferences()
        prefs.master = 0.6
        try store.savePreferences(prefs)

        var issue: String?
        XCTAssertEqual(store.loadMIDIMap(issue: &issue), map)
        XCTAssertEqual(store.loadPreferences(issue: &issue), prefs)
        XCTAssertNil(issue)
        XCTAssertFalse(contents().contains { $0.contains(".unreadable") })
    }

    func testDamagedMIDIMapIsKeptAsideAndReported() throws {
        try damaged.write(to: store.midiURL)
        var issue: String?
        XCTAssertEqual(store.loadMIDIMap(issue: &issue), MIDIMap())
        let message = try XCTUnwrap(issue)
        XCTAssertTrue(message.contains("midi.json"))
        XCTAssertTrue(message.contains("midi.unreadable.json"))
        let copy = directory.appendingPathComponent("midi.unreadable.json")
        XCTAssertEqual(try Data(contentsOf: copy), damaged)

        // The next save replaces midi.json, but the damaged original survives.
        try store.saveMIDIMap(MIDIMap())
        XCTAssertEqual(try Data(contentsOf: copy), damaged)
    }

    func testDamagedPreferencesAreKeptAsideAndReported() throws {
        try damaged.write(to: store.preferencesURL)
        var issue: String?
        XCTAssertEqual(store.loadPreferences(issue: &issue), Preferences())
        XCTAssertTrue(try XCTUnwrap(issue).contains("preferences.unreadable.json"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("preferences.unreadable.json")), damaged)
    }

    func testAnEarlierCopyIsNeverOverwritten() throws {
        try damaged.write(to: store.midiURL)
        var issue: String?
        _ = store.loadMIDIMap(issue: &issue)
        let second = Data("second damage".utf8)
        try second.write(to: store.midiURL)
        _ = store.loadMIDIMap(issue: &issue)

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("midi.unreadable.json")), damaged)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("midi.unreadable-1.json")), second)
        XCTAssertTrue(try XCTUnwrap(issue).contains("midi.unreadable-1.json"))
    }

    func testPlainLoadersKeepTheirOldSignatureAndAlsoPreserve() throws {
        try damaged.write(to: store.midiURL)
        XCTAssertEqual(store.loadMIDIMap(), MIDIMap())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("midi.unreadable.json").path))
    }

    private func contents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }
}
