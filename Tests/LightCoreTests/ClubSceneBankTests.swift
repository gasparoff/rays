import XCTest
@testable import RaysTempo
@testable import RaysCore
@testable import RaysEngine

/// Club bank (130–138 BPM): identity of the factory scenes and their real rendering
/// (SceneLook, sequencer gesture, 30 Hz engine). No UI, no hardware.
final class ClubSceneBankTests: XCTestCase {
    let bpms = [130.0, 134.0, 138.0]
    let looks = Dictionary(uniqueKeysWithValues: SceneID.allCases.map { ($0, SceneLook(ClubSceneBank.scene(for: $0))) })

    /// Pattern and phrase both from `beat` unless given (anchor at 0), Energia as the factory default.
    func frame(_ slot: SceneID, _ beat: Double, phrase: Double? = nil, energy: Double = 0.7) -> RigFrame {
        looks[slot]!.render(slot, SceneContext(beat: beat, phrase: phrase ?? beat, energy: energy, minAttack: 0.06))
    }

    func seg(_ f: RigFrame, _ i: Int) -> Double { f.center.rgb[i].peak }
    func rgbPeaks(_ f: RigFrame) -> [Double] { ([f.left.rgb[0]] + f.center.rgb + [f.right.rgb[0]]).map(\.peak) }
    func cobs(_ f: RigFrame) -> [Double] { f.left.cob + f.center.cob + f.right.cob }
    func full(_ x: Double, _ msg: String = "", line: UInt = #line) { XCTAssertEqual(x, 1, accuracy: 1e-6, msg, line: line) }
    func bounded(_ f: RigFrame) -> Bool {
        let rgb = [f.left, f.center, f.right].flatMap(\.rgb)
        return rgb.allSatisfy { $0.isFinite && [$0.r, $0.g, $0.b, $0.w].allSatisfy { (0...1).contains($0) } }
            && cobs(f).allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    // MARK: Identity

    func testSixStableEditableFactoryScenesOnTheirSlots() throws {
        XCTAssertEqual(ClubSceneBank.scenes.count, 6)
        var trackIDs = Set<UUID>()
        for (n, slot) in SceneID.allCases.enumerated() {
            let s = ClubSceneBank.scene(for: slot)
            XCTAssertEqual(s.id, UUID(uuidString: "13013800-0000-4000-8000-00000000000\(n + 1)"))
            XCTAssertEqual(s.presetSlot, slot); XCTAssertEqual(s.base, slot); XCTAssertEqual(s.presetBank, .club)
            XCTAssertEqual(s.energy, 0.7); XCTAssertEqual(s.warmth, 1); XCTAssertEqual(s.subdivision, .one)
            XCTAssertEqual([s.leftLevel, s.centerLevel, s.rightLevel], [1, 1, 1])
            XCTAssertEqual(s, s.sanitized, "stored already clean")
            XCTAssertLessThanOrEqual(s.name.count, 12, "fits the 180 px card")
            let sub = ClubSceneBank.subtitle(for: slot)
            XCTAssertFalse(sub.isEmpty); XCTAssertLessThanOrEqual(sub.count, 26)
            XCTAssertEqual(ClubSceneBank.scene(id: s.id), s)
            XCTAssertEqual(ClubSceneBank.scene(for: slot), s, "cached: same track ids on every lookup")

            let program = try XCTUnwrap(s.program)
            XCTAssertEqual(program.baseLevel, 0, "only tracks, no hidden house choreography")
            XCTAssertLessThanOrEqual(program.tracks.count, SceneProgram.maxTracks)
            XCTAssertGreaterThanOrEqual(program.tracks.count, 5)
            for t in program.tracks {
                XCTAssertTrue(trackIDs.insert(t.id).inserted, "unique track id")
                XCTAssertLessThanOrEqual(t.stepCount, ProgramTrack.maxSteps)
                XCTAssertEqual(t.steps.count, t.stepCount)
                XCTAssertEqual(t.peak, 1, "\(s.name)/\(t.name): full-strength peak")
                XCTAssertTrue(t.steps.allSatisfy { [0, 0.5, 1].contains($0) }, "strong 1, soft 0.5")
                XCTAssertTrue(t.enabled); XCTAssertFalse(t.target.isEmpty)
                XCTAssertEqual(t.riseBeats, slot == .aurora ? 8 : 0)
            }
        }
        XCTAssertNil(ClubSceneBank.scene(id: UUID()))
        // Round trip through the user's scene file format keeps everything, ids included.
        let data = try CustomSceneDocument.encode(ClubSceneBank.scenes)
        XCTAssertEqual(try CustomSceneDocument.decode(data), ClubSceneBank.scenes)
        // A user edit is a copy; the factory stays untouched.
        var edited = ClubSceneBank.scene(for: .pulse)
        edited.program?.tracks[0].peak = 0.3
        XCTAssertEqual(ClubSceneBank.scene(for: .pulse).program?.tracks[0].peak, 1)
    }

    // MARK: Known hits (full 255 on the step)

    func testPocketKickBassOffbeatAndClapLandFullOnTheirSteps() {
        let s = SceneID.ambra
        full(seg(frame(s, 4), 2)); full(seg(frame(s, 4), 3))
        full(seg(frame(s, 4.05), 1), "kick blooms upward 0.05 beat later"); full(seg(frame(s, 4.05), 4))
        full(seg(frame(s, 0), 5), "bass 1 top-left"); full(seg(frame(s, 1.5), 0), "bass 2 top-right")
        XCTAssertLessThan(seg(frame(s, 1.5), 5), 0.2, "bass left side has decayed")
        full(frame(s, 0.55).left.rgb[0].peak, "laid-back offbeat"); full(frame(s, 0.55).right.rgb[0].peak)
        XCTAssertLessThan(frame(s, 0).left.rgb[0].peak, 0.2)
        full(frame(s, 3).center.cob[0], "clap on 4")
        XCTAssertEqual(frame(s, 1).center.cob[0], 0.35, accuracy: 1e-6, "ghost clap follows Energia")
        XCTAssertEqual(frame(s, 2).center.cob[0], 0, accuracy: 1e-6)
        full(frame(s, 16).left.cob[0], "phrase accent"); XCTAssertEqual(frame(s, 4).left.cob[0], 0)
    }

    func testShuffleClaveWalksTheCentreEdgesAndSidesAlternate() {
        let s = SceneID.sunset
        full(seg(frame(s, 1), 2)); full(seg(frame(s, 1), 3))
        // Son clave 0, 1.5, 3 | 5, 6 walks top-left → mid-left → mid-right → top-right → top-left.
        for (beat, segment) in [(0.0, 5), (1.5, 4), (3.0, 1), (5.0, 0), (6.0, 5), (8.0, 4)] {
            let f = frame(s, beat)
            full(seg(f, segment), "clave at \(beat)")
            for other in [0, 1, 4, 5] where other != segment { XCTAssertLessThan(seg(f, other), 0.6) }
        }
        full(frame(s, 0.5).left.rgb[0].peak); XCTAssertLessThan(frame(s, 0.5).right.rgb[0].peak, 0.15)
        full(frame(s, 1.5).right.rgb[0].peak); XCTAssertLessThan(frame(s, 1.5).left.rgb[0].peak, 0.15)
        let ghost = frame(s, 0.31).left.rgb[0].peak
        XCTAssertGreaterThan(ghost, 0.3); XCTAssertLessThan(ghost, 0.6, "swung ghost 16th, soft")
        full(frame(s, 1).center.cob[2]); full(frame(s, 3).center.cob[1])
        XCTAssertLessThan(frame(s, 1).center.cob[1], 0.01)
    }

    func testJackBassBouncesAndLeftAsksRightAnswers() {
        let s = SceneID.pulse
        full(seg(frame(s, 0), 2))
        full(seg(frame(s, 0), 4)); full(seg(frame(s, 1.5), 1)); full(seg(frame(s, 3), 4)); full(seg(frame(s, 4), 1))
        full(seg(frame(s, 0.5), 0), "hat top"); full(seg(frame(s, 0.5), 5))
        full(frame(s, 0.5).left.rgb[0].peak); XCTAssertLessThan(frame(s, 0.5).right.rgb[0].peak, 0.15)
        full(frame(s, 2.5).right.rgb[0].peak); XCTAssertLessThan(frame(s, 2.5).left.rgb[0].peak, 0.15)
        full(frame(s, 1).center.cob[0]); full(frame(s, 3).center.cob[0])
        XCTAssertLessThan(frame(s, 2).center.cob[0], 0.01)
    }

    func testDriveRunsAcrossTheStageAndBackWithAnOverlappingTail() {
        let s = SceneID.chase
        let order = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5].map { frame(s, $0) }
        full(order[0].left.rgb[0].peak); XCTAssertLessThan(order[0].right.rgb[0].peak, 0.3)
        for (k, segment) in [5, 4, 3, 2, 1, 0].enumerated() { full(seg(order[k + 1], segment), "head on segment \(segment)") }
        full(order[7].right.rgb[0].peak)
        let tail = seg(order[7], 0)
        XCTAssertGreaterThan(tail, 0.4); XCTAssertLessThan(tail, 0.8, "previous position still glowing")
        full(frame(s, 4).right.rgb[0].peak, "bar 2 comes back"); full(seg(frame(s, 4.5), 0)); full(frame(s, 7.5).left.rgb[0].peak)
        for beat in [0.0, 1, 2, 3] { full(seg(frame(s, beat), 2), "quarter punch") }
        XCTAssertLessThan(frame(s, 0.75).center.rgb[2].g, 0.5)
        XCTAssertTrue(cobs(frame(s, 0)).allSatisfy { abs($0 - 1) < 1e-6 }, "white only on the phrase")
        XCTAssertEqual(frame(s, 1).center.cob[0], 0.35, accuracy: 1e-6, "soft clap grows with Energia")
        XCTAssertEqual(frame(s, 1, energy: 1).center.cob[0], 0.5, accuracy: 1e-6)
    }

    // MARK: Build + / Drop +

    func testBuildRisesOverEightBeatsWithAClimbingWaveAndRotatingCOBs() {
        let press = 100.37, anchor = press + 0.5   // sequencer anchor: press + Build fade
        func build(_ beat: Double) -> RigFrame { frame(.aurora, beat, phrase: beat - anchor) }
        func total(_ f: RigFrame) -> Double { rgbPeaks(f).reduce(0, +) + cobs(f).reduce(0, +) }
        func mean(_ from: Double) -> Double {
            let xs = stride(from: from, to: from + 1, by: 1 / 48).map { total(build($0)) }
            return xs.reduce(0, +) / Double(xs.count)
        }
        XCTAssertGreaterThan(mean(anchor + 9), mean(anchor) * 2.5)
        XCTAssertEqual(seg(build(101), 2), 0.25, accuracy: 0.01, "starts at 25 %")
        XCTAssertGreaterThan(seg(build(105), 2), seg(build(103), 2) + 0.2, "keeps climbing")
        full(seg(build(110), 2), "full after 8 beats")
        XCTAssertLessThan(seg(build(110), 0), 0.2)
        full(seg(build(110.24), 0), "wave reaches the top 0.24 beat later")
        XCTAssertGreaterThan(seg(build(110.24), 0), seg(build(110.24), 2))
        full(build(110).left.rgb[0].peak); full(build(110.5).right.rgb[0].peak)
        XCTAssertLessThan(build(110.5).left.rgb[0].peak, 0.2, "only the cyan bed")
        var lit: [Int] = []
        for beat in 108...113 {
            let c = build(Double(beat)).center.cob
            XCTAssertEqual(c.filter { $0 > 0.9 }.count, 1, "one COB at a time")
            lit.append(c.firstIndex { $0 > 0.9 }!)
        }
        XCTAssertEqual(Set(lit).count, 3); XCTAssertTrue(zip(lit, lit.dropFirst()).allSatisfy { $0 != $1 }, "rotates every beat")
        full(build(112).left.cob[0], "bar downbeat on the side COBs")
        assertSame(build(112.3), build(124.3), "after the rise it loops every 12 beats (colour cycle × bar), no fake restart")
    }

    func testDropIsDarkThenImpactsEverythingThenGroovesWithoutFlatWhite() {
        func drop(_ phrase: Double) -> RigFrame { frame(.respiro, 200 + phrase, phrase: phrase) }
        XCTAssertTrue(rgbPeaks(drop(-0.5)).allSatisfy { $0 == 0 } && cobs(drop(-0.5)).allSatisfy { $0 == 0 }, "dark gate")
        let edge = rgbPeaks(drop(-0.03)).max()!
        XCTAssertGreaterThan(edge, 0); XCTAssertLessThan(edge, 0.5)

        let hit = drop(0)
        XCTAssertTrue(rgbPeaks(hit).allSatisfy { abs($0 - 1) < 1e-6 }, "every RGB at 255 on the downbeat")
        XCTAssertEqual(hit.center.cob, [1, 1, 1]); XCTAssertEqual(hit.left.cob[0], 0)
        XCTAssertGreaterThan(hit.left.rgb[0].r, hit.left.rgb[0].b + 0.4, "gold impact, not white")
        XCTAssertGreaterThan(drop(2).left.rgb[0].peak, 0.3, "long RGB tail")
        XCTAssertLessThan(drop(2).center.cob.max()!, 0.01, "shorter COB tail")

        XCTAssertLessThan(seg(drop(4.6), 2), 0.15); full(seg(drop(5), 2), "kick quarters")
        XCTAssertLessThan(drop(5).left.rgb[0].peak, 0.15); full(drop(5.5).left.rgb[0].peak, "offbeat sides")
        full(seg(drop(5.5), 0)); XCTAssertLessThan(seg(drop(5.5), 5), 0.2)
        full(seg(drop(6.5), 5), "top edges alternate")
        let reHit = drop(8).left.rgb[0].peak
        XCTAssertGreaterThan(reHit, 0.25); XCTAssertLessThan(reHit, 0.5, "smaller re-impact at bar 3")
        XCTAssertTrue(rgbPeaks(drop(16)).allSatisfy { abs($0 - 1) < 1e-6 }); XCTAssertEqual(drop(16).center.cob, [1, 1, 1])

        let samples = stride(from: 0.0, to: 16, by: 1 / 30).map { drop($0) }
        let whiteFrames = samples.filter { $0.center.cob.reduce(0, +) / 3 > 0.5 }.count
        XCTAssertLessThan(Double(whiteFrames) / Double(samples.count), 0.1, "not a permanent white")
        let flat = samples.filter { rgbPeaks($0).allSatisfy { $0 > 0.9 } }.count
        XCTAssertLessThan(Double(flat) / Double(samples.count), 0.1, "the full wash is the impact only")
    }

    func testBuildToDropGestureThroughTheSequencer() {
        let build = looks[.aurora]!, drop = looks[.respiro]!
        var seq = SceneSequencer(scene: .ambra, rate: 0.25)
        seq.request(.aurora, look: build, beat: 100.37, now: 0, gridTrusted: true, rateOverride: 1, forceRestart: true)
        seq.advance(beat: 110, bpm: 134, now: 4.3, gridTrusted: true)
        XCTAssertTrue(seq.isRateLocked)
        full(seq.render(beat: 110, energy: 0.7, now: 4.3).center.rgb[2].peak, "real 1× beat, full after the rise")
        seq.request(.respiro, look: drop, beat: 114, now: 6.1, gridTrusted: true, rateOverride: 1, forceRestart: true)
        XCTAssertTrue(seq.pendingIsDownbeat)
        seq.advance(beat: 115.95, bpm: 134, now: 6.97, gridTrusted: true)
        XCTAssertLessThan(rgbPeaks(seq.render(beat: 115.95, energy: 0.7, now: 6.97)).max()!, 0.06, "pre-drop dip")
        seq.advance(beat: 116, bpm: 134, now: 6.99, gridTrusted: true)
        let f = seq.render(beat: 116, energy: 0.7, now: 6.99)
        XCTAssertTrue(rgbPeaks(f).allSatisfy { $0 > 0.999 }); XCTAssertEqual(f.center.cob, [1, 1, 1])
        XCTAssertEqual(seq.patternBeat(beat: 117), 1)
    }

    // MARK: Tempo, 30 Hz sampling, safety

    /// 30 fps frames at 130/134/138 BPM: bounded output, a full centre kick caught on every beat,
    /// full sides and COBs, white never strobing fast or sitting on, RGB never washed to white.
    func testThirtyFPSAtClubTemposCatchesEveryKickAndNeverStrobesWhite() {
        for bpm in bpms {
            let step = bpm / 60 / 30
            for slot in SceneID.allCases {
                let tag = "\(slot.rawValue) @ \(Int(bpm))"
                let beats = Array(stride(from: 0.0137, to: 24, by: step))
                let frames = beats.map { frame(slot, $0) }
                XCTAssertTrue(frames.allSatisfy(bounded), tag)
                for k in 8..<24 {
                    let caught = zip(beats, frames).filter { abs($0.0 - Double(k) - 0.05) < 0.08 }.map { rgbPeaks($0.1).dropFirst().prefix(6).max()! }
                    XCTAssertGreaterThan(caught.max() ?? 0, 0.97, "\(tag): centre kick on beat \(k)")
                }
                XCTAssertGreaterThan(frames.map { max($0.left.rgb[0].peak, $0.right.rgb[0].peak) }.max()!, 0.97, tag)
                XCTAssertGreaterThan(frames.map { cobs($0).max()! }.max()!, 0.97, tag)

                let seconds = Double(frames.count) / 30
                for e in 0..<5 {
                    var onsets = 0, armed = true
                    for f in frames {
                        let v = cobs(f)[e]
                        if armed && v > 0.7 { onsets += 1; armed = false } else if v < 0.3 { armed = true }
                    }
                    XCTAssertLessThanOrEqual(Double(onsets) / seconds, 2.5, "\(tag): COB \(e) flashes at most on quarters")
                }
                let meanCOB = frames.map { cobs($0).reduce(0, +) / 5 }
                XCTAssertLessThan(meanCOB.reduce(0, +) / Double(frames.count), 0.25, "\(tag): no standing white")
                XCTAssertLessThan(Double(meanCOB.filter { $0 > 0.8 }.count) / Double(frames.count), 0.08, tag)
                let washed = frames.flatMap { [$0.left, $0.center, $0.right].flatMap(\.rgb) }.filter { min($0.r, $0.g, $0.b) > 0.8 }
                XCTAssertTrue(washed.isEmpty, "\(tag): RGB keeps its colour")
            }
        }
    }

    /// Every scene moves light across the stage: left, centre and right each pulse, and the centre
    /// segments are never just one flat block.
    func testMovementAcrossLeftCentreAndRight() {
        for slot in SceneID.allCases {
            let frames = stride(from: 16.0, to: 24, by: 1 / 48).map { frame(slot, $0) }
            let left = frames.map { $0.left.rgb[0].peak }, right = frames.map { $0.right.rgb[0].peak }
            let centre = frames.map { $0.center.rgb.map(\.peak).max()! }
            for (name, xs) in [("left", left), ("centre", centre), ("right", right)] {
                XCTAssertGreaterThan(xs.max()! - xs.min()!, 0.6, "\(slot.rawValue): \(name) pulses")
            }
            let contrast = frames.map { $0.center.rgb.map(\.peak).max()! - $0.center.rgb.map(\.peak).min()! }
            XCTAssertGreaterThan(contrast.max()!, 0.6, "\(slot.rawValue): shape inside the triangle")
            let brightest = Set(frames.map { f in f.center.rgb.indices.max { f.center.rgb[$0].peak < f.center.rgb[$1].peak }! })
            XCTAssertGreaterThanOrEqual(brightest.count, 3, "\(slot.rawValue): centre segments take turns")
            if slot != .ambra && slot != .respiro {
                XCTAssertGreaterThan(zip(left, right).map { abs($0 - $1) }.max()!, 0.6, "\(slot.rawValue): sides answer each other")
            }
        }
    }

    /// The real 30 Hz engine (sequencer, master, DMX composer) at each club tempo.
    func testEngineOutputAtClubTempos() {
        for bpm in bpms {
            for slot in SceneID.allCases {
                let clock = ManualClock()
                clock.now = 0
                let engine = LightEngine(tempo: LocalTempoClock(bpm: bpm, now: { clock.now }), transport: FakeTransport(),
                                         clock: { clock.now }, runsTimer: false)
                var patch = VarytecRig.referenceRig()
                patch.setConfirmed(true, library: ProfileLibrary())
                engine.setPatch(patch)
                engine.setMaster(1)
                engine.setEnergy(0.7)
                var snap = EngineSnapshot()
                engine.onSnapshot = { snap = $0 }
                engine.setScene(slot, look: ClubSceneBank.scene(for: slot), immediate: true)
                var centre = 0.0, side = 0.0, cob = 0.0, ok = true
                for i in 0..<Int(17 * 60 / bpm * 30) {
                    clock.now = Double(i) / 30
                    engine.stepForTesting()
                    let fx = snap.fixtures
                    guard fx.count == 3 else { ok = false; break }
                    let values = fx.flatMap { $0.rgb.flatMap { [$0.r, $0.g, $0.b] } + $0.cob }
                    ok = ok && values.allSatisfy { $0.isFinite && (0...1).contains($0) }
                    centre = max(centre, fx[1].rgb.map(\.peak).max() ?? 0)
                    side = max(side, fx[0].rgb[0].peak, fx[2].rgb[0].peak)
                    cob = max(cob, fx.flatMap(\.cob).max() ?? 0)
                }
                let tag = "\(slot.rawValue) @ \(Int(bpm))"
                XCTAssertTrue(ok, tag)
                XCTAssertGreaterThan(centre, 0.97, tag); XCTAssertGreaterThan(side, 0.97, tag); XCTAssertGreaterThan(cob, 0.97, tag)
                XCTAssertNotNil(snap.patternBeat, tag)
            }
        }
    }

    func assertSame(_ a: RigFrame, _ b: RigFrame, _ msg: String = "", line: UInt = #line) {
        for (p, q) in zip([a.left, a.center, a.right], [b.left, b.center, b.right]) {
            for (c, d) in zip(p.rgb, q.rgb) {
                XCTAssertEqual(c.r, d.r, accuracy: 1e-6, msg, line: line); XCTAssertEqual(c.g, d.g, accuracy: 1e-6, line: line)
                XCTAssertEqual(c.b, d.b, accuracy: 1e-6, line: line)
            }
            for (c, d) in zip(p.cob, q.cob) { XCTAssertEqual(c, d, accuracy: 1e-6, msg, line: line) }
        }
    }
}
