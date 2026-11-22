import XCTest
@testable import RaysCore
@testable import RaysControl

/// Ports routed by a JSON ControllerProfile (non-K2).
final class ProfileRoutingTests: XCTestCase {
    private let pad = ControllerProfile(
        id: "test.padbox", name: "PadBox", manufacturer: "Test", portNamePattern: "padbox", midiChannel: 2,
        bindings: [.init(.master, .cc, 7), .init(.energy, .cc, 1), .init(.scene1, .note, 36), .init(.accent, .note, 44)],
        relativeEncoders: [1], encoderResolution: 50,
        leds: .init(notes: .init(from: 36, to: 51), colors: .init(red: 0, amber: 16, green: 32), special: nil),
        notes: "test")

    private func note(_ n: UInt8, on: Bool = true, ch: UInt8 = 1) -> MIDIEvent {
        MIDIEvent(control: .init(.note, channel: ch, number: n), value: on ? 127 : 0, isNoteOn: on)
    }
    private func cc(_ n: UInt8, _ v: UInt8, ch: UInt8 = 1) -> MIDIEvent {
        MIDIEvent(control: .init(.cc, channel: ch, number: n), value: v, isNoteOn: false)
    }

    func testProfileBindingsDriveActionsOnTheProfileChannelOnly() {
        var r = MIDIRouter()
        XCTAssertEqual(r.handle(note(36), profile: pad), .command(.scene(SceneID.allCases[0])))
        XCTAssertEqual(r.handle(note(36, on: false), profile: pad), .none)
        XCTAssertEqual(r.handle(note(36, ch: 0), profile: pad), .none, "wrong channel")
        XCTAssertEqual(r.handle(note(44), profile: pad), .command(.accent(true)))
        XCTAssertEqual(r.handle(note(44, on: false), profile: pad), .command(.accent(false)))
        XCTAssertEqual(r.handle(note(36)), .none, "without a profile only learned bindings act")
    }

    func testAbsoluteFaderUsesSoftTakeoverAndEncoderUsesProfileResolution() {
        var r = MIDIRouter()
        XCTAssertEqual(r.handle(cc(7, 127), profile: pad, current: { _ in 0 }), .waiting(.master, 1))
        XCTAssertEqual(r.handle(cc(7, 0), profile: pad, current: { _ in 0 }), .command(.master(0)))
        XCTAssertEqual(r.handle(cc(1, 1), profile: pad, current: { _ in 0.5 }), .command(.energy(0.5 + 1.0 / 50)))
        XCTAssertEqual(r.handle(cc(1, 127), profile: pad, current: { _ in 0.5 }), .command(.energy(0.5 - 1.0 / 50)))
    }

    func testLearnedBindingsWinAndRelearnedActionsLeaveTheLayout() {
        var r = MIDIRouter()
        r.map.bind(.blackout, to: .init(.note, channel: 1, number: 36))
        XCTAssertEqual(r.handle(note(36), profile: pad), .command(.toggleBlackout))
        r.map.bind(.accent, to: .init(.note, channel: 5, number: 1))
        XCTAssertEqual(r.handle(note(44), profile: pad), .none, "accent moved elsewhere")
    }

    func testLearnOnAProfileEncoderIsRelativeAndButtonsNeverLearnFromIt() {
        var r = MIDIRouter()
        r.learning = .scene2
        XCTAssertEqual(r.handle(cc(1, 1), profile: pad), .none)
        r.learning = .levelLeft
        XCTAssertEqual(r.handle(cc(1, 1), profile: pad), .learned(.levelLeft, .init(.cc, channel: 1, number: 1)))
        XCTAssertEqual(r.map.binding(for: .init(.cc, channel: 1, number: 1))?.relative, true)
    }

    func testK2PortsIgnoreAnyProfileArgument() {
        var a = MIDIRouter(), b = MIDIRouter()
        let e = MIDIEvent(control: .init(.note, channel: 14, number: 36), value: 127, isNoteOn: true)
        XCTAssertEqual(a.handle(e, fromK2: true), b.handle(e, fromK2: true, profile: pad))
    }

    func testProfileLEDsFollowTheK2ColourRulesAndLearnedOverrides() {
        var map = MIDIMap()
        var s = K2FeedbackState(scene: SceneID.allCases[0])
        s.live = true
        var leds = K2Feedback.leds(map: map, profile: pad, state: s)
        XCTAssertEqual(leds[36], .green)
        XCTAssertEqual(leds[44], .off)
        XCTAssertNil(leds[7], "CCs have no LED")
        map.bind(.scene1, to: .init(.note, channel: 1, number: 40))
        leds = K2Feedback.leds(map: map, profile: pad, state: s)
        XCTAssertNil(leds[36])
        XCTAssertEqual(leds[40], .green)
        map.bind(.scene1, to: .init(.note, channel: 9, number: 40))
        XCTAssertNil(K2Feedback.leds(map: map, profile: pad, state: s)[40], "learned on another channel")
        XCTAssertEqual(pad.leds?.addresses(base: 40), [40, 56, 72])
        var noLEDs = pad; noLEDs.leds = nil
        XCTAssertEqual(K2Feedback.leds(map: MIDIMap(), profile: noLEDs, state: s), [:])
    }

    func testLearnFromAllInputsIsOffByDefaultAndOldFilesStillLoad() throws {
        XCTAssertFalse(MIDIMap().learnFromAllInputs)
        let old = #"{"bindings":[],"k2Preset":true,"k2Layout":"liveV2"}"#
        let map = try JSONDecoder().decode(MIDIMap.self, from: Data(old.utf8))
        XCTAssertFalse(map.learnFromAllInputs)
        XCTAssertEqual(map.k2Layout, .liveV2)
        var on = MIDIMap(); on.learnFromAllInputs = true
        XCTAssertTrue(try JSONDecoder().decode(MIDIMap.self, from: JSONEncoder().encode(on)).learnFromAllInputs)
    }
}
