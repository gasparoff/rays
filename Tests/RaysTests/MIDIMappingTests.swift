import XCTest
@testable import RaysCore
@testable import RaysControl
@testable import RaysEngine

final class MIDIMappingTests: XCTestCase {
    func testDecodesNotesCCsRunningStatusAndSkipsSysEx() {
        let events = MIDIDecoder.decode([0xF8, 0x92, 36, 100, 36, 0, 0xF0, 1, 2, 0xF7, 0xB1, 4, 127, 0x80, 5, 64])
        XCTAssertEqual(events.map(\.control), [.init(.note, channel: 2, number: 36), .init(.note, channel: 2, number: 36),
                                              .init(.cc, channel: 1, number: 4), .init(.note, channel: 0, number: 5)])
        XCTAssertEqual(events.map(\.isNoteOn), [true, false, false, false])
    }

    func testUnlearnedControlsDoNothing() {
        var router = MIDIRouter()
        XCTAssertEqual(router.handle(note(36, on: true)), .none)
        XCTAssertEqual(router.handle(cc(4, 127)), .none)
    }

    func testLearnSceneIgnoresReleaseAndNoteOffNeverTriggers() {
        var router = MIDIRouter()
        router.learning = .scene3
        XCTAssertEqual(router.handle(note(36, on: false)), .none, "release must not be learned")
        XCTAssertEqual(router.handle(note(36, on: true)), .learned(.scene3, .init(.note, channel: 0, number: 36)))
        XCTAssertEqual(router.handle(note(36, on: false)), .none)
        XCTAssertEqual(router.handle(note(36, on: true)), .command(.scene(SceneID.allCases[2])))
    }

    func testFaderLearnsOnlyCCAndScales() {
        var router = MIDIRouter()
        router.learning = .master
        XCTAssertEqual(router.handle(note(40, on: true)), .none)
        _ = router.handle(cc(16, 10))
        XCTAssertEqual(router.handle(cc(16, 127)), .waiting(.master, 1))
        XCTAssertEqual(router.handle(cc(16, 0)), .command(.master(0)))
        XCTAssertEqual(router.handle(cc(16, 127)), .command(.master(1)))
    }

    func testCCButtonFiresOncePerPressAndRelearnMovesControl() {
        var router = MIDIRouter()
        router.learning = .blackout
        _ = router.handle(cc(50, 127))
        _ = router.handle(cc(50, 0))
        XCTAssertEqual(router.handle(cc(50, 127)), .command(.toggleBlackout))
        XCTAssertEqual(router.handle(cc(50, 127)), .none)
        router.learning = .output
        _ = router.handle(cc(50, 0))
        XCTAssertEqual(router.handle(cc(50, 127)), .learned(.output, .init(.cc, channel: 0, number: 50)))
        XCTAssertNil(router.map.control(for: .blackout))
    }

    func testMapRoundTripsAndK2Matching() throws {
        var map = MIDIMap()
        map.bind(.energy, to: .init(.cc, channel: 14, number: 4))
        let decoded = try JSONDecoder().decode(MIDIMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded, map)
        XCTAssertTrue(MIDIRouter.isK2("XONE:K2"))
        XCTAssertFalse(MIDIRouter.isK2("IAC Driver Bus 1"))
        XCTAssertFalse(MIDIRouter.isK2("MiniLab MK2"))
    }

    func testFreshPreferencesStartLowButSavedValuesSurvive() throws {
        XCTAssertEqual(Preferences().master, 0.25)
        let saved = try JSONDecoder().decode(Preferences.self, from: Data(#"{"master":0.1,"scene":"aurora"}"#.utf8))
        XCTAssertEqual(saved.master, 0.1, accuracy: 1e-9)
        XCTAssertEqual(saved.beatSource, .auto)
    }

    func testTri180TestPresetMatchesConfirmedLight() {
        let patch = VarytecRig.tri180Test()
        XCTAssertEqual(patch.fixtures.map(\.address), [8])
        XCTAssertEqual(patch.fixtures.map(\.universe), [1])
        XCTAssertEqual(patch.fixtures.map(\.profileID), ["varytec.tri180.8"])
        XCTAssertTrue(patch.validate(library: ProfileLibrary()).isEmpty)
        XCTAssertFalse(patch.isConfirmed(library: ProfileLibrary()))
    }

    private func note(_ n: UInt8, on: Bool) -> MIDIEvent {
        MIDIEvent(control: .init(.note, channel: 0, number: n), value: on ? 100 : 0, isNoteOn: on)
    }

    private func cc(_ n: UInt8, _ v: UInt8) -> MIDIEvent {
        MIDIEvent(control: .init(.cc, channel: 0, number: n), value: v, isNoteOn: false)
    }
}
