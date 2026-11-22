import XCTest
@testable import RaysTempo

final class ProDJBeatTests: XCTestCase {
    func packet() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 96)
        bytes.replaceSubrange(0..<10, with: [0x51,0x73,0x70,0x74,0x31,0x57,0x6d,0x4a,0x4f,0x4c])
        bytes[10] = 0x28
        bytes.replaceSubrange(11..<17, with: Array("XDJ-XZ".utf8))
        bytes[0x1f] = 1; bytes[0x21] = 1; bytes[0x23] = 0x3c
        bytes[0x55] = 0x10 // neutral pitch is 0x100000 at offsets55..57
        bytes[0x5a] = 0x30; bytes[0x5b] = 0xd4 // 12500 = 125.00 BPM
        bytes[0x5c] = 3
        return bytes
    }

    func testRealDocumentedOffsetsAndPitch() throws {
        let beat = try XCTUnwrap(ProDJBeat.parse(packet()))
        XCTAssertEqual(beat.deviceName, "XDJ-XZ")
        XCTAssertEqual(beat.deck, 1)
        XCTAssertEqual(beat.bpm, 125, accuracy: 0.001)
        XCTAssertEqual(beat.beatWithinBar, 3)
        var raised = packet()
        raised[0x55] = 0x11 // +6.25%, not the adjacent undocumented byte54
        XCTAssertEqual(try XCTUnwrap(ProDJBeat.parse(raised)).bpm, 132.8125, accuracy: 0.00001)
    }

    func testMalformedAndNonPlayerPacketsAreRejected() {
        for count in 0..<96 { XCTAssertNil(ProDJBeat.parse(Array(packet().prefix(count)))) }
        for offset in [0, 10, 0x1f, 0x20, 0x21, 0x23, 0x55, 0x5c] {
            var corrupt = packet()
            corrupt[offset] = 0xff
            XCTAssertNil(ProDJBeat.parse(corrupt), "Invalid byte at \(offset)")
        }
        var mixer = packet(); mixer[0x21] = 0x21
        XCTAssertNil(ProDJBeat.parse(mixer), "Mixer beats have no reliable downbeat")
        var sentinel = packet(); sentinel[0x5a] = 0xff; sentinel[0x5b] = 0xff
        XCTAssertNil(ProDJBeat.parse(sentinel))
    }
}
