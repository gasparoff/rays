import XCTest
@testable import RaysCore

/// Scene banks in `custom-scenes.json`: old files keep decoding, user banks round-trip, and the
/// House factory scenes render exactly as the built-in choreography.
final class SceneLibraryTests: XCTestCase {
    func testBankIdsAreValidatedAndStoredAsPlainStrings() throws {
        XCTAssertEqual(SceneBank(rawValue: "house"), .house)
        XCTAssertEqual(SceneBank(rawValue: "club"), .club)
        XCTAssertNil(SceneBank(rawValue: ""))
        XCTAssertNil(SceneBank(rawValue: "Club"))
        XCTAssertNil(SceneBank(rawValue: "user/../x"))
        let user = SceneBank.user()
        XCTAssertFalse(user.isBuiltIn)
        XCTAssertEqual(SceneBank(rawValue: user.rawValue), user)
        let data = try JSONEncoder().encode([SceneBank.club, user])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"club\",\"\(user.rawValue)\"]")
        XCTAssertEqual(try JSONDecoder().decode([SceneBank].self, from: data), [.club, user])
    }

    func testFileWithoutBanksReadsAndWritesAsBefore() throws {
        let old = Data(
            """
            {"version":1,"scenes":[{"name":"Pulse mia","presetSlot":"pulse","base":"pulse"},
            {"name":"Jack mio","presetSlot":"pulse","presetBank":"club","base":"pulse"}]}
            """.utf8)
        let library = try CustomSceneDocument.decodeLibrary(old)
        XCTAssertEqual(library.scenes.map(\.presetBank), [.house, .club])
        XCTAssertEqual(library.banks, [])
        XCTAssertEqual(library.allBanks.map(\.id), [.house, .club])
        let written = try CustomSceneDocument.encode(library)
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("banks"), "no new key for users without banks")
        XCTAssertEqual(written, try CustomSceneDocument.encode(library.scenes))
    }

    func testUserBanksRoundTripAndBadEntriesAreSkippedNotFatal() throws {
        var library = SceneLibrary()
        let techno = try XCTUnwrap(library.addBank(name: "Techno", origin: .club))
        let edit = CustomScene(name: "Mia", presetSlot: .chase, presetBank: techno.id, base: .chase)
        library.scenes = [edit]
        let loaded = try CustomSceneDocument.decodeLibrary(CustomSceneDocument.encode(library))
        XCTAssertEqual(loaded, library)
        XCTAssertEqual(loaded.preset(.chase, bank: techno.id), edit)
        XCTAssertNil(loaded.preset(.chase, bank: .club))

        let messy = Data(
            """
            {"version":1,"scenes":[{"name":"A","base":"pulse"}],
             "banks":[{"id":"club","name":"Fake"},{"id":"user-a","name":"  Uno  ","origin":"club"},
                      {"id":"user-a","name":"Duplicate"},{"name":"no id"},{"id":"user-b","origin":"user-a"}]}
            """.utf8)
        let cleaned = try CustomSceneDocument.decodeLibrary(messy)
        XCTAssertEqual(cleaned.scenes.map(\.name), ["A"], "scenes survive a damaged bank list")
        XCTAssertEqual(cleaned.banks.map(\.id.rawValue), ["user-a", "user-b"])
        XCTAssertEqual(cleaned.banks.map(\.name), ["Uno", "My bank"])
        XCTAssertEqual(cleaned.banks.map(\.origin), [.club, .house], "only built-in banks can be an origin")
    }

    func testDeletingABankRemovesOnlyItsPadEdits() throws {
        var library = SceneLibrary()
        let bank = try XCTUnwrap(library.addBank(name: "Uno", origin: .house))
        let mine = CustomScene(name: "Personal", base: .pulse)
        let house = CustomScene(name: "House edit", presetSlot: .pulse, presetBank: .house, base: .pulse)
        let pad = CustomScene(name: "Pad", presetSlot: .pulse, presetBank: bank.id, base: .pulse)
        library.scenes = [mine, house, pad]
        library.deleteBank(.house)
        XCTAssertEqual(library.scenes.count, 3, "built-in banks cannot be removed")
        library.deleteBank(bank.id)
        XCTAssertEqual(library.scenes, [mine, house])
        XCTAssertTrue(library.banks.isEmpty)
    }

    func testBankLimitAndNames() {
        var library = SceneLibrary()
        for i in 0..<SceneBankInfo.maxUserBanks { XCTAssertNotNil(library.addBank(name: "B\(i)", origin: .house)) }
        XCTAssertNil(library.addBank(name: "too many", origin: .house))
        let first = library.banks[0].id
        library.renameBank(first, to: String(repeating: "x", count: 80))
        XCTAssertEqual(library.banks[0].name.count, SceneBankInfo.maxNameLength)
        library.renameBank(first, to: "   ")
        XCTAssertEqual(library.banks[0].name.count, SceneBankInfo.maxNameLength, "an empty name keeps the old one")
    }

    func testEveryPadOfEveryBankHasAStableSceneModel() throws {
        let user = SceneBankInfo(id: try XCTUnwrap(SceneBank(rawValue: "user-x")), name: "X", origin: .house)
        for slot in SceneID.allCases {
            let house = FactoryScenes.scene(for: slot, in: .house)
            XCTAssertEqual(house, HouseSceneBank.scene(for: slot))
            XCTAssertEqual(house.presetSlot, slot)
            XCTAssertEqual(house.presetBank, .house)
            XCTAssertNil(house.program, "the House choreography plays as written")
            XCTAssertTrue(house.usesBaseColors)
            XCTAssertEqual(FactoryScenes.scene(for: slot, in: .club), ClubSceneBank.scene(for: slot))
            let pad = FactoryScenes.scene(for: slot, in: user)
            XCTAssertEqual(pad.presetBank, user.id)
            XCTAssertEqual(pad.id, FactoryScenes.scene(for: slot, in: user).id)
            XCTAssertNotEqual(pad.id, house.id)
            XCTAssertEqual(FactoryScenes.scene(id: pad.id, banks: SceneBankInfo.builtIn + [user]), pad)
        }
        let ids = SceneID.allCases.flatMap { slot in
            [SceneBankInfo.house, .club, user].map { FactoryScenes.scene(for: slot, in: $0).id }
        }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testHouseFactorySceneRendersExactlyAsTheChoreography() {
        for slot in SceneID.allCases {
            let look = SceneLook(HouseSceneBank.scene(for: slot))
            for beat in stride(from: -2.0, through: 18, by: 0.37) {
                let ctx = SceneContext(beat: beat, phrase: beat, energy: 0.6)
                XCTAssertEqual(
                    look.render(slot, ctx), SpatialRig.classic.fitting(Choreography.render(slot, ctx)), "\(slot) at \(beat)")
            }
        }
    }
}
