import XCTest
@testable import RaysCore

/// Spatial targets (ADR 0005, step 4): emitter positions generated from the rig layout, role, ordering
/// and explicit-group targets, and saved targets of older versions.
final class SpatialTargetTests: XCTestCase {
    let red = SceneRGB(r: 1, g: 0, b: 0), green = SceneRGB(r: 0, g: 1, b: 0), blue = SceneRGB(r: 0, g: 0, b: 1)

    // MARK: Helpers

    /// A layout of single-emitter groups (1 RGB + 1 COB) at the given x, ids "g0", "g1"… in layout order.
    func rig(_ xs: [Double], roles: [Set<String>]? = nil) -> SpatialRig {
        let groups = xs.enumerated().map { i, x in
            RigGroup(id: RigGroupID("g\(i)"), name: "G\(i)", position: StagePoint(x: x, y: 0.5), roles: roles?[i] ?? [])
        }
        let sizes = RigFrame(groups: groups.map { GroupFrame(id: $0.id, light: .black(rgb: 1, cob: 1)) })
        return SpatialRig(layout: RigLayout(groups: groups), sizes: sizes)
    }

    func scene(_ tracks: [ProgramTrack]) -> CustomScene {
        CustomScene(name: "Spatial", base: .ambra, colors: [red, green, blue], program: SceneProgram(tracks: tracks))
    }

    /// One hit per beat, short enough that only the current hit is lit on each beat.
    /// Eight hits, one per beat: hit k reaches chase position k modulo the number of positions.
    func chase(_ target: TrackTarget = .all, direction: TrackDirection = .forward) -> ProgramTrack {
        ProgramTrack(
            stepsPerBeat: 1, lengthBeats: 8, steps: Array(repeating: 1, count: 8), target: target, motion: .chase,
            direction: direction, attack: 0, hold: 0, release: 0.2)
    }

    func steady(_ target: TrackTarget) -> ProgramTrack {
        ProgramTrack(stepsPerBeat: 1, lengthBeats: 4, steps: [0, 0, 0, 0], target: target, floor: 1, peak: 1)
    }

    func render(_ s: CustomScene, _ rig: SpatialRig, beat: Double) -> RigFrame {
        SceneLook(s, rig: rig).render(.ambra, SceneContext(beat: beat, phrase: beat, energy: 1))
    }

    /// Ids of the groups whose RGB is lit, in layout order.
    func lit(_ f: RigFrame) -> [String] {
        f.groups.filter { $0.light.rgb.contains { $0.peak > 0.5 } }.map(\.id.rawValue)
    }

    func assertClose(_ a: [Double], _ b: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-12, file: file, line: line) }
    }

    func json(_ text: String) throws -> TrackTarget { try JSONDecoder().decode(TrackTarget.self, from: Data(text.utf8)) }

    func object(_ target: TrackTarget) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any])
    }

    // MARK: Emitter positions

    func testClassicLayoutReproducesTheFormerFixedTablesExactly() {
        let rig = SpatialRig.classic
        let rgb = rig.rgb.map { (rig.groups[$0.group].id, $0.index, $0.x) }
        let oldRGB: [(RigGroupID, Int, Double)] =
            [(.left, 0, 0)] + (0..<6).map { (.center, 5 - $0, Double($0 + 1) / 7) } + [(.right, 0, 1)]
        XCTAssertEqual(rgb.count, oldRGB.count)
        for (a, b) in zip(rgb, oldRGB) {
            XCTAssertEqual(a.0, b.0); XCTAssertEqual(a.1, b.1)
            XCTAssertEqual(a.2.bitPattern, b.2.bitPattern, "x of \(b.0) \(b.1) must be bit-identical")
        }
        let cob = rig.cob.map { (rig.groups[$0.group].id, $0.index, $0.x) }
        let oldCOB: [(RigGroupID, Int, Double)] = [
            (.left, 0, 0), (.center, 2, 2.0 / 7), (.center, 0, 0.5), (.center, 1, 5.0 / 7), (.right, 0, 1),
        ]
        XCTAssertEqual(cob.count, oldCOB.count)
        for (a, b) in zip(cob, oldCOB) {
            XCTAssertEqual(a.0, b.0); XCTAssertEqual(a.1, b.1)
            XCTAssertEqual(a.2.bitPattern, b.2.bitPattern, "x of COB \(b.0) \(b.1) must be bit-identical")
        }
        XCTAssertTrue(rig.rgb.allSatisfy { !$0.cob }); XCTAssertTrue(rig.cob.allSatisfy(\.cob))
        XCTAssertEqual(rig.black, RigFrame.black)
        XCTAssertEqual(rig.xRank, [0, 1, 2]); XCTAssertEqual(rig.xPositions, 3)
    }

    func testClassicLookEqualsTheDefaultLookAndRendersTheSame() {
        let s = scene([chase(), .template(.hat), .template(.clap)])
        XCTAssertEqual(SceneLook(s), SceneLook(s, rig: .classic))
        for beat in stride(from: 0.0, through: 8, by: 0.25) {
            let ctx = SceneContext(beat: beat, phrase: beat, energy: 0.7)
            XCTAssertEqual(SceneLook(s).render(.pulse, ctx), SceneLook(s, rig: .classic).render(.pulse, ctx))
        }
        XCTAssertNotEqual(SceneLook(s), SceneLook(s, rig: rig([0, 1])), "a look on another rig is another look")
    }

    func testSegmentsOfAGroupSpreadBetweenItsNeighboursWithoutInterleaving() {
        func layout(_ specs: [(x: Double, rgb: Int)]) -> SpatialRig {
            let groups = specs.enumerated().map { i, s in
                RigGroup(id: RigGroupID("g\(i)"), name: "G", position: StagePoint(x: s.x, y: 0))
            }
            let sizes = RigFrame(groups: zip(groups, specs).map { GroupFrame(id: $0.id, light: .black(rgb: $1.rgb, cob: 1)) })
            return SpatialRig(layout: RigLayout(groups: groups), sizes: sizes)
        }
        // A 4-zone bar between two PARs stays strictly between them, in channel order.
        var r = layout([(0.2, 1), (0.5, 4), (0.9, 1)])
        let bar = r.rgb.filter { $0.group == 1 }
        XCTAssertEqual(bar.map(\.index), [0, 1, 2, 3])
        XCTAssertTrue(bar.allSatisfy { $0.x > 0.2 && $0.x < 0.9 })
        assertClose(bar.map(\.x), [0.32, 0.44, 0.56, 0.68])
        XCTAssertEqual(r.rgb.map(\.group), [0, 1, 1, 1, 1, 2])
        // Two bars next to each other share the gap and never interleave.
        r = layout([(0.4, 3), (0.6, 3)])
        let a = r.rgb.filter { $0.group == 0 }.map(\.x), b = r.rgb.filter { $0.group == 1 }.map(\.x)
        XCTAssertLessThan(a.max() ?? 1, b.min() ?? 0)
        XCTAssertEqual(r.rgb.map(\.group), [0, 0, 0, 1, 1, 1])
        // A lone bar spreads over half a stage either side.
        r = layout([(0.5, 3)])
        assertClose(r.rgb.map(\.x), [0.25, 0.5, 0.75])
    }

    // MARK: Spatial ordering on other layouts

    func testChaseFollowsGroupXNotLayoutOrderOnOneTwoFourAndFiveGroups() {
        let layouts: [[Double]] = [[0.3], [0.8, 0.1], [0.9, 0.2, 0.6, 0.4], [0.5, 1, 0, 0.75, 0.25]]
        for xs in layouts {
            let r = rig(xs)
            let byX = xs.indices.sorted { xs[$0] < xs[$1] }.map { "g\($0)" }
            let n = xs.count
            let forward = scene([chase()])
            let backward = scene([chase(direction: .backward)])
            for k in 0..<n {
                XCTAssertEqual(lit(render(forward, r, beat: Double(k))), [byX[k]], "\(n) groups, hit \(k + 1)")
                XCTAssertEqual(lit(render(backward, r, beat: Double(k))), [byX[n - 1 - k]], "\(n) groups reversed, hit \(k + 1)")
                // The chase wraps around after the last position.
                XCTAssertEqual(lit(render(forward, r, beat: Double(k + n))), [byX[k]])
            }
            // Frames follow the rig's layout, one group each, in layout order.
            XCTAssertEqual(render(forward, r, beat: 0).groups.map(\.id.rawValue), xs.indices.map { "g\($0)" })
        }
    }

    func testGroupsAtTheSameXMoveTogetherDeterministically() {
        // g1 and g3 share x = 0.5: three positions, the tied pair lights on the same hit.
        let r = rig([0.9, 0.5, 0.1, 0.5])
        XCTAssertEqual(r.xRank, [2, 1, 0, 1]); XCTAssertEqual(r.xPositions, 3)
        XCTAssertEqual(r.rgb.map(\.group), [2, 1, 3, 0], "ties keep layout order")
        let s = scene([chase()])
        XCTAssertEqual(lit(render(s, r, beat: 0)), ["g2"])
        XCTAssertEqual(lit(render(s, r, beat: 1)), ["g1", "g3"])
        XCTAssertEqual(lit(render(s, r, beat: 2)), ["g0"])
        // Same input, same output.
        XCTAssertEqual(rig([0.9, 0.5, 0.1, 0.5]), r)
        XCTAssertEqual(render(s, rig([0.9, 0.5, 0.1, 0.5]), beat: 1), render(s, r, beat: 1))
    }

    func testFromTheCentreRanksByDistanceFromTheMiddleOfTheStage() {
        let r = rig([0, 0.4, 0.55, 1])
        let s = scene([chase(direction: .center)])
        XCTAssertEqual(lit(render(s, r, beat: 0)), ["g2"], "0.05 from the centre")
        XCTAssertEqual(lit(render(s, r, beat: 1)), ["g1"], "0.1 from the centre")
        XCTAssertEqual(lit(render(s, r, beat: 2)), ["g0", "g3"], "both edges together")
    }

    // MARK: Role, ordering and explicit-group targets

    func testHalvesFollowTheXOrdering() {
        let left = TrackTarget(selection: .half(.left)), right = TrackTarget(selection: .half(.right))
        // 4 groups: two on each side.
        var r = rig([0.9, 0.2, 0.6, 0.4])
        XCTAssertEqual(lit(render(scene([steady(left)]), r, beat: 0)), ["g1", "g3"])
        XCTAssertEqual(lit(render(scene([steady(right)]), r, beat: 0)), ["g0", "g2"])
        // 5 groups: the middle one belongs to neither half.
        r = rig([0.5, 1, 0, 0.75, 0.25])
        XCTAssertEqual(lit(render(scene([steady(left)]), r, beat: 0)), ["g2", "g4"])
        XCTAssertEqual(lit(render(scene([steady(right)]), r, beat: 0)), ["g1", "g3"])
        // 1 group: no halves.
        XCTAssertEqual(lit(render(scene([steady(left)]), rig([0.5]), beat: 0)), [])
    }

    func testRoleAndExplicitGroupTargets() {
        let r = rig([0, 0.3, 0.6, 1], roles: [["side"], ["center", "accent"], ["center"], ["side"]])
        XCTAssertEqual(lit(render(scene([steady(.centerOnly)]), r, beat: 0)), ["g1", "g2"])
        XCTAssertEqual(lit(render(scene([steady(.sides)]), r, beat: 0)), ["g0", "g3"])
        XCTAssertEqual(lit(render(scene([steady(TrackTarget(selection: .role("accent")))]), r, beat: 0)), ["g1"])
        XCTAssertEqual(lit(render(scene([steady(.all)]), r, beat: 0)), ["g0", "g1", "g2", "g3"])
        let picked = TrackTarget(selection: .groups([RigGroupID("g3"), RigGroupID("g0"), RigGroupID("missing")]))
        XCTAssertEqual(lit(render(scene([steady(picked)]), r, beat: 0)), ["g0", "g3"])
        // Masks on explicit groups select segments and COBs inside them.
        let bars = RigLayout(groups: [RigGroup(id: RigGroupID("bar"), name: "Bar"), RigGroup(id: RigGroupID("par"), name: "Par")])
        let sizes = RigFrame(groups: [
            GroupFrame(id: RigGroupID("bar"), light: .black(rgb: 4, cob: 2)),
            GroupFrame(id: RigGroupID("par"), light: .black(rgb: 1, cob: 1)),
        ])
        let masked = TrackTarget(
            selection: .groups([RigGroupID("bar")]), color: true, warm: true,
            masks: [RigGroupID("bar"): TrackTarget.Mask(segments: [false, true, false, true], cobs: [true, false])])
        let f = render(scene([steady(masked)]), SpatialRig(layout: bars, sizes: sizes), beat: 0)
        XCTAssertEqual(f.groups[0].light.rgb.map(\.peak), [0, 1, 0, 1])
        XCTAssertEqual(f.groups[0].light.cob, [1, 0])
        XCTAssertEqual(f.groups[1].light.rgb.map(\.peak), [0]); XCTAssertEqual(f.groups[1].light.cob, [0])
    }

    func testClassicBooleansAndZonesMapOntoRoleAndOrderingTargets() {
        XCTAssertEqual(TrackTarget.all.selection, .all)
        XCTAssertEqual(TrackTarget.centerOnly.selection, .role("center"))
        XCTAssertEqual(TrackTarget.sides.selection, .role("side"))
        XCTAssertEqual(TrackTarget(center: false, right: false).selection, .half(.left))
        XCTAssertEqual(TrackTarget(left: false, center: false).selection, .half(.right))
        XCTAssertEqual(TrackTarget(right: false).selection, .groups([.left, .center]))
        XCTAssertEqual(TrackTarget(left: false, center: false, right: false).selection, .groups([]))
        for zone in TrackTarget.Zone.allCases {
            var t = TrackTarget(selection: .groups([RigGroupID("x")]))
            XCTAssertNil(t.zone)
            t.setZone(zone)
            XCTAssertEqual(t.zone, zone)
        }
        // Toggling a classic position works on the classic view of the selection.
        var t = TrackTarget.all
        t.left.toggle()
        XCTAssertEqual(t.selection, .groups([.center, .right]))
        XCTAssertEqual([t.left, t.center, t.right], [false, true, true])
        t.left.toggle()
        XCTAssertEqual(t, .all)
        t = TrackTarget(selection: .role("accent"))
        XCTAssertEqual([t.left, t.center, t.right], [false, false, false], "a tag the classic layout lacks reaches none of it")
        XCTAssertFalse(t.isEmpty, "but it is not empty on a layout that has it")
        t.center = true
        XCTAssertEqual(t.selection, .role("center"))
    }

    func testEmptyTargetsAreRecognised() {
        XCTAssertTrue(TrackTarget(selection: .groups([])).isEmpty)
        XCTAssertTrue(TrackTarget(selection: .all, color: false, warm: false).isEmpty)
        var centre = TrackTarget.centerOnly
        centre.segments = Array(repeating: false, count: 6); centre.cobs = Array(repeating: false, count: 3)
        XCTAssertTrue(centre.isEmpty)
        let masked = TrackTarget(selection: .groups([RigGroupID("b")]), masks: [RigGroupID("b"): TrackTarget.Mask(segments: [false])])
        XCTAssertTrue(masked.isEmpty)
        XCTAssertFalse(TrackTarget(selection: .groups([RigGroupID("b")])).isEmpty)
    }

    // MARK: Saved files

    func testOldTargetsDecodeToTheSameValuesAndReencodeWithOnlyTheOldKeys() throws {
        // Targets as the current release writes them (one JSON object per line, split only to fit).
        func old(
            _ flags: String, _ light: String, segments: String = "[true,true,true,true,true,true]", cobs: String = "[true,true,true]"
        ) -> String {
            "{\(flags),\(light),\"segments\":\(segments),\"cobs\":\(cobs)}"
        }
        let samples: [(String, TrackTarget)] = [
            (old(#""left":true,"center":true,"right":true"#, #""color":true,"warm":false"#), .all),
            (
                old(
                    #""left":false,"center":true,"right":false"#, #""color":true,"warm":false"#,
                    segments: "[true,false,true,false,true,false]"),
                TrackTarget(left: false, right: false, segments: [true, false, true, false, true, false])
            ),
            (
                old(#""left":true,"center":false,"right":true"#, #""color":false,"warm":true"#, cobs: "[false,true,false]"),
                TrackTarget(center: false, color: false, warm: true, cobs: [false, true, false])
            ),
            (old(#""left":true,"center":false,"right":false"#, #""color":true,"warm":false"#), TrackTarget(center: false, right: false)),
            (
                old(#""left":false,"center":false,"right":true"#, #""color":true,"warm":true"#),
                TrackTarget(left: false, center: false, warm: true)
            ),
            (old(#""left":true,"center":true,"right":false"#, #""color":true,"warm":false"#), TrackTarget(right: false)),
            (
                old(#""left":false,"center":false,"right":false"#, #""color":true,"warm":false"#),
                TrackTarget(left: false, center: false, right: false)
            ),
        ]
        for (text, expected) in samples {
            let decoded = try json(text)
            XCTAssertEqual(decoded, expected, text)
            XCTAssertEqual(decoded.masks, [:])
            // Written back exactly as an older version wrote it: same keys, same values.
            let written = try object(decoded) as NSDictionary
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
            XCTAssertEqual(written, original, text)
        }
        // Missing and broken keys keep their defaults, short masks are padded as before.
        XCTAssertEqual(try json("{}"), .all)
        XCTAssertEqual(try json(#"{"left":"yes","center":false,"segments":[false]}"#).selection, .role("side"))
        XCTAssertEqual(try json(#"{"segments":[false]}"#).segments, [false, true, true, true, true, true])
    }

    func testNewTargetKindsRoundTripAndStayReadableByOlderVersions() throws {
        let accent = TrackTarget(selection: .role("accent"), warm: true)
        let picked = TrackTarget(
            selection: .groups([RigGroupID("g-1"), .center]), masks: [RigGroupID("g-1"): TrackTarget.Mask(segments: [true, false])])
        let centreGroup = TrackTarget(selection: .groups([.center]))
        for t in [accent, picked, centreGroup, TrackTarget(selection: .half(.left)), .all] {
            XCTAssertEqual(try JSONDecoder().decode(TrackTarget.self, from: JSONEncoder().encode(t)), t)
        }
        // The classic keys are always there, holding the target as it lands on the classic layout.
        var o = try object(accent)
        XCTAssertEqual(o["left"] as? Bool, false); XCTAssertEqual(o["center"] as? Bool, false)
        XCTAssertEqual(o["right"] as? Bool, false)
        XCTAssertEqual((o["select"] as? [String: Any])?["kind"] as? String, "role")
        XCTAssertEqual((o["select"] as? [String: Any])?["role"] as? String, "accent")
        XCTAssertNil(o["masks"])
        o = try object(picked)
        XCTAssertEqual(o["center"] as? Bool, true); XCTAssertEqual(o["left"] as? Bool, false)
        XCTAssertEqual((o["select"] as? [String: Any])?["groups"] as? [String], ["g-1", "center"])
        XCTAssertEqual(((o["masks"] as? [String: Any])?["g-1"] as? [String: Any])?["segments"] as? [Bool], [true, false])
        // A centre-group target differs from the centre role on other layouts, so it keeps its own key.
        o = try object(centreGroup)
        XCTAssertNotNil(o["select"]); XCTAssertEqual(o["center"] as? Bool, true)
        // Targets the classic keys express fully write no new key.
        XCTAssertNil(try object(.centerOnly)["select"]); XCTAssertNil(try object(TrackTarget(selection: .half(.right)))["select"])

        // What an older version decodes from a new file: the classic keys only.
        struct OldTarget: Decodable, Equatable {
            var left, center, right, color, warm: Bool
            var segments, cobs: [Bool]
        }
        let old = try JSONDecoder().decode(OldTarget.self, from: JSONEncoder().encode(picked))
        let expected = OldTarget(
            left: false, center: true, right: false, color: true, warm: false, segments: Array(repeating: true, count: 6),
            cobs: Array(repeating: true, count: 3))
        XCTAssertEqual(old, expected)
    }

    func testUnknownOrBrokenNewKeysFallBackToTheClassicKeys() throws {
        XCTAssertEqual(try json(#"{"left":true,"center":false,"right":false,"select":{"kind":"spiral"}}"#).selection, .half(.left))
        XCTAssertEqual(try json(#"{"left":true,"center":false,"right":true,"select":{"kind":"role"}}"#).selection, .role("side"))
        XCTAssertEqual(try json(#"{"select":"left"}"#).selection, .all)
        XCTAssertEqual(try json(#"{"masks":[1,2]}"#).masks, [:])
        let deduped = try json(#"{"select":{"kind":"groups","groups":["a","a","b"]}}"#)
        XCTAssertEqual(deduped.selection, .groups([RigGroupID("a"), RigGroupID("b")]))
        XCTAssertEqual(try json(#"{"select":{"kind":"role","role":"all"}}"#).selection, .all)
        // A mask for the centre group lands in the classic centre mask.
        let t = try json(#"{"select":{"kind":"groups","groups":["center"]},"masks":{"center":{"segments":[false]}}}"#)
        XCTAssertEqual(t.segments, [false, true, true, true, true, true]); XCTAssertEqual(t.masks, [:])
    }

    func testOldScenesFileDecodesToIdenticalScenesAndRendersTheSame() throws {
        // A scenes file as the current release writes it (target keys only in the classic form).
        func track(_ id: Int, _ target: String, motion: String, direction: String) -> String {
            """
            {"id":"601DE000-0000-4000-8000-00000000010\(id)","name":"T\(id)","sound":"free","enabled":true,"stepsPerBeat":2,\
            "lengthBeats":4,"steps":[1,0,0.5,0,1,0,0,1],"offset":0,"target":\(target),"motion":"\(motion)",\
            "direction":"\(direction)","spread":0.25,"attack":0.05,"hold":0.05,"release":0.45,"floor":0,"peak":1,\
            "color":"cycle","blend":"max","softFollowsEnergy":true,"riseBeats":0}
            """
        }
        let whole = #""segments":[true,true,true,true,true,true],"cobs":[true,true,true]"#
        let all = #"{"left":true,"center":true,"right":true,"color":true,"warm":false,"# + whole + "}"
        let centre =
            #"{"left":false,"center":true,"right":false,"color":true,"warm":true,"#
            + #""segments":[false,true,true,false,true,true],"cobs":[true,false,true]}"#
        let mix = #"{"left":true,"center":true,"right":false,"color":false,"warm":true,"# + whole + "}"
        let file = """
            {"version":1,"scenes":[{"id":"601DE000-0000-4000-8000-000000000100","name":"Old","base":"pulse",\
            "program":{"version":1,"baseLevel":0.3,"tracks":[\(track(1, all, motion: "chase", direction: "bounce")),\
            \(track(2, centre, motion: "alternate", direction: "center")),\(track(3, mix, motion: "chase", direction: "backward"))]}}]}
            """
        let scenes = try CustomSceneDocument.decode(Data(file.utf8))
        let s = try XCTUnwrap(scenes.first)
        let targets = try XCTUnwrap(s.program?.tracks.map(\.target))
        XCTAssertEqual(
            targets,
            [
                .all,
                TrackTarget(
                    left: false, right: false, warm: true, segments: [false, true, true, false, true, true], cobs: [true, false, true]),
                TrackTarget(right: false, color: false, warm: true),
            ])
        // Saving and loading again changes nothing, and no new key appears in the file.
        let saved = try CustomSceneDocument.encode(scenes)
        XCTAssertEqual(try CustomSceneDocument.decode(saved), scenes)
        let text = String(decoding: saved, as: UTF8.self)
        XCTAssertFalse(text.contains("\"select\"")); XCTAssertFalse(text.contains("\"masks\""))
        // The classic render matches the program rebuilt from values.
        var rebuilt = s
        rebuilt.program?.tracks = zip(s.program?.tracks ?? [], targets).map { track, target in
            var t = track
            t.target = TrackTarget(
                left: target.left, center: target.center, right: target.right, color: target.color, warm: target.warm,
                segments: target.segments, cobs: target.cobs)
            return t
        }
        for beat in stride(from: 0.0, through: 8, by: 0.125) {
            let ctx = SceneContext(beat: beat, phrase: beat, energy: 0.6)
            XCTAssertEqual(SceneLook(s).render(.pulse, ctx), SceneLook(rebuilt).render(.pulse, ctx))
        }
    }

    // MARK: 30 Hz path

    /// Positions are resolved when the look is built; rendering writes into the frame's existing buffers.
    func testRenderingOnAnotherLayoutWritesInPlace() throws {
        let r = rig([0.8, 0.1, 0.5])
        let look = SceneLook(scene([chase(), steady(TrackTarget(selection: .half(.left), warm: true))]), rig: r)
        let program = try XCTUnwrap(look.program)
        XCTAssertEqual(program.tracks.map { $0.units.map(\.id.rawValue) }, [["g1", "g2", "g0"], ["g1", "g1"]])
        var f = r.black
        for i in f.groups.indices {
            f.groups[i].light.rgb[0] = .black
            f.groups[i].light.cob[0] = 0
        }
        func base<T>(_ a: [T]) -> UnsafeRawPointer? { a.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
        let groups = base(f.groups), rgb = f.groups.map { base($0.light.rgb) }, cob = f.groups.map { base($0.light.cob) }
        program.render(into: &f, scene: .ambra, SceneContext(beat: 1, phrase: 1, energy: 1))
        XCTAssertEqual(base(f.groups), groups)
        XCTAssertEqual(f.groups.map { base($0.light.rgb) }, rgb)
        XCTAssertEqual(f.groups.map { base($0.light.cob) }, cob)
        XCTAssertEqual(lit(f), ["g1", "g2"], "hit 2 on g2, and the steady left half on g1")
    }

    func testTheBaseChoreographyIsFittedToAnotherRig() {
        let groups = [RigGroup(id: .right, name: "R", position: StagePoint(x: 0.1, y: 0)), RigGroup(id: RigGroupID("new"), name: "N")]
        let sizes = RigFrame(groups: groups.map { GroupFrame(id: $0.id, light: .black(rgb: 1, cob: 1)) })
        let r = SpatialRig(layout: RigLayout(groups: groups), sizes: sizes)
        var s = scene([steady(.all)])
        s.program?.baseLevel = 1
        let f = SceneLook(s, rig: r).render(.ambra, SceneContext(beat: 0, energy: 1))
        XCTAssertEqual(f.groups.map(\.id), [.right, RigGroupID("new")], "the base choreography follows the rig (ADR 0005 step 6)")
        XCTAssertEqual(f.right.rgb.map(\.peak), [1])
        XCTAssertEqual(f[group: RigGroupID("new")]?.rgb.map(\.peak), [1])
        XCTAssertTrue(f.isFinite)
    }
}
