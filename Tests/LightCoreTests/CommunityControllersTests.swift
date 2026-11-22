import XCTest
@testable import RaysControl

/// Validates every controller layout in `Controllers/` and proves the Xone:K2 files are
/// identical to the built-in `XoneK2` presets the router uses.
final class CommunityControllersTests: XCTestCase {
    private var controllersDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LightCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Controllers", isDirectory: true)
    }

    private func loaded() -> [ControllerProfile] {
        let result = ControllerLibrary.loadProfiles(in: controllersDirectory)
        XCTAssertEqual(result.errors, [], "Invalid controller layout in Controllers/")
        return result.profiles
    }

    func testEveryControllerFileIsValidAndUnique() {
        let profiles = loaded()
        XCTAssertGreaterThanOrEqual(profiles.count, 2)
        var ids = Set<String>()
        for p in profiles {
            XCTAssertEqual(p.problems, [], p.id)
            XCTAssertTrue(ids.insert(p.id).inserted, "Duplicate controller id \(p.id)")
            XCTAssertFalse(p.notes?.isEmpty ?? true, "\(p.id): add notes describing the layout")
        }
    }

    /// Fixed expected values: the factory layouts as they shipped before controllers became data.
    private static let expectedClassic: [(ControlAction, MIDIControl.Kind, UInt8)] = [
        (.levelLeft, .cc, 16), (.levelCenter, .cc, 17), (.levelRight, .cc, 18), (.master, .cc, 19),
        (.accentLevel, .cc, 11), (.energy, .cc, 15),
        (.scene1, .note, 36), (.scene2, .note, 37), (.scene3, .note, 38), (.stop, .note, 39),
        (.scene4, .note, 32), (.scene5, .note, 33), (.scene6, .note, 34), (.buildDrop, .note, 35),
        (.rateQuarter, .note, 28), (.rateHalf, .note, 29), (.rateNormal, .note, 30), (.rateDouble, .note, 31),
        (.accent, .note, 24), (.blackout, .note, 27),
    ]
    private static let expectedLiveV2: [(ControlAction, MIDIControl.Kind, UInt8)] = [
        (.levelLeft, .cc, 16), (.levelCenter, .cc, 17), (.levelRight, .cc, 18), (.master, .cc, 19),
        (.energy, .cc, 20), (.accentLevel, .cc, 21),
        (.scene1, .note, 36), (.scene2, .note, 37), (.scene3, .note, 38), (.bankHouse, .note, 39),
        (.scene4, .note, 32), (.scene5, .note, 33), (.scene6, .note, 34), (.bankClub, .note, 35),
        (.rateQuarter, .note, 28), (.rateHalf, .note, 29), (.rateNormal, .note, 30), (.rateDouble, .note, 31),
        (.accent, .note, 24), (.sceneFirstBeat, .note, 25), (.cancelPending, .note, 26), (.stop, .note, 27),
        (.buildDrop, .note, 12), (.blackout, .note, 15),
    ]

    private static func expectedLED(_ base: UInt8) -> [UInt8] {
        if base == 12 || base == 15 { return [base, base + 4, base + 8] }
        return (24...55).contains(base) ? [base, base + 36, base + 72] : []
    }

    func testXoneK2FilesAndBuiltInsEqualTheFactoryLayouts() throws {
        let byID = Dictionary(uniqueKeysWithValues: loaded().map { ($0.id, $0) })
        let cases: [(XoneK2.Layout, [(ControlAction, MIDIControl.Kind, UInt8)], Int?)] =
            [(.classic, Self.expectedClassic, nil), (.liveV2, Self.expectedLiveV2, 127)]
        for (layout, expected, resolution) in cases {
            let builtIn = XoneK2.profile(for: layout)
            let file = try XCTUnwrap(byID[builtIn.id], builtIn.id)
            XCTAssertEqual(file, builtIn, "Controllers/ JSON drifted from the built-in \(layout) layout")
            let id = builtIn.id
            XCTAssertEqual(builtIn.bindings, expected.map { .init($0.0, $0.1, $0.2) }, id)
            XCTAssertEqual(builtIn.midiChannel, 15, id)
            XCTAssertEqual(builtIn.channel, XoneK2.factoryChannel, id)
            XCTAssertEqual(Set(builtIn.relativeEncoders ?? []), [0, 1, 2, 3, 20, 21], id)
            XCTAssertEqual(Set(builtIn.relativeEncoders ?? []), XoneK2.relativeEncoderCCs, id)
            XCTAssertEqual(builtIn.encoderResolution, resolution, id)
            for name in ["XONE:K2", "Xone K2 MIDI", "K2"] { XCTAssertTrue(builtIn.matches(portName: name), "\(id) \(name)") }
            for name in ["K25", "Launchpad", "XONE:K3"] {
                XCTAssertEqual(builtIn.matches(portName: name), MIDIRouter.isK2(name), "\(id) \(name)")
            }
            let leds = try XCTUnwrap(builtIn.leds, id)
            for base in UInt8(0)...127 {
                XCTAssertEqual(leds.addresses(base: base), Self.expectedLED(base), "\(id) LED \(base)")
                XCTAssertEqual(XoneK2.ledAddresses(base: base), Self.expectedLED(base), "XoneK2 LED \(base)")
            }
            for (action, kind, number) in expected {
                XCTAssertEqual(XoneK2.presetAction(kind: kind, number: number, layout: layout), action, id)
                XCTAssertEqual(XoneK2.presetControl(for: action, channel: 14, layout: layout),
                               MIDIControl(kind, channel: 14, number: number), id)
            }
        }
        XCTAssertEqual(MIDIRouter.livePresetEncoderStep, 1.0 / 127, accuracy: 1e-12)
    }

    func testValidationCatchesCommonMistakes() {
        var p = ControllerProfile(id: "x", name: "X", manufacturer: "Y", portNamePattern: "x", midiChannel: 17,
                                  bindings: [.init(.master, .note, 1), .init(.scene1, .cc, 2), .init(.scene2, .cc, 2)],
                                  relativeEncoders: [2], encoderResolution: nil, leds: nil, notes: nil)
        let problems = p.problems
        XCTAssertTrue(problems.contains { $0.contains("midiChannel") })
        XCTAssertTrue(problems.contains { $0.contains("master is continuous") })
        XCTAssertTrue(problems.contains { $0.contains("cc 2 is bound twice") })
        XCTAssertTrue(problems.contains { $0.contains("button on encoder") })
        p.midiChannel = 1
        p.bindings = [.init(.master, .cc, 7)]
        p.relativeEncoders = nil
        XCTAssertEqual(p.problems, [])
        XCTAssertEqual(p.action(for: MIDIControl(.cc, channel: 0, number: 7)), .master)
        XCTAssertNil(p.action(for: MIDIControl(.cc, channel: 1, number: 7)))
    }

    func testUserFilesOverrideBundledOnesByID() {
        let a = ControllerProfile(id: "a", name: "A", manufacturer: "M", portNamePattern: "a", midiChannel: 1,
                                  bindings: [.init(.master, .cc, 1)], relativeEncoders: nil, encoderResolution: nil,
                                  leds: nil, notes: nil)
        var a2 = a; a2.name = "A user"
        var b = a; b.id = "b"
        XCTAssertEqual(ControllerLibrary.merge([a, b], [a2]).map(\.name), ["A user", "A"])
    }
}
