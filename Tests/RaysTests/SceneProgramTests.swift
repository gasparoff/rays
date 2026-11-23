import XCTest
@testable import RaysCore

/// Structure on the beat: model, sanitising, persistence and the deterministic renderer.
final class SceneProgramTests: XCTestCase {
    let red = SceneRGB(r: 1, g: 0, b: 0), green = SceneRGB(r: 0, g: 1, b: 0), blue = SceneRGB(r: 0, g: 0, b: 1)

    func scene(_ tracks: [ProgramTrack], base: SceneID = .ambra, baseLevel: Double = 0, slot: SceneID? = nil) -> CustomScene {
        CustomScene(name: "Test", presetSlot: slot, base: base, colors: [red, green, blue],
                    program: SceneProgram(baseLevel: baseLevel, tracks: tracks))
    }

    func render(_ s: CustomScene, beat: Double, phrase: Double? = nil, energy: Double = 1, scene: SceneID? = nil) -> RigFrame {
        SceneLook(s).render(scene ?? s.base, SceneContext(beat: beat, phrase: phrase ?? beat, energy: energy))
    }

    /// Quarter-note kick: steps on every beat, short envelope.
    func kick(_ target: TrackTarget = .all, motion: TrackMotion = .together, direction: TrackDirection = .forward,
              steps: [Double] = [1, 1, 1, 1], attack: Double = 0, hold: Double = 0, release: Double = 0.25,
              spread: Double = 0, offset: Double = 0, color: TrackColor = .first) -> ProgramTrack {
        ProgramTrack(sound: .kick, stepsPerBeat: 1, lengthBeats: steps.count, steps: steps, offset: offset, target: target,
                     motion: motion, direction: direction, spread: spread, attack: attack, hold: hold, release: release,
                     color: color)
    }

    func peak(_ f: RoleFrame) -> Double { f.rgb.map(\.peak).max() ?? 0 }

    // MARK: Persistence

    func testOldScenesWithoutProgramDecodeAndRenderExactlyAsBefore() throws {
        let old = Data("""
        {"version":1,"scenes":[{"id":"6F1C2C0E-4C55-4E4B-9E43-2B7C1B8E2A11","name":"Green","base":"pulse",
          "colors":[{"r":0,"g":1,"b":0},{"r":0,"g":1,"b":0},{"r":0,"g":1,"b":0}],"energy":0.4,"subdivision":2,
          "warmth":0.6,"leftLevel":1,"centerLevel":0.8,"rightLevel":1},
          {"id":"0B4AF1E8-55B5-4C59-9A0B-7E0E0C2F7B10","name":"Ambra mia","presetSlot":"ambra","base":"ambra"}]}
        """.utf8)
        let scenes = try CustomSceneDocument.decode(old)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertTrue(scenes.allSatisfy { $0.program == nil })
        XCTAssertEqual(scenes[1].presetSlot, .ambra)
        XCTAssertEqual(scenes[0].id.uuidString, "6F1C2C0E-4C55-4E4B-9E43-2B7C1B8E2A11")
        for s in scenes {
            for beat in stride(from: -3.0, to: 20, by: 0.37) {
                let ctx = SceneContext(beat: beat, phrase: beat - 1, energy: 0.4)
                XCTAssertEqual(SceneLook(s).render(s.base, ctx), s.applyingLook(to: Choreography.render(s.base, ctx)))
            }
        }
        // Re-saving an old scene does not invent a program key.
        let encoded = String(decoding: try CustomSceneDocument.encode(scenes), as: UTF8.self)
        XCTAssertFalse(encoded.contains("program"))
        XCTAssertTrue(encoded.contains("\"version\" : 1"))
    }

    func testProgramRoundTripsForPresetSlotsAndPersonalScenesKeepingIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = CustomSceneFile(directory: dir)
        var list: [CustomScene] = []
        for slot in SceneID.allCases {
            var s = CustomScene(name: "\(slot.title) mio", presetSlot: slot, base: slot, program: .starter(for: slot))
            s.program?.tracks[0].steps[0] = 0.5
            list.append(s)
        }
        var personal = scene([.template(.hat), .template(.bass)], base: .chase, baseLevel: 0.3)
        personal.program?.tracks[1].target.segments = [true, false, true, false, true, false]
        list.append(personal)
        try file.save(list)
        let loaded = try file.load()
        XCTAssertEqual(loaded, list.map(\.sanitized))
        XCTAssertEqual(loaded.map(\.id), list.map(\.id))
        XCTAssertEqual(loaded.map(\.presetSlot), list.map(\.presetSlot))
        XCTAssertEqual(loaded.last?.program?.tracks[1].target.segments, [true, false, true, false, true, false])
        XCTAssertEqual(loaded.last?.program?.baseLevel, 0.3)
        XCTAssertEqual(loaded.first(where: { $0.presetSlot == .aurora })?.base, .aurora, "a preset keeps its musical identity")
    }

    func testInvalidValuesAreBoundedAndBrokenTracksDoNotDropTheScene() throws {
        let json = Data("""
        [{"name":"Rotta","base":"chase","program":{"version":7,"baseLevel":"x","tracks":[
          {"name":"\\u0007Cassa lunghissima con un nome che non finisce mai","sound":"kick","stepsPerBeat":3,"lengthBeats":64,
           "steps":[1,2,-1,0.5],"offset":9,"attack":-1,"hold":1e9,"release":99,"floor":0.9,"peak":0.4,
           "motion":"spin","direction":"up","color":"neon","blend":"xor","spread":5,"riseBeats":7,
           "target":{"left":false,"segments":[false],"cobs":[true,true,true,true,true]}},
          {"sound":"hat","stepsPerBeat":4,"lengthBeats":16},
          "not a track",
          {"sound":"bass"},{"sound":"bass"},{"sound":"bass"},{"sound":"bass"},{"sound":"bass"},{"sound":"bass"},{"sound":"bass"}
        ]}}]
        """.utf8)
        let s = try XCTUnwrap(CustomSceneDocument.decode(json).first)
        let p = try XCTUnwrap(s.program)
        XCTAssertEqual(p.version, SceneProgram.currentVersion)
        XCTAssertEqual(p.baseLevel, 0)
        XCTAssertEqual(p.tracks.count, SceneProgram.maxTracks, "at most 8 tracks; the broken entry is skipped")
        let t = p.tracks[0]
        XCTAssertLessThanOrEqual(t.name.count, ProgramTrack.maxNameLength)
        XCTAssertFalse(t.name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertEqual(t.stepsPerBeat, 4)
        XCTAssertEqual(t.steps.count, t.stepsPerBeat * t.lengthBeats)
        XCTAssertLessThanOrEqual(t.steps.count, ProgramTrack.maxSteps)
        XCTAssertEqual(Array(t.steps.prefix(4)), [1, 1, 0, 0.5])
        XCTAssertEqual(t.offset, ProgramTrack.maxOffset)
        XCTAssertEqual(t.attack, 0)
        XCTAssertEqual(t.hold, ProgramTrack.maxHold)
        XCTAssertEqual(t.release, ProgramTrack.maxRelease)
        XCTAssertEqual(t.peak, 0.4); XCTAssertEqual(t.floor, 0.4, "floor never above peak")
        XCTAssertEqual(t.motion, .together); XCTAssertEqual(t.direction, .forward)
        XCTAssertEqual(t.color, .first); XCTAssertEqual(t.blend, .max)
        XCTAssertEqual(t.spread, ProgramTrack.maxSpread)
        XCTAssertEqual(t.riseBeats, 4)
        XCTAssertEqual(t.target.segments.count, 6); XCTAssertEqual(t.target.cobs.count, 3)
        XCTAssertEqual(p.tracks[1].lengthBeats, 8, "16 beats of sixteenths exceeds 32 steps")

        var nan = scene([kick()])
        nan.program?.baseLevel = .nan
        nan.program?.tracks[0].attack = .infinity
        nan.program?.tracks[0].steps = [.nan, 1, .infinity, -0.0]
        nan.program?.tracks[0].floor = .nan
        let clean = nan.sanitized.program!
        XCTAssertEqual(clean.baseLevel, 0)
        XCTAssertTrue(clean.tracks[0].attack.isFinite)
        XCTAssertEqual(clean.tracks[0].steps, [0, 1, 0, 0])

        // A program that is not even an object keeps the scene and its historical behaviour.
        let bad = try XCTUnwrap(CustomSceneDocument.decode(Data("[{\"name\":\"X\",\"base\":\"pulse\",\"program\":42}]".utf8)).first)
        XCTAssertNil(bad.program)
        XCTAssertEqual(bad.base, .pulse)
    }

    func testRendererStaysFiniteAndBoundedForHostileContexts() {
        var tracks = SceneID.allCases.flatMap { SceneProgram.starter(for: $0).tracks }.prefix(8).map { $0 }
        tracks[0].blend = .add; tracks[1].blend = .add
        let s = scene(tracks, baseLevel: 0.7)
        for base in SceneID.allCases {
            for t in [-1e12, -7.3, -0.01, 0, 0.5, 3.99, 1e9, .nan, .infinity, -.infinity] {
                for e in [0, 0.5, 1, .nan] {
                    let f = SceneLook(s).render(base, SceneContext(beat: t, phrase: t - 2, energy: e, minAttack: .nan))
                    XCTAssertTrue(f.isFinite)
                    for c in f.left.rgb + f.center.rgb + f.right.rgb {
                        XCTAssertTrue((0...1).contains(c.r) && (0...1).contains(c.g) && (0...1).contains(c.b))
                        XCTAssertEqual(c.w, 0, "no white channel from RGB tracks")
                    }
                    XCTAssertTrue((f.left.cob + f.center.cob + f.right.cob).allSatisfy { (0...1).contains($0) })
                }
            }
        }
    }

    // MARK: Rhythm and envelope

    func testStepsTurnLightsOnAndOffOnTheBeat() {
        let s = scene([kick(steps: [1, 0, 1, 0], release: 0.25)])
        XCTAssertEqual(peak(render(s, beat: 0).center), 1, accuracy: 1e-9, "full peak on a strong step")
        XCTAssertEqual(peak(render(s, beat: 8).left), 1, accuracy: 1e-9)
        XCTAssertEqual(peak(render(s, beat: 0.5).center), 0, "dark between hits")
        XCTAssertEqual(peak(render(s, beat: 1).center), 0, "step 2 is off")
        XCTAssertEqual(peak(render(s, beat: 2).center), 1, accuracy: 1e-9)
        XCTAssertEqual(peak(render(s, beat: 3).center), 0)
        XCTAssertEqual(render(s, beat: 4), render(s, beat: 0), "the cycle repeats")
        XCTAssertEqual(render(s, beat: 1234.5), render(s, beat: 1234.5), "deterministic")
        // Colour 1 of the scene (red), RGB only.
        let c = render(s, beat: 0).center.rgb[0]
        XCTAssertEqual(c.r, 1); XCTAssertEqual(c.g, 0); XCTAssertEqual(c.b, 0)
        XCTAssertEqual(render(s, beat: 0).center.cob, [0, 0, 0], "colour tracks never light the COBs")
    }

    func testOffsetAttackHoldAndReleaseShapeEachHit() {
        let s = scene([kick(steps: [1, 0, 0, 0], attack: 0.5, hold: 0.25, release: 1)])
        let level = { (b: Double) in self.peak(self.render(s, beat: b).center) }
        XCTAssertEqual(level(-0.6), 0)
        XCTAssertGreaterThan(level(-0.25), 0.2); XCTAssertLessThan(level(-0.25), 0.8)
        XCTAssertEqual(level(0), 1, accuracy: 1e-9, "the attack ends exactly on the step")
        XCTAssertEqual(level(0.2), 1, accuracy: 1e-9, "hold")
        XCTAssertGreaterThan(level(0.5), level(0.9))
        XCTAssertEqual(level(1.25), 0, accuracy: 1e-9, "release ends after hold + release")
        let late = scene([kick(steps: [1, 0, 0, 0], release: 0.2, offset: 0.25)])
        XCTAssertEqual(peak(render(late, beat: 0).center), 0, "offset delays the hit")
        XCTAssertEqual(peak(render(late, beat: 0.25).center), 1, accuracy: 1e-9)
        var floorPeak = kick(steps: [1, 0, 0, 0])
        floorPeak.floor = 0.2; floorPeak.peak = 0.7
        let fp = scene([floorPeak])
        XCTAssertEqual(peak(render(fp, beat: 2).center), 0.2, accuracy: 1e-9)
        XCTAssertEqual(peak(render(fp, beat: 0).center), 0.7, accuracy: 1e-9)
    }

    func testSoftStepsFollowEnergyWhileStrongStepsKeepTheFullPeak() {
        let s = scene([kick(steps: [1, 0.5, 0, 0])])
        for energy in [0.0, 0.5, 1.0] {
            XCTAssertEqual(peak(render(s, beat: 0, energy: energy).center), 1, accuracy: 1e-9, "strong step = 255 at any energy")
        }
        XCTAssertEqual(peak(render(s, beat: 1, energy: 0).center), 0)
        XCTAssertEqual(peak(render(s, beat: 1, energy: 1).center), 0.5, accuracy: 1e-9)
        var fixed = s
        fixed.program?.tracks[0].softFollowsEnergy = false
        XCTAssertEqual(peak(render(fixed, beat: 1, energy: 0).center), 0.5, accuracy: 1e-9)
    }

    // MARK: Targets

    func testTargetsSelectRolesSegmentsAndCOBsIndependently() {
        let center = scene([kick(.centerOnly)])
        var f = render(center, beat: 0)
        XCTAssertEqual(peak(f.left), 0); XCTAssertEqual(peak(f.right), 0)
        XCTAssertTrue(f.center.rgb.allSatisfy { $0.peak == 1 })

        var detail = TrackTarget.centerOnly
        detail.segments = [true, false, false, true, false, false]
        f = render(scene([kick(detail)]), beat: 0)
        XCTAssertEqual(f.center.rgb.map(\.peak), [1, 0, 0, 1, 0, 0])

        var warm = TrackTarget(color: false, warm: true)
        warm.cobs = [false, true, false]
        f = render(scene([kick(warm)]), beat: 0)
        XCTAssertEqual(f.center.cob, [0, 1, 0])
        XCTAssertEqual(f.left.cob, [1]); XCTAssertEqual(f.right.cob, [1])
        XCTAssertEqual(peak(f.center) + peak(f.left) + peak(f.right), 0, "warm tracks never light RGB")

        f = render(scene([kick(.sides)]), beat: 0)
        XCTAssertEqual(peak(f.center), 0); XCTAssertEqual(peak(f.left), 1); XCTAssertEqual(peak(f.right), 1)
        // Empty target: silent, not a crash.
        f = render(scene([kick(TrackTarget(left: false, center: false, right: false))]), beat: 0)
        XCTAssertEqual(f, .black)
    }

    // MARK: Motion

    func testChaseRunsAcrossTheStageInTheChosenDirection() {
        // 8 RGB positions: L, centre 5,4,3,2,1,0, R.
        let forward = scene([kick(motion: .chase, steps: Array(repeating: 1, count: 8), release: 0.2)])
        func lit(_ f: RigFrame) -> [Int] {
            let all = f.left.rgb + f.center.rgb + f.right.rgb   // L, c0…c5, R
            return all.indices.filter { all[$0].peak > 0.5 }
        }
        XCTAssertEqual(lit(render(forward, beat: 0)), [0], "hit 1: left")
        XCTAssertEqual(lit(render(forward, beat: 1)), [6], "hit 2: centre segment 5 (left edge, top)")
        XCTAssertEqual(lit(render(forward, beat: 6)), [1], "hit 7: centre segment 0 (right edge, top)")
        XCTAssertEqual(lit(render(forward, beat: 7)), [7], "hit 8: right")
        let backward = scene([kick(motion: .chase, direction: .backward, steps: Array(repeating: 1, count: 8), release: 0.2)])
        XCTAssertEqual(lit(render(backward, beat: 0)), [7])
        XCTAssertEqual(lit(render(backward, beat: 7)), [0])
        let bounce = scene([ProgramTrack(stepsPerBeat: 1, lengthBeats: 16, steps: Array(repeating: 1, count: 16), target: .sides,
                                         motion: .chase, direction: .bounce, attack: 0, hold: 0, release: 0.2)])
        XCTAssertEqual(lit(render(bounce, beat: 0)), [0]); XCTAssertEqual(lit(render(bounce, beat: 1)), [7])
        XCTAssertEqual(lit(render(bounce, beat: 2)), [0])
        let fromCenter = scene([kick(motion: .chase, direction: .center, steps: Array(repeating: 1, count: 4), release: 0.2)])
        XCTAssertEqual(lit(render(fromCenter, beat: 0)), [3, 4], "innermost segments 3 and 2 together")
        XCTAssertEqual(lit(render(fromCenter, beat: 3)), [0, 7], "then out to both sides together")
    }

    func testAlternateAndSpreadReallyMoveBetweenPositions() {
        let alt = scene([kick(.sides, motion: .alternate, release: 0.2)])
        XCTAssertEqual(peak(render(alt, beat: 0).left), 1); XCTAssertEqual(peak(render(alt, beat: 0).right), 0)
        XCTAssertEqual(peak(render(alt, beat: 1).left), 0); XCTAssertEqual(peak(render(alt, beat: 1).right), 1)
        // Centre only: left half of the triangle (segments 5,4,3) then the right half (2,1,0).
        let centerAlt = render(scene([kick(.centerOnly, motion: .alternate, release: 0.2)]), beat: 0).center.rgb.map(\.peak)
        XCTAssertEqual(centerAlt, [0, 0, 0, 1, 1, 1])
        // Spread: each position a quarter beat later, left first.
        let wave = scene([kick(steps: [1, 0, 0, 0], release: 0.1, spread: 0.25)])
        let f = render(wave, beat: 0.25)
        XCTAssertEqual(peak(f.left), 0, "left already released")
        XCTAssertEqual(f.center.rgb[5].peak, 1, accuracy: 1e-9, "first centre position peaks one spread later")
        XCTAssertEqual(f.center.rgb[0].peak, 0, "right edge still waiting")
        XCTAssertEqual(peak(render(wave, beat: 1.75).right), 1, accuracy: 1e-9, "right side after 7 spreads")
    }

    func testColourCycleAndBlendModesKeepRGBAndCOBSeparate() {
        let cycle = scene([kick(color: .cycle)])
        XCTAssertEqual(render(cycle, beat: 0).left.rgb[0], LightColor(1, 0, 0))
        XCTAssertEqual(render(cycle, beat: 1).left.rgb[0], LightColor(0, 1, 0))
        XCTAssertEqual(render(cycle, beat: 2).left.rgb[0], LightColor(0, 0, 1))
        var a = kick(.centerOnly); a.peak = 0.5
        var b = kick(.centerOnly, color: .first); b.peak = 0.4
        XCTAssertEqual(peak(render(scene([a, b]), beat: 0).center), 0.5, accuracy: 1e-9, "max: strongest wins")
        b.blend = .add
        XCTAssertEqual(peak(render(scene([a, b]), beat: 0).center), 0.9, accuracy: 1e-9, "add: sums")
        a.peak = 1
        XCTAssertEqual(peak(render(scene([a, b]), beat: 0).center), 1, "add is limited to full scale")
        // Base choreography under the tracks, recoloured, at the chosen share.
        let original = CustomScene(base: .pulse, colors: [red, green, blue])
        let ctx = SceneContext(beat: 5.3, phrase: 5.3, energy: 0.5)
        var over = original; over.program = SceneProgram(baseLevel: 1, tracks: [])
        XCTAssertEqual(SceneLook(over).render(.pulse, ctx), original.applyingLook(to: Choreography.render(.pulse, ctx)))
        over.program?.baseLevel = 0
        XCTAssertEqual(SceneLook(over).render(.pulse, ctx), .black, "0% = only the tracks")
    }

    func testSceneWhiteScalesWarmTracksAndRiseRampsFromTheSceneStart() {
        var s = scene([kick(TrackTarget(color: false, warm: true))])
        XCTAssertEqual(render(s, beat: 0).center.cob, [1, 1, 1])
        s.warmth = 0.5
        XCTAssertEqual(render(s, beat: 0).center.cob, [0.5, 0.5, 0.5])
        s.warmth = 0
        XCTAssertEqual(render(s, beat: 0).center.cob, [0, 0, 0])
        var rise = kick(); rise.riseBeats = 16
        let r = scene([rise])
        XCTAssertEqual(peak(render(r, beat: 0, phrase: 0).center), 0.25, accuracy: 1e-9)
        XCTAssertEqual(peak(render(r, beat: 16, phrase: 16).center), 1, accuracy: 1e-9)
        XCTAssertEqual(peak(render(r, beat: 64, phrase: 64).center), 1, accuracy: 1e-9)
    }

    func testDropKeepsItsDarkDipAndTracksCountFromTheAnchoredDownbeat() {
        let d = scene([ProgramTrack(stepsPerBeat: 1, lengthBeats: 8, steps: [1, 0, 0, 0, 0, 0, 0, 0], target: .all,
                                    attack: 0, hold: 0, release: 0.5)], base: .respiro, slot: .respiro)
        // Beat 103 is not a multiple of 8: the hit follows the drop (phrase), not the global grid.
        XCTAssertEqual(peak(render(d, beat: 102.8, phrase: -0.2).center), 0, "dip before the drop")
        XCTAssertEqual(peak(render(d, beat: 103, phrase: 0).center), 1, accuracy: 1e-9, "impact on the drop")
        XCTAssertEqual(peak(render(d, beat: 111, phrase: 8).center), 1, accuracy: 1e-9)
        XCTAssertEqual(SceneLook.patternTime(.respiro, SceneContext(beat: 103, phrase: 0, energy: 0)), 0)
        XCTAssertEqual(SceneLook.patternTime(.pulse, SceneContext(beat: 103, phrase: 0, energy: 0)), 103)
    }

    // MARK: Editing helpers and starters

    func testResizeRotateAndQuickFillsKeepMusicalTimes() {
        var t = ProgramTrack(stepsPerBeat: 1, lengthBeats: 4, steps: [1, 0, 0.5, 0])
        let eighths = t.resized(stepsPerBeat: 2, lengthBeats: 4)
        XCTAssertEqual(eighths.steps, [1, 0, 0, 0, 0.5, 0, 0, 0])
        XCTAssertEqual(eighths.resized(stepsPerBeat: 1, lengthBeats: 4).steps, [1, 0, 0.5, 0])
        XCTAssertEqual(t.resized(stepsPerBeat: 1, lengthBeats: 8).steps, [1, 0, 0.5, 0, 1, 0, 0.5, 0], "longer cycle repeats")
        XCTAssertEqual(t.resized(stepsPerBeat: 4, lengthBeats: 16).lengthBeats, 8, "never above 32 steps")
        XCTAssertEqual(t.rotated(by: 1).steps, [0, 1, 0, 0.5])
        XCTAssertEqual(t.rotated(by: -1).steps, [0, 0.5, 0, 1])
        t = PatternFill.kick.apply(to: ProgramTrack(stepsPerBeat: 4, lengthBeats: 2))
        XCTAssertEqual(t.steps, [1, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(PatternFill.clap.apply(to: ProgramTrack(stepsPerBeat: 1, lengthBeats: 4)).steps, [0, 1, 0, 1])
        let hat = PatternFill.hat.apply(to: ProgramTrack(stepsPerBeat: 1, lengthBeats: 2))
        XCTAssertEqual(hat.stepsPerBeat, 2); XCTAssertEqual(hat.steps, [0, 1, 0, 1])
        XCTAssertEqual(PatternFill.bass.apply(to: ProgramTrack(stepsPerBeat: 2, lengthBeats: 4)).steps, [1, 0, 0, 1, 0, 0, 1, 0])
        XCTAssertEqual(PatternFill.clear.apply(to: hat).activeStepCount, 0)
        for sound in TrackSound.allCases {
            let tpl = ProgramTrack.template(sound)
            XCTAssertEqual(tpl, tpl.sanitized, "\(sound) template is already valid")
        }
        XCTAssertEqual(ProgramTrack.template(.kick).steps, [1, 1, 1, 1])
        XCTAssertEqual(ProgramTrack.template(.clap).steps, [0, 1, 0, 1])
    }

    func testEveryPresetStarterIsAliveAndReachesFullRGBAndWarmPeaks() {
        for base in SceneID.allCases {
            let p = SceneProgram.starter(for: base)
            XCTAssertEqual(p, p.sanitized)
            XCTAssertLessThanOrEqual(p.tracks.count, SceneProgram.maxTracks)
            let s = CustomScene(presetSlot: base, base: base, program: p)
            var rgb = 0.0, cob = 0.0, changes = 0
            var last: RigFrame?
            for step in 0..<(64 * 8) {
                let b = Double(step) / 8
                let f = SceneLook(s).render(base, SceneContext(beat: b, phrase: b, energy: 0.5))
                rgb = max(rgb, peak(f.center), peak(f.left), peak(f.right))
                cob = max(cob, (f.center.cob + f.left.cob + f.right.cob).max() ?? 0)
                if let last, last != f { changes += 1 }
                last = f
            }
            XCTAssertGreaterThanOrEqual(rgb, 0.999, "\(base) RGB peak")
            XCTAssertGreaterThanOrEqual(cob, 0.999, "\(base) warm peak")
            XCTAssertGreaterThan(changes, 100, "\(base) moves")
        }
    }

    func testEightFullTracksRenderWellWithinTheFrameBudget() {
        let heavy = (0..<SceneProgram.maxTracks).map { i in
            ProgramTrack(stepsPerBeat: 4, lengthBeats: 8, steps: Array(repeating: i % 2 == 0 ? 1 : 0.5, count: 32),
                         target: TrackTarget(color: true, warm: true), motion: TrackMotion.allCases[i % 3],
                         direction: TrackDirection.allCases[i % 4], spread: 0.3, attack: 4, hold: 4, release: 8,
                         color: .cycle, blend: i % 2 == 0 ? .max : .add)
        }
        let look = SceneLook(scene(heavy, baseLevel: 1))
        var sink = 0.0
        // Best of three timed runs of the same 300 frames: a shared CI runner (parallel tests,
        // coverage instrumentation) can preempt one run, but not make the code itself slower.
        var perFrame = Double.infinity
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            for frame in 0..<300 {
                let b = 1000 + Double(frame) / 15
                sink += look.render(.chase, SceneContext(beat: b, phrase: b, energy: 0.5)).center.rgb[0].r
            }
            perFrame = min(perFrame, (ProcessInfo.processInfo.systemUptime - start) / 300)
        }
        XCTAssertTrue(sink.isFinite)
        XCTAssertLessThan(perFrame, 0.005, "worst-case program must stay far below the 33 ms frame (debug build)")
    }
}
