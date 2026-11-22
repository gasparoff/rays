import XCTest
@testable import LightCore

final class SceneAndDMXTests: XCTestCase {
    func testAllScenesFiniteAndBoundedAtEdgeBeats() {
        let beats: [Double] = [0, -0.001, -3.75, -1e6, 0.5, 1, 3.999, 1e9, .nan, .infinity, -.infinity]
        for scene in SceneID.allCases {
            for sub in Subdivision.allCases {
                for energy in [0.0, 0.5, 1.0] {
                    for count in [1, 2, 6, 24] {
                        for beat in beats {
                            for i in 0..<count {
                                let c = SceneRenderer.render(scene, beat: beat, index: i, count: count,
                                                             params: SceneParameters(energy: energy, subdivision: sub))
                                XCTAssertTrue(c.isFinite, "\(scene) beat \(beat)")
                                for v in [c.r, c.g, c.b, c.w] { XCTAssertTrue((0...1).contains(v), "\(scene) \(v)") }
                            }
                        }
                    }
                }
            }
        }
    }

    func testScenesAreDeterministicFunctionsOfBeat() {
        let p = SceneParameters(energy: 0.7, subdivision: .one)
        for scene in SceneID.allCases {
            XCTAssertEqual(SceneRenderer.render(scene, beat: 12.25, index: 2, count: 6, params: p),
                           SceneRenderer.render(scene, beat: 12.25, index: 2, count: 6, params: p))
        }
    }

    func testPulseCentreHitsAndSidesAnswerOffbeat() {
        func frame(_ beat: Double) -> RigFrame { Choreography.render(.pulse, SceneContext(beat: beat, energy: 1)) }
        let on = frame(4), decay = frame(4.3), offbeat = frame(4.5)
        XCTAssertGreaterThan(on.center.rgb.map(\.peak).max()!, decay.center.rgb.map(\.peak).max()!)
        XCTAssertGreaterThan(offbeat.left.rgb[0].peak, on.left.rgb[0].peak)
        XCTAssertTrue(frame(-4).isFinite)
    }

    func testChaseTravelsAcrossTheWholeRig() {
        func frame(_ beat: Double) -> RigFrame { Choreography.render(.chase, SceneContext(beat: beat, energy: 1)) }
        XCTAssertGreaterThan(frame(0).left.rgb[0].peak, frame(0).right.rgb[0].peak)
        XCTAssertGreaterThan(frame(2).right.rgb[0].peak, frame(2).left.rgb[0].peak)
        let middle = frame(1)
        XCTAssertGreaterThan(middle.center.rgb.map(\.peak).max()!, middle.left.rgb[0].peak)
    }

    func testBlackoutIsAllZerosIncludingConstants() {
        let custom = FixtureProfile(id: "custom.s", name: "S", isGeneric: false,
                                    channels: [.init(.dimmer), .init(.red), .init(.green), .init(.blue), .init(.constant, value: 255)])
        let patch = Patch(fixtures: [PatchedFixture(label: "A", profileID: "custom.s", universe: 0, address: 100)], customProfiles: [custom])
        let lib = ProfileLibrary()
        let lit = DMXComposer.compose(patch: patch, library: lib, colors: [LightColor(1, 0.5, 0)], master: 1, blackout: false)
        XCTAssertEqual(Array(lit[PortAddress(0)!]![99..<104]), [255, 255, 128, 0, 255])
        let dark = DMXComposer.compose(patch: patch, library: lib, colors: [LightColor(1, 0.5, 0)], master: 1, blackout: true)
        XCTAssertEqual(dark[PortAddress(0)!]?.count, 512)
        XCTAssertTrue(dark[PortAddress(0)!]!.allSatisfy { $0 == 0 })
    }

    func testMasterScalesColorsWithoutDimmerAndOnlyOwnSlotsAreWritten() {
        let lib = ProfileLibrary()
        let patch = Patch(fixtures: [PatchedFixture(label: "A", profileID: "generic.rgb3", universe: 1, address: 510)])
        let f = DMXComposer.compose(patch: patch, library: lib, colors: [LightColor(1, 1, 1)], master: 0.5, blackout: false)
        let u = f[PortAddress(1)!]!
        XCTAssertEqual(Array(u[509..<512]), [128, 128, 128])
        XCTAssertTrue(u[0..<509].allSatisfy { $0 == 0 })
        XCTAssertNil(f[PortAddress(0)!], "universes without fixtures are not produced")
    }

    func testWhiteFoldsIntoRGBWhenNoWhiteChannel() {
        let rgb = ProfileLibrary().profile(id: "generic.rgb3")!
        let v = DMXComposer.channelValues(profile: rgb, color: LightColor(0, 0, 0, 1), master: 1)
        XCTAssertTrue(v.allSatisfy { $0 > 150 })
    }
}
