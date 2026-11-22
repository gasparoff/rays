import XCTest

/// English is the source language; translations live in `Localization/<lang>.lproj` and are
/// copied into the app by `Scripts/build-app.sh`. A broken file or a lost placeholder would
/// show raw keys or crash `String(format:)`, so every translation is checked here.
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ language: String, _ name: String = "Localizable") throws -> [String: String] {
        let url = Self.root.appendingPathComponent("Localization/\(language).lproj/\(name).strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(url.lastPathComponent) must be a flat strings table")
    }

    /// Format placeholders in order of their argument, with `%1$@`-style positions resolved.
    static func placeholders(_ s: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?([-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA])|%%"#)
        var numbered: [(Int, String)] = []
        var next = 1
        for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard m.range(at: 2).location != NSNotFound, let spec = Range(m.range(at: 2), in: s) else { continue }
            let position = Range(m.range(at: 1), in: s).flatMap { Int(s[$0]) } ?? next
            next = position + 1
            numbered.append((position, String(s[spec])))
        }
        return numbered.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func testPlaceholderParsing() {
        XCTAssertEqual(Self.placeholders("%@ of %.1f, 100%%"), ["@", ".1f"])
        XCTAssertEqual(Self.placeholders("%2$@ prima di %1$@"), ["@", "@"])
        XCTAssertEqual(Self.placeholders("deck %d · %.1f BPM"), ["d", ".1f"])
    }

    func testItalianTranslationIsCompleteAndKeepsEveryPlaceholder() throws {
        let it = try table("it")
        XCTAssertGreaterThan(it.count, 500)
        for (key, value) in it {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "empty translation for \(key)")
            XCTAssertEqual(Self.placeholders(value), Self.placeholders(key), "placeholders differ for \(key)")
        }
    }

    func testEnglishTableAndInfoPlistStringsParse() throws {
        XCTAssertNoThrow(try table("en"))
        let info = try table("it", "InfoPlist")
        XCTAssertNotNil(info["NSLocalNetworkUsageDescription"])
    }
}
