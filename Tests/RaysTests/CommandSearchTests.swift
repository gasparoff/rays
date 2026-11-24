import XCTest
@testable import RaysEngine

final class CommandSearchTests: XCTestCase {
    private let titles = ["Play Amber", "Play Sunset", "Blackout", "Turn lights on", "Layout preset: Big stage", "Open Setup", "Play Drop"]

    private func rank(_ q: String) -> [String] { CommandSearch.rank(titles, query: q) { $0 } }

    func testEmptyQueryKeepsTheOriginalOrder() {
        XCTAssertEqual(rank(""), titles)
        XCTAssertEqual(rank("   "), titles)
    }

    func testTitleStartBeatsWordStartBeatsAnywhere() {
        XCTAssertEqual(rank("s"), ["Play Sunset", "Layout preset: Big stage", "Open Setup", "Turn lights on"])
        XCTAssertEqual(rank("bl").first, "Blackout")
    }

    func testEveryWordMustMatchIgnoringCaseAndAccents() {
        XCTAssertEqual(rank("play d"), ["Play Drop"])
        XCTAssertEqual(rank("LIGHTS ON"), ["Turn lights on"])
        XCTAssertEqual(CommandSearch.rank(["Attiva luci", "Velocità"], query: "velocita") { $0 }, ["Velocità"])
        XCTAssertEqual(rank("strobe"), [])
    }

    func testTiesKeepTheCallersOrder() {
        XCTAssertEqual(rank("play"), ["Play Amber", "Play Sunset", "Play Drop"])
    }
}
