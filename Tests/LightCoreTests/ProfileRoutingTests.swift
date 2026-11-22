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
        func n(_ x: UInt8, ch: UInt8 = 1) -> MIDIControl { MIDIControl(.note, channel: ch, number: x) }
        var map = MIDIMap()
        var s = K2FeedbackState(scene: SceneID.allCases[0])
        s.live = true
        var leds = K2Feedback.leds(map: map, profile: pad, state: s)
        XCTAssertEqual(leds[n(36)], .green)
        XCTAssertEqual(leds[n(44)], .off)
        XCTAssertNil(leds[MIDIControl(.cc, channel: 1, number: 7)], "CCs have no LED")
        map.bind(.scene1, to: .init(.note, channel: 1, number: 40))
        leds = K2Feedback.leds(map: map, profile: pad, state: s)
        XCTAssertNil(leds[n(36)])
        XCTAssertEqual(leds[n(40)], .green)
        map.bind(.scene1, to: .init(.note, channel: 9, number: 40))
        XCTAssertNil(K2Feedback.leds(map: map, profile: pad, state: s)[n(40)], "learned on another channel")
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

    func testPerBindingChannelsAndVelocityLEDs() {
        let apc = ControllerProfile(
            id: "test.apc", name: "APC", manufacturer: "Test", portNamePattern: "apc", midiChannel: 1,
            bindings: [.init(.levelLeft, .cc, 7, channel: 1), .init(.levelCenter, .cc, 7, channel: 2),
                       .init(.scene1, .note, 0), .init(.stop, .note, 81), .init(.rateHalf, .note, 82)],
            relativeEncoders: [13], encoderResolution: nil,
            leds: .init(style: .velocity, notes: .init(from: 0, to: 39), extraNotes: [82, 83],
                        colors: .init(red: 5, amber: 9, green: 21)),
            notes: "test")
        XCTAssertEqual(apc.problems, [])
        var r = MIDIRouter()
        XCTAssertEqual(r.handle(MIDIEvent(control: .init(.cc, channel: 1, number: 7), value: 0, isNoteOn: false), profile: apc,
                                current: { _ in 0 }), .command(.level(.center, 0)))
        XCTAssertEqual(r.handle(MIDIEvent(control: .init(.cc, channel: 0, number: 7), value: 0, isNoteOn: false), profile: apc,
                                current: { _ in 0 }), .command(.level(.left, 0)))
        XCTAssertEqual(r.handle(MIDIEvent(control: .init(.cc, channel: 2, number: 7), value: 0, isNoteOn: false), profile: apc), .none)
        XCTAssertTrue(apc.isRelativeEncoder(.init(.cc, channel: 1, number: 13)))
        XCTAssertFalse(apc.isRelativeEncoder(.init(.cc, channel: 5, number: 13)))

        let leds = apc.leds!
        XCTAssertTrue(leds.hasLED(base: 0)); XCTAssertTrue(leds.hasLED(base: 82)); XCTAssertFalse(leds.hasLED(base: 81))
        XCTAssertEqual(leds.onMessage(base: 0, color: .green).map { [$0.note, $0.velocity] }, [0, 21])
        XCTAssertEqual(leds.onMessage(base: 82, color: .red).map { [$0.note, $0.velocity] }, [82, 5])
        XCTAssertNil(leds.onMessage(base: 0, color: .off))
        XCTAssertEqual(leds.offNotes(base: 0), [0])
        XCTAssertEqual(leds.addresses(base: 0), [], "offset addressing does not apply")
        var s = K2FeedbackState(scene: SceneID.allCases[0])
        s.live = true; s.subdivision = .two
        let out = K2Feedback.leds(map: MIDIMap(), profile: apc, state: s)
        XCTAssertEqual(out[.init(.note, channel: 0, number: 0)], .green)
        XCTAssertEqual(out[.init(.note, channel: 0, number: 82)], .green)
        XCTAssertNil(out[.init(.note, channel: 0, number: 81)], "STOP has no LED")

        var bad = apc
        bad.bindings.append(.init(.master, .cc, 7, channel: 2))
        bad.bindings.append(.init(.energy, .cc, 9, channel: 17))
        XCTAssertTrue(bad.problems.contains { $0.contains("cc 7 on channel 2 is bound twice") }, "\(bad.problems)")
        XCTAssertTrue(bad.problems.contains { $0.contains("channel 17") })
        let k2 = XoneK2.classicProfile.leds!
        XCTAssertEqual(k2.onMessage(base: 24, color: .amber).map { [$0.note, $0.velocity] }, [60, 127])
        XCTAssertEqual(k2.offNotes(base: 24), [24, 60, 96])
    }
}

