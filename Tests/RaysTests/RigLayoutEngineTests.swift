import CoreGraphics
import XCTest
@testable import RaysOutput
@testable import RaysTempo
@testable import RaysCore
@testable import RaysEngine

/// Engine frames and preview model from the patch layout (ADR 0005, step 6): `PatchRig`, fitting the
/// choreography frames to any layout, the engine on 1, 2, 4 and 5 groups, and the classic preset
/// rendering exactly as before.
final class RigLayoutEngineTests: XCTestCase {
    let library = ProfileLibrary()
    let red = SceneRGB(r: 1, g: 0, b: 0)

    /// Group x positions, in layout order (deliberately not sorted).
    static let layouts: [[Double]] = [[0.3], [0.8, 0.1], [0.6, 0.1, 0.9, 0.35], [0.5, 1, 0, 0.75, 0.25]]

    // MARK: Helpers

    /// One group per x ("g0", "g1"… in layout order) with one TRI 180 8CH each, patched in reverse layout
    /// order, so neither the layout nor the patch order matches the order across the stage.
    func patch(_ xs: [Double], profile: String = "varytec.tri180.8") -> Patch {
        let groups = xs.enumerated().map { i, x in
            RigGroup(id: RigGroupID("g\(i)"), name: "G\(i)", position: StagePoint(x: x, y: 0.5))
        }
        let fixtures = Array(groups.indices.reversed()).enumerated().map { n, g in
            PatchedFixture(label: "F\(g)", profileID: profile, universe: 1, address: 1 + n * 8, group: groups[g].id)
        }
        var patch = Patch(fixtures: fixtures, layout: RigLayout(groups: groups))
        patch.setConfirmed(true, library: library)
        return patch
    }

    /// Group ids ordered left to right.
    func byX(_ xs: [Double]) -> [String] { xs.indices.sorted { xs[$0] < xs[$1] }.map { "g\($0)" } }

    /// Red chase over every RGB emitter, one hit per beat, held for half a beat so each hit peaks on the
    /// frame the engine renders 40 ms ahead of the beat.
    func chaseScene() -> CustomScene {
        let track = ProgramTrack(
            stepsPerBeat: 1, lengthBeats: 8, steps: Array(repeating: 1, count: 8), target: .all, motion: .chase,
            attack: 0, hold: 0.5, release: 0.2)
        return CustomScene(name: "Chase", base: .ambra, colors: [red, red, red], program: SceneProgram(tracks: [track]))
    }

    func makeEngine() -> (LightEngine, FakeTransport, ManualClock) {
        let transport = FakeTransport()
        let clock = ManualClock()
        let engine = LightEngine(
            tempo: LocalTempoClock(bpm: 120, now: { clock.now }), transport: transport, interfaces: { [Fixture.lan] },
            clock: { clock.now }, runsTimer: false)
        engine.start()
        engine.setMaster(1)
        engine.sync { transport.receive?(Fixture.pollReply(), .init(192, 168, 1, 50)) }
        return (engine, transport, clock)
    }

    func snapshot(_ engine: LightEngine) -> EngineSnapshot {
        var state = EngineSnapshot()
        engine.onSnapshot = { state = $0 }
        engine.stepForTesting()
        engine.onSnapshot = nil
        return state
    }

    func peak(_ f: FixtureVisual) -> Double { f.rgb.map(\.peak).max() ?? 0 }

    func rgb(_ n: Int) -> [ChannelDefinition] {
        (0..<n).flatMap { _ in [ChannelDefinition(.red), ChannelDefinition(.green), ChannelDefinition(.blue)] }
    }

    // MARK: PatchRig

    func testClassicPatchesKeepTheClassicRigAndFrame() {
        for patch in [VarytecRig.referenceRig(), VarytecRig.tri180Test(), Patch.empty] + GoldenFrameTests.rigs.map(\.patch) {
            let rig = PatchRig(patch: patch, library: library)
            XCTAssertTrue(rig.isClassic)
            XCTAssertEqual(rig.spatial, SpatialRig.classic)
            XCTAssertEqual(rig.black, RigFrame.black)
            let roles = patch.roles(library: library)
            XCTAssertEqual(rig.fixtureGroups, roles.map { [FixtureRole.left, .center, .right].firstIndex(of: $0)! })
        }
        // A centre bar of 12 zones still gets the classic 6-segment centre, resampled by its profile as before.
        let bar = FixtureProfile(id: "test.bar12", name: "Bar", channels: rgb(12))
        let patch = Patch(
            fixtures: [PatchedFixture(label: "Bar", profileID: bar.id, universe: 1, address: 1, role: .center)], customProfiles: [bar])
        XCTAssertEqual(PatchRig(patch: patch, library: library).black, RigFrame.black)
    }

    func testGroupsAreSizedFromTheirProfilesAndEmptyGroupsFromTheirShape() {
        let bar = FixtureProfile(id: "test.bar4", name: "Bar", channels: rgb(4) + [ChannelDefinition(.white)])
        let groups = [
            RigGroup(id: RigGroupID("a"), name: "A", position: StagePoint(x: 0.2, y: 0.5)),
            RigGroup(id: RigGroupID("b"), name: "B", shape: .strip, position: StagePoint(x: 0.5, y: 0.5)),
            RigGroup(id: RigGroupID("c"), name: "C", shape: .triangle, position: StagePoint(x: 0.8, y: 0.5)),
            RigGroup(id: RigGroupID("d"), name: "D", position: StagePoint(x: 0.9, y: 0.2)),
        ]
        let patch = Patch(
            fixtures: [
                PatchedFixture(label: "PAR", profileID: "generic.rgb3", universe: 1, address: 1, group: RigGroupID("a")),
                PatchedFixture(label: "Bar", profileID: bar.id, universe: 1, address: 4, group: RigGroupID("a")),
                PatchedFixture(label: "Lost", profileID: "generic.rgb3", universe: 1, address: 20, group: RigGroupID("x")),
            ],
            customProfiles: [bar], layout: RigLayout(groups: groups))
        let rig = PatchRig(patch: patch, library: library)
        XCTAssertFalse(rig.isClassic)
        XCTAssertEqual(rig.layout.groups.map(\.id.rawValue), ["a", "b", "c", "d", "x"], "a group the layout lacks is appended")
        XCTAssertEqual(rig.fixtureGroups, [0, 0, 4])
        let sizes = rig.black.groups.map { [$0.light.rgb.count, $0.light.cob.count] }
        XCTAssertEqual(sizes, [[4, 1], [8, 0], [1, 1], [1, 1], [1, 0]], "largest profile; placeholders by shape")
        // Two fixtures of a group without offsets are spread across x around the group.
        XCTAssertEqual(rig.fixturePositions[0].x, 0.2 - PatchRig.spread / 2, accuracy: 1e-12)
        XCTAssertEqual(rig.fixturePositions[1].x, 0.2 + PatchRig.spread / 2, accuracy: 1e-12)
        XCTAssertEqual(rig.fixturePositions[1].y, 0.5)

        // Preview-only lights: one placeholder per group without a patched fixture, nothing else.
        let shadow = rig.shadow(occupied: true)
        XCTAssertEqual(shadow.groups, [1, 2, 3])
        XCTAssertEqual(shadow.patch.fixtures.map(\.label), ["B", "C", "D"])
        XCTAssertEqual(shadow.patch.validate(library: library), [], "placeholders never overlap")
        let lib = shadow.patch.library(base: library)
        let appearances = shadow.patch.fixtures.map { lib.profile(id: $0.profileID)?.appearance.kind }
        XCTAssertEqual(appearances, [.strip, .triangle, .par])
        XCTAssertEqual(rig.shadow(occupied: false).groups, [0, 1, 2, 3, 4], "a patch not shown leaves every group to the preview")
    }

    func testOffsetsPlaceFixturesInsideTheirGroup() {
        let group = RigGroup(id: RigGroupID("a"), name: "A", position: StagePoint(x: 0.4, y: 0.6))
        let patch = Patch(
            fixtures: [
                PatchedFixture(label: "1", profileID: "generic.rgb3", universe: 1, address: 1, group: group.id),
                PatchedFixture(
                    label: "2", profileID: "generic.rgb3", universe: 1, address: 4, group: group.id, offset: StagePoint(x: 0.1, y: -0.2)),
                PatchedFixture(label: "3", profileID: "generic.rgb3", universe: 1, address: 7, group: group.id),
                PatchedFixture(label: "4", profileID: "generic.rgb3", universe: 1, address: 10, group: group.id),
            ],
            layout: RigLayout(groups: [group]))
        let positions = PatchRig(patch: patch, library: library).fixturePositions
        XCTAssertEqual(positions[1], StagePoint(x: 0.4 + 0.1, y: 0.6 - 0.2))
        XCTAssertEqual(positions[0].x, 0.4 - PatchRig.spread, accuracy: 1e-12)
        XCTAssertEqual(positions[2].x, 0.4, accuracy: 1e-12)
        XCTAssertEqual(positions[3].x, 0.4 + PatchRig.spread, accuracy: 1e-12)
        XCTAssertEqual(PatchRig(patch: patch, library: library), PatchRig(patch: patch, library: library), "deterministic")
    }

    func testPlaceholdersOnlyHaveColourAndWhiteChannels() {
        for shape in FixtureShape.allCases.map({ Optional($0) }) + [nil] {
            let profile = PatchRig.placeholder(for: shape)
            XCTAssertTrue(profile.problems.isEmpty, "\(String(describing: shape))")
            let kinds = Set(profile.channels.map(\.kind))
            if shape == .triangle {
                XCTAssertEqual(profile.id, "varytec.tri180.8")
            } else {
                XCTAssertTrue(kinds.isSubset(of: [.red, .green, .blue, .white, .blinder]), "\(String(describing: shape))")
                XCTAssertEqual(profile.appearance.kind, shape ?? .par)
            }
        }
    }

    // MARK: Fitting choreography frames

    func testClassicFramesAreUsedAsTheyAreOnTheClassicRig() {
        let frame = Choreography.render(.chase, SceneContext(beat: 3.3, energy: 0.8))
        XCTAssertTrue(SpatialRig.classic.matches(frame))
        XCTAssertEqual(SpatialRig.classic.fitting(frame), frame)
    }

    func testClassicFramesFollowRolesAndPositionsOnOtherLayouts() {
        let groups = [
            RigGroup(id: RigGroupID("a"), name: "A", position: StagePoint(x: 0, y: 0.5)),
            RigGroup(id: RigGroupID("b"), name: "B", position: StagePoint(x: 0.5, y: 0.5), roles: [TrackTarget.centerRole]),
            RigGroup(id: RigGroupID("c"), name: "C", position: StagePoint(x: 1, y: 0.5)),
            RigGroup(id: RigGroupID("d"), name: "D", position: StagePoint(x: 0.9, y: 0.5), roles: [TrackTarget.sideRole]),
        ]
        let sizes = RigFrame(groups: [
            GroupFrame(id: RigGroupID("a"), light: .black(rgb: 1, cob: 1)),
            GroupFrame(id: RigGroupID("b"), light: .black(rgb: 2, cob: 1)),
            GroupFrame(id: RigGroupID("c"), light: .black(rgb: 1, cob: 1)),
            GroupFrame(id: RigGroupID("d"), light: .black(rgb: 1, cob: 1)),
        ])
        let rig = SpatialRig(layout: RigLayout(groups: groups), sizes: sizes)
        var source = RigFrame.black
        source.left = RoleFrame(rgb: [LightColor(1, 0, 0)], cob: [0.1])
        source.right = RoleFrame(rgb: [LightColor(0, 0, 1)], cob: [0.9])
        source.center = RoleFrame(rgb: (0..<6).map { LightColor(Double($0) / 5, 0.5, 0) }, cob: [0.3, 0.6, 0.9])
        let fitted = rig.fitting(source)
        XCTAssertTrue(rig.matches(fitted))
        XCTAssertEqual(fitted.groups[0].light, source.left, "x 0 takes the left light")
        XCTAssertEqual(fitted.groups[2].light, source.right, "x 1 takes the right light")
        XCTAssertEqual(fitted.groups[3].light, source.right, "a side group on the right half follows the right light")
        let centre = FixtureLevels(source.center).resampled(rgbCount: 2, cobCount: 1)
        XCTAssertEqual(fitted.groups[1].light, RoleFrame(rgb: centre.rgb, cob: centre.cob), "the centre role follows the centre light")
        // A frame of another shape leaves groups it does not know black.
        let other = RigFrame(groups: [GroupFrame(id: RigGroupID("c"), light: RoleFrame(rgb: [LightColor(0, 1, 0)], cob: [1]))])
        let expected: [RoleFrame] = [.black(rgb: 1, cob: 1), .black(rgb: 2, cob: 1), other.groups[0].light, .black(rgb: 1, cob: 1)]
        XCTAssertEqual(rig.fitting(other).groups.map(\.light), expected)
    }

    // MARK: Classic preset: byte-identical

    /// The engine renders through `render(…, rig:)` with looks compiled for the patch rig; on the golden rigs
    /// that is exactly the classic rendering the golden table hashes.
    func testGoldenRigsRenderTheSameFramesThroughThePatchRig() {
        for golden in GoldenFrameTests.rigs {
            let rig = PatchRig(patch: golden.patch, library: library).spatial
            for c in GoldenFrameTests.cases {
                var classic = SceneSequencer(scene: c.scene, rate: c.rate)
                var patched = classic
                if let look = c.look {
                    classic.setLook(SceneLook(look))
                    patched.setLook(SceneLook(look, rig: rig))
                }
                var cues = c.cues[...]
                for beat in stride(from: 0.0, to: 34, by: 0.375) {
                    let now = beat / 2
                    while let cue = cues.first, cue.beat <= beat {
                        if let scene = cue.scene {
                            classic.request(scene, look: cue.look.map { SceneLook($0) }, beat: beat, now: now, gridTrusted: true)
                            patched.request(scene, look: cue.look.map { SceneLook($0, rig: rig) }, beat: beat, now: now, gridTrusted: true)
                        } else {
                            classic.stop(beat: beat, now: now, gridTrusted: true)
                            patched.stop(beat: beat, now: now, gridTrusted: true)
                        }
                        cues = cues.dropFirst()
                    }
                    classic.advance(beat: beat, bpm: 120, now: now, gridTrusted: true)
                    patched.advance(beat: beat, bpm: 120, now: now, gridTrusted: true)
                    XCTAssertEqual(
                        patched.render(beat: beat, energy: 0.7, now: now, rig: rig), classic.render(beat: beat, energy: 0.7, now: now),
                        "\(c.name) on \(golden.name) at beat \(beat)")
                }
            }
        }
    }

    func testOldPatchWithoutLayoutYieldsTodaysPreview() throws {
        let (engine, _, _) = makeEngine()

        // Empty patch: the reference rig as preview-only lights.
        var s = snapshot(engine)
        XCTAssertEqual(s.fixtures.map(\.id), ["preview-left", "preview-center", "preview-right"])
        XCTAssertEqual(s.fixtures.map(\.label), VarytecRig.referenceRig().fixtures.map(\.label))
        XCTAssertEqual(s.fixtures.map(\.profileID), ["varytec.tri180.8", "varytec.tri380.25", "varytec.tri180.8"])
        XCTAssertEqual(s.fixtures.map(\.role), [.left, .center, .right])
        XCTAssertEqual(s.fixtures.map(\.address), [8, 24, 16])
        XCTAssertTrue(s.fixtures.allSatisfy { $0.status == .previewOnly })
        XCTAssertFalse(s.freeLayout)

        // One patched TRI 180 (role guessed left): the centre and right stay preview-only, as before.
        let single = VarytecRig.tri180Test()
        engine.setPatch(single)
        s = snapshot(engine)
        XCTAssertEqual(s.fixtures.map(\.id), [single.fixtures[0].id.uuidString, "preview-center", "preview-right"])
        XCTAssertEqual(s.fixtures.map(\.role), [.left, .center, .right])
        XCTAssertEqual(s.fixtures.map(\.status), [.off, .previewOnly, .previewOnly])

        // The reference rig: three real lights in the classic order, at the classic positions.
        let reference = VarytecRig.referenceRig()
        engine.setPatch(reference)
        s = snapshot(engine)
        XCTAssertEqual(s.fixtures.map(\.id), reference.fixtures.map(\.id.uuidString))
        XCTAssertEqual(s.fixtures.map(\.role), [.left, .center, .right])
        XCTAssertEqual(s.fixtures.map(\.group), [.left, .center, .right])
        XCTAssertEqual(s.fixtures.map(\.position), RigLayout.classic.groups.map { Optional($0.position) })
        XCTAssertEqual(s.fixtures.map(\.appearance), Array(repeating: Optional(VarytecRig.triangle), count: 3))
        XCTAssertEqual(s.fixtures.map { [$0.rgb.count, $0.cob.count] }, [[1, 1], [6, 3], [1, 1]])
        XCTAssertEqual(s.fixtures.map(\.status), [.off, .off, .off])
        XCTAssertFalse(s.freeLayout)

        // The same bytes as composing the classic frame by role, as the engine did before layouts.
        let look = CustomScene(
            base: .pulse, colors: [red, red, red], program: SceneProgram(tracks: [ProgramTrack(target: .all, floor: 1, peak: 1)]))
        engine.setScene(.pulse, look: look, immediate: true)
        s = snapshot(engine)
        let frame = SceneLook(look).render(.pulse, SceneContext(beat: 0, energy: 0.5))
        let levels = reference.roles(library: library).map { FixtureLevels(rgb: frame[$0].rgb, cob: frame[$0].cob) }
        let dmx = DMXComposer.compose(patch: reference, library: library, levels: levels, scales: [1, 1, 1], blackout: false)
        let universe = try XCTUnwrap(dmx[try XCTUnwrap(PortAddress(1))])
        for (visual, fixture) in zip(s.fixtures, reference.fixtures) {
            let profile = try XCTUnwrap(library.profile(id: fixture.profileID))
            let expected = DMXComposer.decode(profile: profile, universe: universe, address: fixture.address)
            XCTAssertEqual(visual.rgb, expected.rgb)
            XCTAssertEqual(visual.cob, expected.cob)
        }
    }

    // MARK: Engine on 1, 2, 4 and 5 groups

    func testEngineChaseRunsAcrossTheStageByXAndPeaksAtFull() throws {
        for xs in Self.layouts {
            let (engine, _, clock) = makeEngine()
            // The look is compiled before the patch arrives: the engine compiles it again for the new rig.
            engine.setScene(.ambra, look: chaseScene(), immediate: true)
            let p = patch(xs)
            engine.setPatch(p)
            let order = byX(xs)
            var hits = Set<Int>()
            for _ in 0..<(30 * xs.count + 30) {
                clock.now += 1 / 30
                let s = snapshot(engine)
                XCTAssertTrue(s.freeLayout)
                XCTAssertEqual(s.fixtures.count, xs.count, "every group has its light, no placeholder")
                let beat = try XCTUnwrap(s.patternBeat)
                let frac = beat - beat.rounded(.down)
                guard frac > 0.05, frac < 0.45 else { continue }
                let hit = Int(beat.rounded(.down))
                let expected = order[((hit % xs.count) + xs.count) % xs.count]
                for f in s.fixtures {
                    if f.group?.rawValue == expected {
                        XCTAssertEqual(peak(f), 1, accuracy: 1e-9, "\(xs.count) groups: hit \(hit) peaks on \(expected)")
                        XCTAssertEqual(f.r, 1, accuracy: 1e-9)
                    } else {
                        XCTAssertEqual(peak(f), 0, accuracy: 1e-9, "\(xs.count) groups: only \(expected) is lit on hit \(hit)")
                    }
                }
                hits.insert(hit % xs.count)
            }
            XCTAssertEqual(hits.count, xs.count, "\(xs.count) groups: the chase reached every position")
        }
    }

    func testEngineNeverMovesStrobeOrProgramChannelsAndBlackoutZeroesEverything() throws {
        let profile = try XCTUnwrap(library.profile(id: "varytec.tri180.8"))
        let ignored = profile.channels.indices.filter { profile.channels[$0].kind == .ignore }
        XCTAssertFalse(ignored.isEmpty)
        for xs in Self.layouts {
            let (engine, transport, clock) = makeEngine()
            let p = patch(xs)
            engine.setPatch(p)
            engine.setArmed(true)
            let looks: [(SceneID, CustomScene?)] = SceneID.allCases.map { ($0, nil) } + [(.ambra, chaseScene())]
            var lit = false
            for (scene, look) in looks {
                engine.setScene(scene, look: look, immediate: true)
                engine.setAccent(scene == .pulse)
                for _ in 0..<45 {
                    clock.now += 1 / 30
                    let s = snapshot(engine)
                    if s.fixtures.contains(where: { !$0.isDark }) { lit = true }
                }
            }
            XCTAssertTrue(lit, "\(xs.count) groups light up")
            let packets = engine.sync { transport.dmxPackets }
            XCTAssertFalse(packets.isEmpty)
            let header = ArtNet.dmxPacketLength - ArtNet.dmxSlots
            for packet in packets {
                let data = Array(packet.bytes.dropFirst(header))
                for fixture in p.fixtures {
                    for offset in ignored {
                        XCTAssertEqual(data[fixture.address - 1 + offset], 0, "\(xs.count) groups: strobe/program channel moved")
                    }
                }
            }
            engine.setBlackout(true)
            let before = engine.sync { transport.dmxPackets.count }
            clock.now += 1 / 30
            XCTAssertTrue(snapshot(engine).fixtures.allSatisfy(\.isDark), "\(xs.count) groups: blackout")
            let black = engine.sync { Array(transport.dmxPackets.dropFirst(before)) }
            XCTAssertFalse(black.isEmpty)
            let zeroed = black.allSatisfy { $0.bytes.dropFirst(header).allSatisfy { $0 == 0 } }
            XCTAssertTrue(zeroed, "\(xs.count) groups: blackout zeroes everything")
        }
    }

    func testEngineGroupMastersAndSoloFollowTheLayout() {
        let xs = [0.6, 0.1, 0.9, 0.35]
        let (engine, _, _) = makeEngine()
        engine.setPatch(patch(xs))
        let steady = SceneProgram(tracks: [ProgramTrack(target: .all, floor: 1, peak: 1)])
        engine.setScene(.ambra, look: CustomScene(base: .ambra, colors: [red, red, red], program: steady), immediate: true)
        var s = snapshot(engine)
        XCTAssertTrue(s.fixtures.allSatisfy { peak($0) > 0.99 }, "every group lit by an all target")
        engine.setLevel(group: RigGroupID("g2"), 0)
        s = snapshot(engine)
        XCTAssertEqual(s.fixtures.filter { peak($0) < 1e-9 }.map(\.group), [RigGroupID("g2")], "a group master reaches its group only")
        engine.setGroupSolo(true, for: RigGroupID("g1"))
        s = snapshot(engine)
        XCTAssertEqual(s.fixtures.filter { peak($0) > 0.5 }.map(\.group), [RigGroupID("g1")])
    }

    func testPreviewModelOfAFreeLayout() throws {
        let groups = [
            RigGroup(id: RigGroupID("back"), name: "Back", shape: .bar, position: StagePoint(x: 0.5, y: 0.1)),
            RigGroup(id: RigGroupID("l"), name: "L", position: StagePoint(x: 0.1, y: 0.8)),
        ]
        let patch = Patch(
            fixtures: [PatchedFixture(label: "PAR", profileID: "generic.rgbw4", universe: 1, address: 1, group: RigGroupID("l"))],
            layout: RigLayout(groups: groups))
        let (engine, _, _) = makeEngine()
        engine.setPatch(patch)
        let s = snapshot(engine)
        XCTAssertTrue(s.freeLayout)
        XCTAssertEqual(s.fixtures.map(\.id), ["preview-back", patch.fixtures[0].id.uuidString], "layout order")
        XCTAssertEqual(s.fixtures.map(\.status), [.previewOnly, .off])
        XCTAssertEqual(s.fixtures.map(\.group), [RigGroupID("back"), RigGroupID("l")])
        XCTAssertEqual(s.fixtures.map(\.position), [StagePoint(x: 0.5, y: 0.1), StagePoint(x: 0.1, y: 0.8)])
        XCTAssertEqual(s.fixtures.map(\.appearance?.kind), [.bar, .par])
        XCTAssertEqual(s.fixtures.map(\.role), [.center, .left])
        XCTAssertEqual(s.fixtures[0].rgb.count, 4, "the bar placeholder has its four zones")
    }

    // MARK: Stage layout

    func testStagePositionsReplaceTheRowOnlyWhenGiven() {
        let size = CGSize(width: 990, height: 460)
        let row = [StageFixtureSpec.triangle(large: false), .triangle(large: true), .triangle(large: false)]
        let classic = StageLayout(size: size, large: [false, true, false])
        XCTAssertEqual(StageLayout(size: size, specs: row), classic, "no position: the row, unchanged")

        // The classic positions put the lights where the row does.
        var placed = row
        for (i, p) in RigLayout.classic.groups.map(\.position).enumerated() { placed[i].position = p }
        let layout = StageLayout(size: size, specs: placed)
        for (a, b) in zip(layout.fixtures, classic.fixtures) {
            XCTAssertEqual(a.center.x, b.center.x, accuracy: 1e-9)
            XCTAssertEqual(a.center.y, b.center.y, accuracy: 1e-9)
        }

        // Positions decide x order and depth: the front light stands lower on the canvas.
        var free = row
        free[0].position = StagePoint(x: 0.9, y: 0.5)
        free[1].position = StagePoint(x: 0.5, y: 0.1)
        free[2].position = StagePoint(x: 0.1, y: 0.9)
        let moved = StageLayout(size: size, specs: free).fixtures
        XCTAssertGreaterThan(moved[0].center.x, moved[1].center.x)
        XCTAssertGreaterThan(moved[1].center.x, moved[2].center.x)
        XCTAssertGreaterThan(moved[2].labelCenter.y, moved[0].labelCenter.y)
        XCTAssertLessThan(moved[1].labelCenter.y, moved[0].labelCenter.y)

        // A spec without a position keeps the whole layout in the row.
        free[1].position = nil
        let mixed = StageLayout(size: size, specs: free)
        XCTAssertEqual(mixed.fixtures.map(\.center), classic.fixtures.map(\.center))
    }
}
