import XCTest
@testable import RaysCore
@testable import RaysControl

final class XoneLiveLayoutTests: XCTestCase {
    private func note(_ n: UInt8, _ on: Bool = true) -> MIDIEvent {
        .init(control: .init(.note, channel: 14, number: n), value: on ? 127 : 0, isNoteOn: on)
    }
    private func cc(_ n: UInt8, _ value: UInt8) -> MIDIEvent {
        .init(control: .init(.cc, channel: 14, number: n), value: value, isNoteOn: false)
    }
    private var liveMap: MIDIMap { var map = MIDIMap(); map.k2Layout = .liveV2; return map }

    func testOldFilesKeepClassicAndNewLayoutRoundTripsWithoutLosingLearnedBindings() throws {
        let old = Data(#"{"k2Preset":true,"bindings":[{"action":"accent","control":{"kind":"note","channel":14,"number":50}}]}"#.utf8)
        var map = try JSONDecoder().decode(MIDIMap.self, from: old)
        XCTAssertEqual(map.k2Layout, .classic)
        XCTAssertEqual(map.k2Control(for: .stop, channel: 14)?.number, 39)
        let bindings = map.bindings
        map.k2Layout = .liveV2
        let loaded = try JSONDecoder().decode(MIDIMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(loaded.k2Layout, .liveV2)
        XCTAssertEqual(loaded.bindings, bindings)
        XCTAssertEqual(loaded.k2Control(for: .accent, channel: 14)?.number, 50)
        XCTAssertEqual(loaded.k2Control(for: .stop, channel: 14)?.number, 27)
        XCTAssertEqual(ControlAction.accent.rawValue, "accent")
        XCTAssertEqual(ControlAction.accentLevel.rawValue, "accentLevel")
    }

    func testPhysicalRateRowMatchesTheSlowToFastScreenOrder() {
        XCTAssertEqual(Subdivision.rateOrder.map(\.rate), [0.25, 0.5, 1, 2])
        XCTAssertEqual(Subdivision.rateOrder.map(\.label), ["¼×", "½×", "1×", "2×"])
        var router = MIDIRouter(map: liveMap)
        for (noteNumber, rate) in zip(UInt8(28)...31, Subdivision.rateOrder) {
            XCTAssertEqual(router.handle(note(noteNumber), fromK2: true), .command(.rate(rate)))
            XCTAssertEqual(router.handle(note(noteNumber, false), fromK2: true), .none)
        }
    }

    func testNewButtonsAreEdgeTriggeredAndFirstBeatIsItsOwnSceneCommand() {
        var router = MIDIRouter(map: liveMap)
        for (number, command): (UInt8, MIDICommand) in [(39, .bank(.house)), (35, .bank(.club)),
                                                       (25, .sceneFirstBeat), (26, .cancelPending),
                                                       (27, .stop), (15, .toggleBlackout)] {
            XCTAssertEqual(router.handle(note(number), fromK2: true), .command(command))
            XCTAssertEqual(router.handle(note(number), fromK2: true), .none)
            XCTAssertEqual(router.handle(note(number, false), fromK2: true), .none)
        }
        XCTAssertEqual(router.handle(note(12, false), fromK2: true), .none)
        XCTAssertEqual(router.handle(note(12), fromK2: true), .command(.buildHold(true)))
        XCTAssertEqual(router.handle(note(12), fromK2: true), .none)
        XCTAssertEqual(router.handle(note(12, false), fromK2: true), .command(.buildHold(false)))
        XCTAssertEqual(router.handle(note(24), fromK2: true), .command(.accent(true)))
        XCTAssertEqual(router.handle(note(24, false), fromK2: true), .command(.accent(false)))
    }

    func testLiveEncodersUseSignedDeltasAndFadersRetainPickup() {
        var router = MIDIRouter(map: liveMap)
        XCTAssertEqual(router.handle(cc(20, 1), fromK2: true, current: { _ in 0.5 }), .command(.energy(0.5 + 1.0 / 127)))
        XCTAssertEqual(router.handle(cc(21, 127), fromK2: true, current: { _ in 0.5 }), .command(.accentLevel(0.5 - 1.0 / 127)))
        XCTAssertEqual(router.handle(cc(20, 64), fromK2: true), .none)
        XCTAssertEqual(router.handle(cc(21, 0), fromK2: true), .none)
        XCTAssertEqual(router.handle(cc(19, 0), fromK2: true, current: { _ in 0.8 }), .waiting(.master, 0))
        XCTAssertEqual(router.handle(cc(19, 127), fromK2: true, current: { _ in 0.8 }), .command(.master(1)))
    }

    func testLearnedControlWinsAndItsLEDDoesNotGetOverwrittenByPreset() {
        var map = liveMap
        map.bind(.blackout, to: .init(.note, channel: 14, number: 39))
        XCTAssertNil(map.k2Control(for: .bankHouse, channel: 14))
        XCTAssertEqual(map.k2Control(for: .blackout, channel: 14)?.number, 39)
        var state = K2FeedbackState(scene: .pulse); state.blackout = true
        XCTAssertEqual(K2Feedback.leds(map: map, channel: 14, state: state)[39], .red)
        var router = MIDIRouter(map: map)
        XCTAssertEqual(router.handle(note(39), fromK2: true), .command(.toggleBlackout))
        XCTAssertEqual(router.handle(note(15), fromK2: true), .none, "Relearned action no longer fires on its preset control")
        map.bind(.accent, to: .init(.note, channel: 2, number: 50))
        XCTAssertNil(K2Feedback.leds(map: map, channel: 14, state: state)[50], "Do not send LEDs to a different MIDI channel")
    }

    func testBottomLEDAddressesAreNotMatrixOffsets() {
        XCTAssertEqual(XoneK2.ledAddresses(base: 12), [12, 16, 20])
        XCTAssertEqual(XoneK2.ledAddresses(base: 15), [15, 19, 23])
        XCTAssertEqual(XoneK2.LED.amber.note(base: 12), 16)
        XCTAssertEqual(XoneK2.LED.green.note(base: 15), 23)
        XCTAssertEqual(XoneK2.ledAddresses(base: 24), [24, 60, 96])
        XCTAssertNil(XoneK2.LED.green.note(base: 127))
    }

    func testBankAndPendingFeedbackDistinguishBrowsingFromActualOutput() {
        var state = K2FeedbackState(scene: .pulse)
        state.live = true; state.playingBank = .house; state.selectedBank = .club
        state.sceneInBank = false; state.pendingScene = .chase; state.pendingSceneInBank = true; state.blinkOn = true
        XCTAssertEqual(K2Feedback.color(.bankHouse, state), .green)
        XCTAssertEqual(K2Feedback.color(.bankClub, state), .amber)
        XCTAssertEqual(K2Feedback.color(.scene3, state), .off)
        XCTAssertEqual(K2Feedback.color(.scene4, state), .amber)
        XCTAssertEqual(K2Feedback.color(.cancelPending, state), .amber)
        state.live = false; state.accent = true
        XCTAssertEqual(K2Feedback.color(.accent, state), .amber, "Preview Flash is not a live green LED")
        state.stopped = true
        XCTAssertEqual(K2Feedback.color(.bankHouse, state), .off)
    }

    func testCancelPendingPreservesPlayingLookPhaseAndFades() throws {
        var current = CustomScene(presetSlot: .pulse, base: .pulse)
        current.name = "Playing"
        var queued = current; queued.id = UUID(); queued.presetBank = .club
        var sequence = SceneSequencer(scene: .pulse)
        sequence.setLook(SceneLook(current))
        sequence.advance(beat: 0.2, bpm: 120, now: 0.1, gridTrusted: true)
        let before = sequence
        sequence.request(.pulse, look: SceneLook(queued), beat: 0.2, now: 0.1, gridTrusted: true)
        XCTAssertEqual(sequence.pendingSceneBank, .club)
        XCTAssertTrue(sequence.cancelPendingScene())
        XCTAssertNil(sequence.pendingScene)
        XCTAssertEqual(sequence.look?.source.id, current.id)
        XCTAssertEqual(sequence.currentSceneBeatAnchor, before.currentSceneBeatAnchor)
        XCTAssertEqual(sequence.render(beat: 0.3, energy: 0.5, now: 0.15), before.render(beat: 0.3, energy: 0.5, now: 0.15))
        XCTAssertFalse(sequence.cancelPendingScene())
        sequence.advance(beat: 8, bpm: 120, now: 4, gridTrusted: true)
        XCTAssertEqual(sequence.currentSceneLook?.id, current.id)
        sequence.stop(beat: 8, now: 4, gridTrusted: true)
        XCTAssertFalse(sequence.cancelPendingScene())
        XCTAssertTrue(sequence.isStopped)
        XCTAssertTrue(sequence.isStopFading(beat: 8.2, now: 4.1))
    }

    func testCancelAfterTheQueuedLaunchHasStartedDoesNotUndoTheLaunch() {
        var sequence = SceneSequencer(scene: .ambra)
        sequence.advance(beat: 0.2, bpm: 120, now: 0.1, gridTrusted: true)
        sequence.request(.chase, beat: 0.2, now: 0.1, gridTrusted: true)
        sequence.advance(beat: 1.1, bpm: 120, now: 0.55, gridTrusted: true)
        XCTAssertNil(sequence.pendingScene)
        XCTAssertFalse(sequence.cancelPendingScene())
        XCTAssertEqual(sequence.targetScene, .chase)
    }
}
