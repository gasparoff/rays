import XCTest
@testable import LightCore

final class PresetEditingTests: XCTestCase {
    func testModifiedPresetRoundTripsInItsOriginalSlotAlongsidePersonalScenes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = CustomSceneFile(directory: dir)
        var modified = CustomScene(name: "Ambra mia", presetSlot: .ambra, base: .ambra,
                                   colors: Array(repeating: .init(r: 0, g: 1, b: 0), count: 3),
                                   energy: 0.73, subdivision: .two, warmth: 0.4,
                                   leftLevel: 0.8, centerLevel: 0.9, rightLevel: 0.7)
        let personal = CustomScene(name: "Green")
        try file.save([personal, modified])
        var loaded = try file.load()
        XCTAssertEqual(loaded, [personal, modified])
        XCTAssertNil(loaded[0].presetSlot)
        modified.colors[0] = .init(r: 1, g: 0, b: 0)
        loaded[1] = modified
        try file.save(loaded)
        XCTAssertEqual(try file.load().first(where: { $0.presetSlot == .ambra })?.id, modified.id)
        XCTAssertEqual(try file.load().count, 2, "editing a preset must not multiply personal scenes")
    }

    func testExistingScenesRemainPersonalAndPresetMusicalIdentityStaysFixed() throws {
        let old = Data("[{\"name\":\"Green\",\"base\":\"pulse\"}]".utf8)
        let scene = try XCTUnwrap(CustomSceneDocument.decode(old).first)
        XCTAssertNil(scene.presetSlot)
        XCTAssertEqual(scene.base, .pulse)
        var preset = CustomScene(name: "Build mio", presetSlot: .aurora, base: .chase)
        preset = preset.sanitized
        XCTAssertEqual(preset.base, .aurora, "the Build pad must still launch a build after editing")
        preset.presetSlot = nil
        preset.base = .chase
        XCTAssertEqual(preset.sanitized.base, .chase, "personal copies can choose any choreography")
    }

    func testHeldBuildAndReleasedDropUseEditedLooksWithoutLosingBeatRateLock() {
        let clock = ManualClock()
        clock.now = 0 // Start the timeline before advancing to 4 s; never jump backwards from 1000.
        let engine = LightEngine(tempo: LocalTempoClock(bpm: 120, now: { clock.now }), transport: FakeTransport(),
                                 clock: { clock.now }, runsTimer: false)
        var patch = VarytecRig.referenceRig()
        patch.setConfirmed(true, library: ProfileLibrary())
        engine.setPatch(patch); engine.setMaster(1); engine.setEnergy(1)
        engine.setSubdivision(.four, immediate: true)
        let build = CustomScene(name: "Build rosso", presetSlot: .aurora, base: .aurora,
                                colors: Array(repeating: .init(r: 1, g: 0, b: 0), count: 3), warmth: 0)
        var snap = EngineSnapshot()
        engine.onSnapshot = { snap = $0 }
        engine.setBuildDropGesture(true, look: build)
        engine.sync {}
        clock.now = 4
        engine.stepForTesting()
        XCTAssertTrue(snap.movementLocked)
        XCTAssertEqual(snap.subdivision, .one, "the held gesture runs at the real beat rate")
        XCTAssertTrue(snap.fixtures.flatMap(\.rgb).allSatisfy { $0.g == 0 && $0.b == 0 })
        XCTAssertTrue(snap.fixtures.flatMap(\.cob).allSatisfy { $0 == 0 })
        let drop = CustomScene(name: "Drop verde", presetSlot: .respiro, base: .respiro,
                               colors: Array(repeating: .init(r: 0, g: 1, b: 0), count: 3), warmth: 0.3)
        engine.setBuildDropGesture(false, look: drop)
        engine.sync {}
        clock.now = 4.125
        engine.stepForTesting()
        XCTAssertEqual(snap.scene, .respiro)
        XCTAssertTrue(snap.movementLocked)
        XCTAssertGreaterThan(snap.fixtures.flatMap(\.rgb).map(\.g).max() ?? 0, 0.8)
        XCTAssertTrue(snap.fixtures.flatMap(\.rgb).allSatisfy { $0.r == 0 && $0.b == 0 })
        XCTAssertTrue(snap.fixtures.flatMap(\.cob).allSatisfy { $0 <= 77.0 / 255 })
        XCTAssertGreaterThan(snap.fixtures.flatMap(\.cob).max() ?? 0, 0.25)
        engine.setCustomScene(nil); engine.setScene(.pulse)
        engine.sync {}
        clock.now = 5.5
        engine.stepForTesting()
        XCTAssertFalse(snap.movementLocked)
        XCTAssertEqual(snap.subdivision, .four, "the original movement preference resumes after the gesture")
    }
}
