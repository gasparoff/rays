import XCTest
@testable import RaysTempo

final class BeatLinkEventTests: XCTestCase {
    private func line(_ extra: String = "", deck: Int = 2, master: Bool = true, playing: Bool = true, timestamp: Double = 1000) -> String {
        "LSBLT {\"type\":\"beat\",\"timestamp\":\(timestamp),\"deck\":\(deck),\"name\":\"XDJ-XZ\",\"bpm\":128.5,\"beat\":1,\"master\":\(master),\"playing\":\(playing)\(extra)}"
    }
    func testAutomaticMasterAndExplicitDeck() throws {
        let master = try XCTUnwrap(BeatLinkEvent.parse(line()))
        XCTAssertEqual(master.acceptedBeat(now: 1000.01)?.bpm, 128.5)
        XCTAssertEqual(master.acceptedBeat(now: 1000.01)?.deck, 2)
        XCTAssertNil(master.acceptedBeat(deck: 1, now: 1000.01))
        let slave = try XCTUnwrap(BeatLinkEvent.parse(line(master: false)))
        XCTAssertNil(slave.acceptedBeat(now: 1000.01))
        XCTAssertNotNil(slave.acceptedBeat(deck: 2, now: 1000.01))
    }
    func testStoppedStaleMixerAndMalformedCannotChangeTempo() throws {
        XCTAssertNil(BeatLinkEvent.parse("log: " + line()))
        XCTAssertNil(BeatLinkEvent.parse("LSBLT {}"))
        XCTAssertNil(try XCTUnwrap(BeatLinkEvent.parse(line(playing: false))).acceptedBeat(now: 1000.01))
        XCTAssertNil(try XCTUnwrap(BeatLinkEvent.parse(line(deck: 33))).acceptedBeat(now: 1000.01))
        let b = try XCTUnwrap(BeatLinkEvent.parse(line()))
        XCTAssertNil(b.acceptedBeat(now: 1000.5))
        XCTAssertNil(b.acceptedBeat(now: 999))
        for field in ["bpm", "beat", "deck", "playing", "master"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line().dropFirst(6).utf8)) as? [String: Any])
            object.removeValue(forKey: field)
            let text = "LSBLT " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            XCTAssertNil(try XCTUnwrap(BeatLinkEvent.parse(text)).acceptedBeat(now: 1000.01), field)
        }
    }
}
