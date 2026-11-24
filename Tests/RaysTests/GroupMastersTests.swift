import XCTest
@testable import RaysOutput
@testable import RaysTempo
@testable import RaysCore
@testable import RaysControl
@testable import RaysEngine

/// Group masters and direct commands (ADR 0005 step 5): saved-file compatibility, the order of the
/// overrides, and blackout winning over every one of them.
final class GroupMastersTests: XCTestCase {
    private let g1 = RigGroupID("g-1")

    // MARK: show.json

    func testOldShowFileDecodesIntoGroupMastersAndIsWrittenBackWithTheSameKeys() throws {
        let old = #"{"accentLevel":0.7,"levelCenter":0.6,"levelLeft":0.4,"levelRight":0.2,"whiteLevel":0.5}"#
        let show = try JSONDecoder().decode(ShowSettings.self, from: Data(old.utf8))
        XCTAssertEqual(show.masters, [.left: 0.4, .center: 0.6, .right: 0.2])
        XCTAssertEqual(show.levelLeft, 0.4)
        XCTAssertEqual(show.level(.center), 0.6)
        XCTAssertEqual(show.level(group: .right), 0.2)
        XCTAssertEqual(show.level(group: g1), 1, "a group without a master plays at full")
        XCTAssertEqual(show.accentLevel, 0.7)
        XCTAssertEqual(show.whiteLevel, 0.5)

        // A classic show is saved exactly as before: the same keys and values, no new key.
        let data = try JSONEncoder().encode(show)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(old.utf8)) as? [String: Double])
        XCTAssertEqual(saved, original)
        XCTAssertEqual(try JSONDecoder().decode(ShowSettings.self, from: data), show)
    }

    func testShowWithAnotherGroupKeepsTheClassicKeysForOlderBuilds() throws {
        var show = ShowSettings()
        show.setLevel(group: g1, 0.3)
        show.setLevel(.left, 0.8)
        let data = try JSONEncoder().encode(show)
        XCTAssertEqual(try JSONDecoder().decode(ShowSettings.self, from: data), show)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["levelLeft"] as? Double, 0.8)
        XCTAssertEqual(object["levelCenter"] as? Double, 1)
        XCTAssertEqual((object["masters"] as? [String: Double])?["g-1"], 0.3)

        // What a build from before group masters reads from the new file.
        struct OldShow: Decodable, Equatable {
            var levelLeft, levelCenter, levelRight, accentLevel, whiteLevel: Double
        }
        XCTAssertEqual(
            try JSONDecoder().decode(OldShow.self, from: data),
            OldShow(levelLeft: 0.8, levelCenter: 1, levelRight: 1, accentLevel: 1, whiteLevel: 1))
    }

    func testBrokenOrOutOfRangeShowMastersFallBackSafely() throws {
        func decode(_ json: String) throws -> ShowSettings { try JSONDecoder().decode(ShowSettings.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"levelLeft":"x","levelRight":4}"#).masters, [.left: 1, .center: 1, .right: 1])
        XCTAssertEqual(try decode(#"{"levelLeft":0.2,"masters":[1,2]}"#).levelLeft, 0.2, "an unreadable map keeps the classic keys")
        let both = try decode(#"{"levelLeft":0.2,"masters":{"left":0.9,"g-1":-1}}"#)
        XCTAssertEqual(both.levelLeft, 0.9, "the map, written by a newer build, wins")
        XCTAssertEqual(both.level(group: g1), 0)
        XCTAssertEqual(try decode("{}"), ShowSettings())
        var show = ShowSettings()
        show.setLevel(group: g1, .nan)
        XCTAssertEqual(show.level(group: g1), 1)
    }

    // MARK: Scenes

    func testOldSceneLevelsDecodeIntoMastersAndSaveWithoutANewKey() throws {
        let file = """
            {"version":1,"scenes":[{"id":"601DE000-0000-4000-8000-000000000200","name":"Old","base":"chase",\
            "leftLevel":0.25,"centerLevel":0.5,"rightLevel":0.75}]}
            """
        let scene = try XCTUnwrap(CustomSceneDocument.decode(Data(file.utf8)).first)
        XCTAssertEqual(scene.masters, [.left: 0.25, .center: 0.5, .right: 0.75])
        XCTAssertEqual(scene.leftLevel, 0.25)
        XCTAssertEqual(scene.level(.right), 0.75)
        XCTAssertEqual(scene.level(group: .center), 0.5)
        let saved = try CustomSceneDocument.encode([scene])
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("masters"))
        XCTAssertEqual(try CustomSceneDocument.decode(saved), [scene])

        let missing = try XCTUnwrap(CustomSceneDocument.decode(Data(#"[{"name":"Bare"}]"#.utf8)).first)
        XCTAssertEqual(missing.masters, [.left: 1, .center: 1, .right: 1])
    }

    func testSceneWithAnotherGroupWritesBothKeysAndOldBuildsReadTheClassicOnes() throws {
        var scene = CustomScene(name: "Four", base: .pulse, leftLevel: 0.4, masters: [g1: 0.6, .right: 0.3])
        XCTAssertEqual(scene.masters, [.left: 0.4, .center: 1, .right: 0.3, g1: 0.6])
        scene.centerLevel = 0.9
        XCTAssertEqual(scene.masters[.center], 0.9)
        let saved = try CustomSceneDocument.encode([scene])
        XCTAssertEqual(try CustomSceneDocument.decode(saved), [scene])

        struct OldScene: Decodable { var leftLevel, centerLevel, rightLevel: Double }
        struct OldEnvelope: Decodable { var version: Int; var scenes: [OldScene] }
        let old = try JSONDecoder().decode(OldEnvelope.self, from: saved)
        XCTAssertEqual(old.version, 1, "the envelope version is unchanged")
        XCTAssertEqual(old.scenes.first?.leftLevel, 0.4)
        XCTAssertEqual(old.scenes.first?.centerLevel, 0.9)
        XCTAssertEqual(old.scenes.first?.rightLevel, 0.3)
    }

    func testSceneMastersAreSanitized() {
        let s = CustomScene(leftLevel: .infinity, masters: [g1: 3, .center: -2]).sanitized
        XCTAssertEqual(s.masters, [.left: 1, .center: 0, .right: 1, g1: 1])
        var empty = CustomScene()
        empty.masters = [:]
        XCTAssertEqual(empty.sanitized.masters, [.left: 1, .center: 1, .right: 1])
    }

    // MARK: MIDI

    func testLevelFadersRouteToTheirClassicGroups() {
        XCTAssertEqual(ControlAction.levelLeft.group, .left)
        XCTAssertEqual(ControlAction.levelCenter.group, .center)
        XCTAssertEqual(ControlAction.levelRight.group, .right)
        XCTAssertNil(ControlAction.master.group)
        XCTAssertEqual(MIDICommand.continuous(.levelCenter, 0.5), .level(.center, 0.5))
        XCTAssertEqual(MIDICommand.continuous(.master, 0.5), .master(0.5))
    }

    @MainActor
    func testALevelCommandForAnyGroupReachesTheShowAndTheEngine() {
        let engine = RecordingShowEngine()
        let store = FakeShowStore()
        let scheduler = ManualSaveScheduler()
        let name = "GroupMastersTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = ShowSession(
            engine: engine, store: store, presets: FakePresetStore(), defaults: UserDefaults(suiteName: name)!,
            saveScheduler: scheduler, preferences: Preferences(), showSettings: ShowSettings())
        session.perform(.level(.left, 0.3))
        session.perform(.level(g1, 0.6))
        XCTAssertEqual(session.showSettings.levelLeft, 0.3)
        XCTAssertEqual(session.showSettings.level(group: g1), 0.6)
        XCTAssertEqual(engine.calls, ["level left 0.3", "show"])
        scheduler.fire()
        XCTAssertEqual(store.shows.last?.level(group: g1), 0.6)

        // A scene's masters reach the show levels, other groups keep theirs.
        session.useCustomScene(CustomScene(name: "S", base: .chase, rightLevel: 0.2), persist: false)
        XCTAssertEqual(session.showSettings.masters, [.left: 1, .center: 1, .right: 0.2, g1: 0.6])
    }

    // MARK: Order of the overrides (pure)

    private let ids: [RigGroupID] = [.left, .center, .right]

    func testScaleFollowsMasterThenSoloMuteThenGlobalMaster() {
        let masters: [RigGroupID: Double] = [.left: 0.5, .center: 0.25]
        var mix = GroupMix(ids: ids, masters: masters)
        XCTAssertEqual((0..<3).map { mix.scale(group: $0, master: 0.8) }, [0.4, 0.2, 0.8])
        XCTAssertEqual(mix.scale(group: 1, master: 0.8, groupMaster: false), 0.8)
        XCTAssertEqual(mix.scale(group: -1, master: 0.8), 0.8)

        mix = GroupMix(ids: ids, masters: masters, overrides: GroupOverrides(muted: [.left]))
        XCTAssertEqual((0..<3).map { mix.scale(group: $0, master: 1) }, [0, 0.25, 1])

        mix = GroupMix(ids: ids, masters: masters, overrides: GroupOverrides(soloed: [.center], muted: [.center]))
        XCTAssertEqual((0..<3).map { mix.scale(group: $0, master: 1) }, [0, 0, 0], "mute wins over solo")
        XCTAssertEqual(mix.scale(group: 7, master: 1), 0, "a group outside the mix is dark while soloing")

        mix = GroupMix(ids: ids, masters: masters, overrides: GroupOverrides(soloed: [g1]))
        XCTAssertEqual((0..<3).map { mix.scale(group: $0, master: 1) }, [0.5, 0.25, 1], "a solo outside the layout is ignored")

        // A flash bypasses its group's master, never mute, solo or the global master.
        mix = GroupMix(ids: ids, masters: [.left: 0], overrides: GroupOverrides(flashing: [.left, .right], soloed: [.left]))
        XCTAssertEqual((0..<3).map { mix.scale(group: $0, master: 0.5) }, [0.5, 0, 0])
    }

    func testColourOverrideKeepsTheShapeAndNeverLightsADarkSegment() {
        var frame = RigFrame.black
        frame.center.rgb[0] = LightColor(1, 0.5, 0)
        frame.center.rgb[1] = LightColor(0, 0, 0.4)
        frame.center.cob[0] = 0.7
        let before = frame
        GroupMix(ids: ids).apply(to: &frame)
        XCTAssertEqual(frame, before, "no override, no change")

        let blue = GroupOverrides(colors: [.center: LightColor(0, 0, 1), .left: LightColor(1, 0, 0)])
        GroupMix(ids: ids, overrides: blue).apply(to: &frame)
        XCTAssertEqual(frame.center.rgb[0], LightColor(0, 0, 1))
        XCTAssertEqual(frame.center.rgb[1], LightColor(0, 0, 0.4))
        XCTAssertEqual(frame.center.rgb[2], .black)
        XCTAssertEqual(frame.center.cob, before.center.cob, "warm white stays the scene's")
        XCTAssertEqual(frame.left, before.left, "a dark group stays dark under a colour override")
        XCTAssertEqual(frame.right, before.right)
    }

    func testFlashPutsTheGroupAtFullInItsOverrideColour() {
        var frame = RigFrame.black
        let overrides = GroupOverrides(colors: [.right: LightColor(0, 1, 0)], flashing: [.center, .right])
        GroupMix(ids: ids, overrides: overrides).apply(to: &frame)
        XCTAssertTrue(frame.center.rgb.allSatisfy { $0 == LightColor(1, 1, 1) })
        XCTAssertTrue(frame.center.cob.allSatisfy { $0 == 1 })
        XCTAssertEqual(frame.right.rgb, [LightColor(0, 1, 0)])
        XCTAssertEqual(frame.right.cob, [1])
        XCTAssertEqual(frame.left, RigFrame.black.left)
    }

    func testBlackoutWinsOverEveryOverrideAndStrobeProgramChannelsStayZero() throws {
        let library = ProfileLibrary()
        let patch = VarytecRig.referenceRig()
        let roles = patch.roles(library: library)
        let groups = roles.map { ids.firstIndex(of: $0.groupID) ?? -1 }
        let all = Set(ids)
        let cases: [GroupOverrides] = [
            GroupOverrides(),
            GroupOverrides(flashing: all),
            GroupOverrides(colors: [.center: LightColor(1, 0, 1)], flashing: [.left], soloed: [.center]),
            GroupOverrides(colors: [.left: LightColor(0, 1, 1)], soloed: all, muted: [.right]),
        ]
        var frame = RigFrame.black
        for g in frame.groups.indices {
            for k in frame.groups[g].light.rgb.indices { frame.groups[g].light.rgb[k] = LightColor(1, 0.5, 0.2) }
            for k in frame.groups[g].light.cob.indices { frame.groups[g].light.cob[k] = 0.6 }
        }
        for overrides in cases {
            let mix = GroupMix(ids: ids, masters: [.left: 0, .center: 0.5], overrides: overrides)
            var f = frame
            mix.apply(to: &f)
            let levels = roles.map { FixtureLevels(f[$0]) }
            let scales = groups.map { mix.scale(group: $0, master: 1) }
            let lit = DMXComposer.compose(patch: patch, library: library, levels: levels, scales: scales, blackout: false)
            XCTAssertTrue(lit.values.contains { $0.contains { $0 > 0 } }, "\(overrides) lights something")
            for fixture in patch.fixtures {
                let profile = try XCTUnwrap(library.profile(id: fixture.profileID))
                let port = try XCTUnwrap(PortAddress(fixture.universe))
                let bytes = try XCTUnwrap(lit[port])
                for (offset, channel) in profile.channels.enumerated() where channel.kind == .ignore {
                    XCTAssertEqual(bytes[fixture.address - 1 + offset], 0, "strobe/program channels never move")
                }
            }
            let black = DMXComposer.compose(patch: patch, library: library, levels: levels, scales: scales, blackout: true)
            XCTAssertTrue(black.values.allSatisfy { $0.allSatisfy { $0 == 0 } }, "blackout wins over \(overrides)")
        }
    }

    // MARK: Engine

    private func makeEngine() -> (LightEngine, FakeTransport, ManualClock) {
        let transport = FakeTransport()
        let clock = ManualClock()
        let engine = LightEngine(
            tempo: LocalTempoClock(bpm: 120, now: { clock.now }), transport: transport, interfaces: { [Fixture.lan] },
            clock: { clock.now }, runsTimer: false)
        var patch = VarytecRig.referenceRig()
        patch.setConfirmed(true, library: ProfileLibrary())
        engine.start()
        engine.setPatch(patch)
        engine.setMaster(1)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        let red = CustomScene(
            base: .pulse, colors: Array(repeating: SceneRGB(r: 1, g: 0, b: 0), count: 3),
            program: SceneProgram(tracks: [ProgramTrack(target: .all, floor: 1, peak: 1)]))
        engine.setScene(.pulse, look: red, immediate: true)
        return (engine, transport, clock)
    }

    private func fixtures(_ engine: LightEngine) -> [FixtureVisual] {
        var state = EngineSnapshot()
        engine.onSnapshot = { state = $0 }
        engine.stepForTesting()
        engine.onSnapshot = nil
        return state.fixtures
    }

    private func peak(_ f: FixtureVisual) -> Double { f.rgb.map(\.peak).max() ?? 0 }

    func testEngineAppliesGroupMastersAndDirectCommandsToTheOutput() {
        let (engine, _, _) = makeEngine()
        let base = fixtures(engine)
        XCTAssertEqual(base.map(\.role), [.left, .center, .right])
        XCTAssertTrue(base.allSatisfy { peak($0) > 0.2 }, "every group lit")

        engine.setLevel(group: .left, 0.5)
        var f = fixtures(engine)
        XCTAssertEqual(peak(f[0]), peak(base[0]) * 0.5, accuracy: 1.0 / 255 + 1e-9)
        XCTAssertEqual(f[1].rgb, base[1].rgb)

        engine.setGroupMute(true, for: .center)
        f = fixtures(engine)
        XCTAssertTrue(f[1].isDark)
        XCTAssertFalse(f[2].isDark)
        engine.setGroupMute(false, for: .center)
        engine.setGroupSolo(true, for: .right)
        f = fixtures(engine)
        XCTAssertTrue(f[0].isDark)
        XCTAssertTrue(f[1].isDark)
        XCTAssertEqual(f[2], base[2])
        engine.setGroupSolo(false, for: .right)

        engine.setGroupColor(LightColor(0, 0, 1), for: .center)
        f = fixtures(engine)
        for (now, before) in zip(f[1].rgb, base[1].rgb) {
            XCTAssertEqual(now.r, 0)
            XCTAssertEqual(now.g, 0)
            XCTAssertEqual(now.b, before.peak, accuracy: 1.0 / 255 + 1e-9)
        }
        engine.setGroupColor(nil, for: .center)
        XCTAssertEqual(fixtures(engine)[1], base[1])

        engine.setLevel(group: .left, 0)
        engine.setGroupFlash(true, for: .left)
        f = fixtures(engine)
        XCTAssertTrue(f[0].rgb.allSatisfy { $0 == LightColor(1, 1, 1) }, "a flash bypasses its group's master")
        XCTAssertTrue(f[0].cob.allSatisfy { $0 == 1 })
        engine.setGroupFlash(false, for: .left)
        XCTAssertTrue(fixtures(engine)[0].isDark)

        engine.setLevel(group: .left, 1)
        engine.clearGroupOverrides()
        XCTAssertEqual(fixtures(engine), base)
    }

    func testBlackoutWinsOverFlashSoloAndColourAndReleasesTheFlash() {
        let (engine, transport, _) = makeEngine()
        engine.setArmed(true)
        let base = fixtures(engine)
        XCTAssertFalse(base.allSatisfy(\.isDark))
        engine.setGroupFlash(true, for: .center)
        engine.setGroupSolo(true, for: .center)
        engine.setGroupColor(LightColor(0, 1, 0), for: .center)
        XCTAssertFalse(fixtures(engine)[1].isDark)

        engine.setBlackout(true)
        let sentBefore = engine.sync { transport.dmxPackets.count }
        engine.setGroupFlash(true, for: .left)
        engine.setGroupMute(false, for: .right)
        XCTAssertTrue(fixtures(engine).allSatisfy(\.isDark), "blackout wins over flash, solo and colour")
        let packets = engine.sync { Array(transport.dmxPackets.dropFirst(sentBefore)) }
        XCTAssertFalse(packets.isEmpty, "blackout keeps transmitting zeros")
        XCTAssertTrue(packets.allSatisfy { $0.bytes.dropFirst((ArtNet.dmxPacketLength - ArtNet.dmxSlots)).allSatisfy { $0 == 0 } })

        // Leaving blackout never flashes: blackout released the flash, and a flash pressed during it was ignored.
        engine.setBlackout(false)
        XCTAssertTrue(fixtures(engine)[0].isDark, "solo on the centre still darkens the left")
        engine.setGroupSolo(false, for: .center)
        engine.setGroupColor(nil, for: .center)
        XCTAssertEqual(fixtures(engine), base)
    }

    func testDirectCommandsNeverTurnTheOutputOn() {
        let (engine, transport, _) = makeEngine()
        engine.setGroupFlash(true, for: .left)
        engine.setGroupSolo(true, for: .center)
        engine.setGroupMute(true, for: .right)
        engine.setGroupColor(LightColor(1, 1, 1), for: .center)
        engine.setLevel(group: g1, 1)
        engine.clearGroupOverrides()
        var state = EngineSnapshot()
        engine.onSnapshot = { state = $0 }
        engine.stepForTesting()
        XCTAssertFalse(state.armed)
        XCTAssertFalse(state.outputRequested)
        XCTAssertEqual(engine.sync { transport.dmxPackets.count }, 0)
    }
}
