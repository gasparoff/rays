import XCTest
import LinkBridge

final class LinkBridgeTests: XCTestCase {
    /// Checks that the real Ableton Link SDK is compiled and linked: creates an instance
    /// (not enabled, so no network traffic), reads the timeline and destroys it.
    func testRealLinkBridgeCapturesTimeline() throws {
        let link = try XCTUnwrap(ls_link_create(123))
        defer { ls_link_destroy(link) }
        XCTAssertFalse(ls_link_is_enabled(link))
        XCTAssertEqual(ls_link_num_peers(link), 0)
        let state = ls_link_capture(link, 4)
        XCTAssertEqual(state.tempo, 123, accuracy: 0.0001)
        XCTAssertTrue(state.beat.isFinite)
        XCTAssertGreaterThanOrEqual(state.phase, 0)
        XCTAssertLessThan(state.phase, 4)
        XCTAssertGreaterThan(state.hostTimeMicros, 0)

        ls_link_set_tempo(link, 97.5)
        XCTAssertEqual(ls_link_capture(link, 4).tempo, 97.5, accuracy: 0.0001)
        ls_link_set_tempo(link, 5000)
        // Generous deadline: under `swift test --parallel` the runner can be busy for a while.
        let deadline = Date().addingTimeInterval(2)
        while abs(ls_link_capture(link, 4).tempo - 999) > 0.0001 && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertEqual(ls_link_capture(link, 4).tempo, 999, accuracy: 0.0001, "tempo clamped to Link range")
    }

    /// External-clock bridging aligns phase; the session is isolated from live peers.
    func testFollowBeatAlignsTempoAndPhase() throws {
        let link = try XCTUnwrap(ls_link_create(120))
        defer { ls_link_destroy(link) }
        let before = Date()
        ls_link_follow_beat(link, 128, 2)
        let state = ls_link_capture(link, 4)
        // The phase keeps moving between the two calls: allow for the time actually elapsed,
        // so a busy test runner can't turn scheduling delay into a failure.
        let elapsedBeats = Date().timeIntervalSince(before) * 128 / 60
        XCTAssertEqual(state.tempo, 128, accuracy: 0.0001)
        XCTAssertEqual(state.phase, 2, accuracy: 0.05 + elapsedBeats)
        ls_link_follow_beat(link, 128, 7)  // invalid beat-in-bar is ignored
        XCTAssertEqual(ls_link_capture(link, 4).tempo, 128, accuracy: 0.0001)
    }
    func testInvalidExternalTempoCannotPoisonTimeline() throws {
        let link = try XCTUnwrap(ls_link_create(.nan))
        defer { ls_link_destroy(link) }
        XCTAssertEqual(ls_link_capture(link, 4).tempo, 120, accuracy: 0.001)
        ls_link_set_tempo(link, .nan)
        ls_link_follow_beat(link, .infinity, 1)
        XCTAssertEqual(ls_link_capture(link, 4).tempo, 120, accuracy: 0.001)
        XCTAssertTrue(ls_link_capture(link, 4).phase.isFinite)
    }

}
