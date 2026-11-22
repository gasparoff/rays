import XCTest
@testable import RaysCore
@testable import RaysControl

final class SceneBankCompatibilityTests: XCTestCase {
    func testExistingPresetEditsStayInHouseAndBothBanksRoundTripIndependently() throws {
        let old = Data("{\"version\":1,\"scenes\":[{\"name\":\"Pulse mia\",\"presetSlot\":\"pulse\",\"base\":\"pulse\"}]}".utf8)
        let house = try XCTUnwrap(CustomSceneDocument.decode(old).first)
        XCTAssertEqual(house.presetBank, .house)
        var club = house
        club.id = UUID(); club.presetBank = .club; club.name = "Jack mio"
        club.program = SceneProgram(tracks: [ProgramTrack(target: .sides)])
        let loaded = try CustomSceneDocument.decode(CustomSceneDocument.encode([house, club]))
        XCTAssertEqual(loaded, [house, club])
        XCTAssertEqual(loaded.filter { $0.presetBank == .house }.first?.id, house.id)
        XCTAssertEqual(loaded.filter { $0.presetBank == .club }.first?.id, club.id)
        XCTAssertNotEqual(house.id, club.id)
    }

    func testAnotherBankInTheSameSlotWaitsForItsBeatAndKeepsOutgoingLook() {
        let red = CustomScene(presetSlot: .pulse, base: .pulse,
                              colors: Array(repeating: SceneRGB(r: 1, g: 0, b: 0), count: 3),
                              program: SceneProgram(tracks: [ProgramTrack(target: .all, floor: 1, peak: 1)]))
        var green = red
        green.id = UUID(); green.presetBank = .club
        green.colors = Array(repeating: SceneRGB(r: 0, g: 1, b: 0), count: 3)
        var seq = SceneSequencer(scene: .pulse)
        seq.setLook(SceneLook(red))
        seq.advance(beat: 0.2, bpm: 134, now: 0, gridTrusted: true)
        seq.request(.pulse, look: SceneLook(green), beat: 0.2, now: 0, gridTrusted: true)
        XCTAssertEqual(seq.pendingScene, .pulse, "Sharing a MIDI slot must not replace the running bank instantly")
        let before = seq.render(beat: 0.2, energy: 1, now: 0)
        XCTAssertTrue(before.center.rgb.allSatisfy { $0 == LightColor(1, 0, 0) })
        seq.advance(beat: 4.2, bpm: 134, now: 4 * 60 / 134, gridTrusted: true)
        let after = seq.render(beat: 4.2, energy: 1, now: 4 * 60 / 134)
        XCTAssertTrue(after.center.rgb.allSatisfy { $0 == LightColor(0, 1, 0) })
        XCTAssertNil(seq.pendingScene)
    }

    func testEditingTheSameSceneIdentityDoesNotRestartOrQuantiseIt() {
        var scene = CustomScene(presetSlot: .pulse, base: .pulse)
        var seq = SceneSequencer(scene: .pulse)
        seq.setLook(SceneLook(scene))
        scene.energy = 0.9
        seq.request(.pulse, look: SceneLook(scene), beat: 0.2, now: 0, gridTrusted: true)
        XCTAssertNil(seq.pendingScene)
        XCTAssertEqual(seq.look?.source.energy, 0.9)
    }

    func testXoneSceneLEDsDoNotMisidentifyAnotherBanksPlayingScene() {
        var state = K2FeedbackState(scene: .pulse)
        state.live = true; state.armed = true
        XCTAssertEqual(K2Feedback.color(.scene3, state), .green)
        state.sceneInBank = false
        state.pendingScene = .chase; state.blinkOn = true
        for action in [ControlAction.scene1, .scene2, .scene3, .scene4, .scene5, .scene6] {
            XCTAssertEqual(K2Feedback.color(action, state), .off)
        }
        XCTAssertEqual(K2Feedback.color(.output, state), .green, "Browsing banks must preserve real output feedback")
        state.blackout = true
        XCTAssertEqual(K2Feedback.color(.blackout, state), .red)
    }
}
