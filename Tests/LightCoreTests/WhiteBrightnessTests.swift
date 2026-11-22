import XCTest
@testable import RaysTempo
@testable import RaysCore
@testable import RaysEngine

final class WhiteBrightnessTests: XCTestCase {
    func testEverySceneCanReachFullRGBAndCOBAtEveryEnergy() {
        for energy in [0.0, 0.5, 1.0] {
        for scene in SceneID.allCases {
            var rgb = [0.0, 0, 0], white = [0.0, 0, 0]
            for step in 0...2048 {
                let beat = Double(step) / 32
                let frame = Choreography.render(scene, SceneContext(beat: beat, phrase: beat, energy: energy))
                for (i, role) in FixtureRole.allCases.enumerated() {
                    rgb[i] = max(rgb[i], frame[role].rgb.map(\.peak).max() ?? 0)
                    white[i] = max(white[i], frame[role].cob.max() ?? 0)
                }
            }
            for i in 0..<3 {
                XCTAssertGreaterThanOrEqual(rgb[i], 0.999, "\(scene) energy\(energy) RGB role\(i): \(rgb)")
                XCTAssertGreaterThanOrEqual(white[i], 0.999, "\(scene) energy\(energy) COB role\(i): \(white)")
            }
        }
        }
    }

    func testWhiteFaderIsIndependentAndAlwaysBelowMasterIncludingAccent() throws {
        let clock = ManualClock()
        let engine = LightEngine(tempo: LocalTempoClock(now: { clock.now }), transport: FakeTransport(),
                                 clock: { clock.now }, runsTimer: false)
        var patch = VarytecRig.referenceRig()
        patch.setConfirmed(true, library: ProfileLibrary())
        engine.setPatch(patch); engine.setScene(.respiro, immediate: true); engine.setMaster(0.5)
        engine.setAccentLevel(1); engine.setAccent(true)
        var state = EngineSnapshot()
        engine.onSnapshot = { state = $0 }
        engine.setWhiteLevel(1); engine.stepForTesting()
        let first = state.fixtures
        XCTAssertEqual(first.count, 3)
        for f in first { XCTAssertTrue(f.cob.allSatisfy { abs($0 - 128.0 / 255) < 1e-9 }) }
        engine.beginScenePreview(); engine.finishScenePreview(restore: true)
        engine.setWhiteLevel(0.25); engine.stepForTesting()
        for (old, f) in zip(first, state.fixtures) {
            XCTAssertEqual(f.rgb, old.rgb, "white brightness never changes RGB")
            XCTAssertTrue(f.cob.allSatisfy { abs($0 - 32.0 / 255) < 1e-9 })
        }
        engine.setWhiteLevel(0); engine.stepForTesting()
        XCTAssertTrue(state.fixtures.flatMap(\.cob).allSatisfy { $0 == 0 })
        engine.setWhiteLevel(1); engine.setMaster(0); engine.stepForTesting()
        XCTAssertTrue(state.fixtures.allSatisfy(\.isDark))
        engine.setMaster(1); engine.setBlackout(true); engine.stepForTesting()
        XCTAssertTrue(state.fixtures.allSatisfy(\.isDark))
    }

    func testGreenCustomSceneReachesMasterWithHalfEnergyAndQuarterSpeed() {
        let clock = ManualClock()
        let engine = LightEngine(tempo: LocalTempoClock(now: { clock.now }), transport: FakeTransport(),
                                 clock: { clock.now }, runsTimer: false)
        var patch = VarytecRig.referenceRig()
        patch.setConfirmed(true, library: ProfileLibrary())
        engine.setPatch(patch); engine.setScene(.ambra, immediate: true)
        engine.setEnergy(0.5); engine.setSubdivision(.four, immediate: true)
        engine.setCustomScene(CustomScene(base: .ambra, colors: Array(repeating: SceneRGB(r: 0, g: 1, b: 0), count: 3)))
        var state = EngineSnapshot()
        engine.onSnapshot = { state = $0 }
        for (master, expected) in [(1.0, 1.0), (0.5, 128.0 / 255)] {
            engine.setMaster(master)
            var peaks = [0.0, 0, 0]
            for step in 0...512 {
                clock.now = Double(step) / 32
                engine.stepForTesting()
                for (i, f) in state.fixtures.enumerated() {
                    peaks[i] = max(peaks[i], f.rgb.map(\.g).max() ?? 0)
                    XCTAssertTrue(f.rgb.allSatisfy { $0.r == 0 && $0.b == 0 })
                }
            }
            for p in peaks { XCTAssertEqual(p, expected, accuracy: 1.0 / 255 + 1e-9, "master controls the Green scene crest at energy50%, rate×¼") }
        }
    }

    func testOldShowFilesKeepFullWhiteAndNewLevelRoundTrips() throws {
        let old = try JSONDecoder().decode(ShowSettings.self, from: Data("{\"levelLeft\":0.4,\"accentLevel\":0.7}".utf8))
        XCTAssertEqual(old.whiteLevel, 1); XCTAssertEqual(old.levelLeft, 0.4)
        var show = old; show.whiteLevel = 0.37
        XCTAssertEqual(try JSONDecoder().decode(ShowSettings.self, from: JSONEncoder().encode(show)).whiteLevel, 0.37)
    }
}
