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

    func testXoneK2FilesEqualTheBuiltInPresets() throws {
        let byID = Dictionary(uniqueKeysWithValues: loaded().map { ($0.id, $0) })
        let files: [(String, XoneK2.Layout)] = [("allen-heath.xone-k2.classic", .classic),
                                                ("allen-heath.xone-k2.live-v2", .liveV2)]
        for (id, layout) in files {
            let p = try XCTUnwrap(byID[id], id)
            XCTAssertEqual(p.bindings, XoneK2.preset(for: layout).map { .init($0.action, $0.kind, $0.number) }, id)
            XCTAssertEqual(p.channel, XoneK2.factoryChannel, id)
            XCTAssertEqual(Set(p.relativeEncoders ?? []), XoneK2.relativeEncoderCCs, id)
            for name in ["XONE:K2", "Xone K2 MIDI", "K2"] { XCTAssertTrue(p.matches(portName: name), "\(id) \(name)") }
            for name in ["K25", "Launchpad", "XONE:K3"] {
                XCTAssertEqual(p.matches(portName: name), MIDIRouter.isK2(name), "\(id) \(name)")
            }
            let leds = try XCTUnwrap(p.leds, id)
            for base in UInt8(0)...127 {
                XCTAssertEqual(leds.addresses(base: base), XoneK2.ledAddresses(base: base), "\(id) LED \(base)")
            }
            for binding in p.bindings {
                let control = MIDIControl(binding.type, channel: XoneK2.factoryChannel, number: binding.number)
                XCTAssertEqual(p.action(for: control), XoneK2.presetAction(kind: binding.type, number: binding.number, layout: layout))
            }
        }
        let live = try XCTUnwrap(byID["allen-heath.xone-k2.live-v2"])
        XCTAssertEqual(1.0 / Double(try XCTUnwrap(live.encoderResolution)), MIDIRouter.livePresetEncoderStep, accuracy: 1e-12)
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
