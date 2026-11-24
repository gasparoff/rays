import XCTest
@testable import RaysEngine

/// The language picker writes the per-app `AppleLanguages` entry that macOS reads at launch.
final class InterfaceLanguageTests: XCTestCase {
    private let suite = "io.github.gasparoff.rays.tests.language"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFollowsMacOSUntilALanguageIsChosen() {
        let language = InterfaceLanguage(defaults: defaults, domain: suite)
        // The system-wide list is visible through `object(forKey:)`; it is not a choice made in RAYS.
        XCTAssertNil(language.override)

        language.setOverride("it")
        XCTAssertEqual(language.override, "it")
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["it"])

        language.setOverride(nil)
        XCTAssertNil(language.override)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }

    func testKeyIsTheOneMacOSReads() {
        XCTAssertEqual(InterfaceLanguage.defaultsKey, "AppleLanguages")
    }

    func testAvailableLanguagesComeFromTheBundleAndAlwaysIncludeEnglish() {
        XCTAssertEqual(InterfaceLanguage.available(bundleLocalizations: []), ["en"])
        XCTAssertEqual(InterfaceLanguage.available(bundleLocalizations: ["it", "Base", "en"]), ["en", "it"])
        XCTAssertEqual(InterfaceLanguage.available(bundleLocalizations: ["it", "de"]), ["de", "en", "it"])
    }

    func testEveryShippedTranslationHasANameInItsOwnLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Localization").path)
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }
        XCTAssertTrue(folders.contains("it"))
        for code in folders {
            XCTAssertNotEqual(InterfaceLanguage.displayName(of: code), code, "no display name for \(code)")
        }
        XCTAssertEqual(InterfaceLanguage.displayName(of: "en"), "English")
        XCTAssertEqual(InterfaceLanguage.displayName(of: "it"), "Italiano")
    }
}
