import XCTest
@testable import RaysTempo
@testable import RaysEngine

/// Text as OSC puts it on the wire, without the zero bytes that end and pad it.
private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

/// The parts of a packet one after the other. A function, because long chains of `+` on array
/// literals take the compiler too long to type-check.
private func bytes(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

final class OSCMessageTests: XCTestCase {
    /// `/beat 1 3 128.0` as openDJ puts it on the wire.
    private static let beat = bytes(
        ascii("/beat"), [0, 0, 0], ascii(",iif"), [0, 0, 0, 0], [0, 0, 0, 1], [0, 0, 0, 3], [0x43, 0, 0, 0])
    private static let bundleHeader = bytes(ascii("#bundle"), [0], [0, 0, 0, 0, 0, 0, 0, 1])

    private static func element(_ element: [UInt8]) -> [UInt8] {
        bytes([0, 0, UInt8(element.count >> 8), UInt8(element.count & 0xFF)], element)
    }

    func testEncodingPadsEveryPartToFourBytes() {
        let subscribe = OSCMessage("/subscribe", [.string("/beat")]).encoded()
        XCTAssertEqual(Array(subscribe), bytes(ascii("/subscribe"), [0, 0], ascii(",s"), [0, 0], ascii("/beat"), [0, 0, 0]))
        XCTAssertEqual(Array(OSCMessage("/beat", [.int(1), .int(3), .float(128)]).encoded()), Self.beat)
        // A string whose length is a multiple of four still ends with four zero bytes.
        XCTAssertEqual(Array(OSCMessage("/abc").encoded()), bytes(ascii("/abc"), [0, 0, 0, 0], [0x2C, 0, 0, 0]))
    }

    func testDecodingMessagesAndNestedBundles() {
        let beat = OSCMessage("/beat", [.int(1), .int(3), .float(128)])
        XCTAssertEqual(OSCMessage.decode(Data(Self.beat)), [beat])
        let phrase = OSCMessage("/phrase", [.string("Drop"), .int(16)])
        let inner = bytes(Self.bundleHeader, Self.element(Array(phrase.encoded())))
        let outer = bytes(Self.bundleHeader, Self.element(Self.beat), Self.element(inner))
        XCTAssertEqual(OSCMessage.decode(Data(outer)), [beat, phrase])
        XCTAssertEqual(OSCMessage.decode(OSCMessage.bundle([phrase, beat])), [phrase, beat])
        // A slice of a larger buffer decodes like its own data.
        let padded = Data(bytes([9, 9, 9], Self.beat))
        XCTAssertEqual(OSCMessage.decode(padded.dropFirst(3)), [beat])
    }

    func testMalformedPacketsDecodeToNothing() {
        XCTAssertEqual(OSCMessage.decode(Data()), [])
        XCTAssertEqual(OSCMessage.decode(Data("hello".utf8)), [])
        XCTAssertEqual(OSCMessage.decode(Data(Self.beat.dropLast(2))), [], "argument cut short")
        XCTAssertEqual(OSCMessage.decode(Data(bytes(ascii("/beat"), [0, 0, 0]))), [], "no type tags")
        let unterminated = bytes(ascii("/beat"), [0, 0, 0], ascii(",s"), [0, 0], ascii("Drop"))
        XCTAssertEqual(OSCMessage.decode(Data(unterminated)), [])
        let blob = bytes(ascii("/x"), [0, 0], ascii(",b"), [0, 0], [0, 0, 0, 0])
        XCTAssertEqual(OSCMessage.decode(Data(blob)), [], "argument types RAYS doesn't read")
        let tooLong = bytes(Self.bundleHeader, [0, 0, 0, 200], Self.beat)
        XCTAssertEqual(OSCMessage.decode(Data(tooLong)), [], "element longer than the packet")
        let negative = bytes(Self.bundleHeader, [0xFF, 0xFF, 0xFF, 0xF0], Self.beat)
        XCTAssertEqual(OSCMessage.decode(Data(negative)), [], "negative element size")
        var nested = Self.beat
        for _ in 0..<20 { nested = bytes(Self.bundleHeader, Self.element(nested)) }
        XCTAssertEqual(OSCMessage.decode(Data(nested)), [], "bundles nested too deep")
    }
}

final class OpenDJEventTests: XCTestCase {
    func testEventsFromOpenDJMessages() {
        XCTAssertEqual(
            OpenDJEvent(OSCMessage("/beat", [.int(4), .int(7), .float(126.5)])),
            .beat(beatInBar: 4, barInPhrase: 7, bpm: 126.5))
        XCTAssertEqual(OpenDJEvent(OSCMessage("/phrase", [.string("Drop"), .int(16)])), .phrase(name: "Drop", bars: 16))
        // Before a track's first bar openDJ counts bar 0.
        XCTAssertEqual(
            OpenDJEvent(OSCMessage("/beat", [.int(1), .int(0), .float(100)])),
            .beat(beatInBar: 1, barInPhrase: 0, bpm: 100))
    }

    func testAnythingElseIsNotAnEvent() {
        XCTAssertNil(OpenDJEvent(OSCMessage("/master/crossfader", [.float(0)])))
        XCTAssertNil(OpenDJEvent(OSCMessage("/beat", [.int(5), .int(1), .float(120)])), "beat outside the bar")
        XCTAssertNil(OpenDJEvent(OSCMessage("/beat", [.int(0), .int(1), .float(120)])))
        XCTAssertNil(OpenDJEvent(OSCMessage("/beat", [.int(1), .int(-1), .float(120)])))
        XCTAssertNil(OpenDJEvent(OSCMessage("/beat", [.int(1), .int(1), .float(.nan)])))
        XCTAssertNil(OpenDJEvent(OSCMessage("/beat", [.int(1), .int(1), .float(0)])), "a stopped deck has no tempo")
        XCTAssertNil(OpenDJEvent(OSCMessage("/beat", [.int(1), .int(1)])))
        XCTAssertNil(OpenDJEvent(OSCMessage("/beat", [.float(1), .int(1), .float(120)])))
        XCTAssertNil(OpenDJEvent(OSCMessage("/phrase", [.int(16), .string("Drop")])))
    }

    func testSubscriptionReplacesItselfAndAsksOpenDJToAnswer() {
        // Unsubscribing first keeps openDJ's list of patterns from growing with every renewal.
        XCTAssertEqual(
            OSCMessage.decode(OpenDJEvent.subscription),
            [
                OSCMessage("/unsubscribe", [.string("/beat"), .string("/phrase")]),
                OSCMessage("/subscribe", [.string("/beat"), .string("/phrase")]),
                OSCMessage("/master/crossfader"),
            ])
        XCTAssertEqual(OpenDJEvent.defaultPort, 9000)
    }
}

final class OpenDJTimelineTests: XCTestCase {
    private func beat(_ beat: Int, bar: Int, bpm: Double = 128) -> OpenDJEvent {
        .beat(beatInBar: beat, barInPhrase: bar, bpm: bpm)
    }

    func testFollowsBeatsAndKeepsThePhraseWhileTheCountContinues() {
        var t = OpenDJTimeline()
        XCTAssertNil(t.bpm)
        t.apply(beat(1, bar: 1))
        t.apply(.phrase(name: "Build", bars: 8))
        XCTAssertEqual(t.phrase, "Build")
        for (b, bar) in [(2, 1), (3, 1), (4, 1), (1, 2), (2, 2)] { t.apply(beat(b, bar: bar, bpm: 128.5)) }
        XCTAssertEqual(t.bpm, 128.5)
        XCTAssertEqual(t.beatInBar, 2)
        XCTAssertEqual(t.barInPhrase, 2)
        XCTAssertEqual(t.phrase, "Build")
        // openDJ can skip one beat when its check runs late.
        t.apply(beat(4, bar: 2))
        XCTAssertEqual(t.phrase, "Build")
    }

    func testPhraseIsForgottenWhenANewOneStartsOrTheCountJumps() {
        var t = OpenDJTimeline()
        t.apply(beat(3, bar: 8))
        t.apply(.phrase(name: "Build", bars: 8))
        t.apply(beat(4, bar: 8))
        XCTAssertEqual(t.phrase, "Build")
        t.apply(beat(1, bar: 1))
        XCTAssertNil(t.phrase, "the next phrase is named by the /phrase that follows its first beat")
        t.apply(.phrase(name: "Drop", bars: 16))
        t.apply(beat(2, bar: 1))
        XCTAssertEqual(t.phrase, "Drop")
        t.apply(beat(3, bar: 5))
        XCTAssertNil(t.phrase, "a jump or another master deck")
        t.apply(.phrase(name: "Outro", bars: 8))
        t.apply(beat(3, bar: 5))
        XCTAssertNil(t.phrase, "the same beat again is not the count continuing")
    }
}

final class BarAgreementTests: XCTestCase {
    private func snapshot(phase: Double, bpm: Double = 128) -> TempoSnapshot {
        TempoSnapshot(bpm: bpm, beat: 40 + phase, phase: phase)
    }

    func testOffsetFromABeatOfTheBarWrapsAroundTheBar() {
        XCTAssertEqual(snapshot(phase: 0.02).offset(fromBeatInBar: 1), 0.02, accuracy: 1e-9)
        XCTAssertEqual(snapshot(phase: 3.98).offset(fromBeatInBar: 1), -0.02, accuracy: 1e-9)
        XCTAssertEqual(snapshot(phase: 2.5).offset(fromBeatInBar: 3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot(phase: 0).offset(fromBeatInBar: 4), 1, accuracy: 1e-9)
        XCTAssertEqual(snapshot(phase: 1).offset(fromBeatInBar: 4), -2, accuracy: 1e-9)
    }

    func testAgreesOnlyWhenTempoAndBarBothMatch() {
        XCTAssertTrue(snapshot(phase: 1.03).agrees(bpm: 128, beatInBar: 2, tolerance: 0.05))
        XCTAssertTrue(snapshot(phase: 3.97).agrees(bpm: 128.004, beatInBar: 1, tolerance: 0.05))
        XCTAssertFalse(snapshot(phase: 1.08).agrees(bpm: 128, beatInBar: 2, tolerance: 0.05), "late by more than the tolerance")
        XCTAssertFalse(snapshot(phase: 2.03).agrees(bpm: 128, beatInBar: 2, tolerance: 0.05), "a whole beat off")
        XCTAssertFalse(snapshot(phase: 1.03).agrees(bpm: 128.5, beatInBar: 2, tolerance: 0.05), "another tempo")
        XCTAssertFalse(snapshot(phase: 1).agrees(bpm: 128, beatInBar: 2, tolerance: 0), "no tolerance always realigns")
    }
}

final class OpenDJBeatSourceCompatibilityTests: XCTestCase {
    func testOpenDJIsOptInAndOlderPreferencesStillDecode() throws {
        XCTAssertFalse(BeatSource.openDJ.usesProDJLink)
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"beatSource":"openDJ"}"#.utf8))
        XCTAssertEqual(p.beatSource, .openDJ)
        let saved = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: saved).beatSource, .openDJ)
        for (old, expected) in [("auto", BeatSource.auto), ("link", .link), ("xdj", .xdj), ("midiClock", .midiClock)] {
            let decoded = try JSONDecoder().decode(Preferences.self, from: Data(#"{"beatSource":"\#(old)","xdjDeck":2}"#.utf8))
            XCTAssertEqual(decoded.beatSource, expected)
            XCTAssertEqual(decoded.xdjDeck, 2)
        }
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).beatSource, .auto)
    }
}
