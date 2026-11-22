import XCTest
@testable import LightCore

final class BuildDropTests: XCTestCase {
    /// Build pressed off-grid at Link beat 100.37: pulses follow the beat, tension the press.
    let press = 100.37
    func build(_ beat: Double, energy: Double = 0.47) -> RigFrame {
        Choreography.render(.aurora, SceneContext(beat: beat, phrase: beat - press, energy: energy))
    }
    func drop(_ rd: Double, energy: Double = 0.47) -> RigFrame {
        Choreography.render(.respiro, SceneContext(beat: 104 + rd, phrase: rd, energy: energy))
    }
    func peak(_ f: RoleFrame) -> Double { f.rgb.map(\.peak).max() ?? 0 }
    func mean(_ f: RoleFrame) -> Double { f.rgb.map(\.peak).reduce(0, +) / Double(f.rgb.count) }
    func assertSame(_ a: RigFrame, _ b: RigFrame, _ msg: String = "", line: UInt = #line) {
        let x = [a.left, a.center, a.right], y = [b.left, b.center, b.right]
        for (p, q) in zip(x, y) {
            for (c, d) in zip(p.rgb, q.rgb) { XCTAssertEqual(c.peak, d.peak, accuracy: 1e-6, msg, line: line); XCTAssertEqual(c.r, d.r, accuracy: 1e-6, line: line) }
            for (c, d) in zip(p.cob, q.cob) { XCTAssertEqual(c, d, accuracy: 1e-6, msg, line: line) }
        }
    }
    func average(_ beats: StrideTo<Double>, _ value: (Double) -> Double) -> Double {
        let xs = Array(beats); return xs.map(value).reduce(0, +) / Double(xs.count)
    }

    func testBuildIsAliveOnThePressAtModerateEnergyAndOnTheLeftSide() {
        let first = build(press)
        XCTAssertGreaterThan(peak(first.center), 0.25)
        XCTAssertGreaterThan(first.left.rgb[0].peak, 0.12, "a single TRI 180 must show the build immediately")
        // The left side calls on the beat from the first bar.
        XCTAssertGreaterThan(build(101).left.rgb[0].peak, build(101.5).left.rgb[0].peak + 0.08)
    }

    func testBuildRisesInLevelWarmthAndDensityWithinSixteenBeats() {
        let early = average(stride(from: press, to: press + 2, by: 1 / 32)) { self.mean(self.build($0).center) }
        let late = average(stride(from: press + 14, to: press + 16, by: 1 / 32)) { self.mean(self.build($0).center) }
        XCTAssertGreaterThan(late, early * 1.5)
        let leftEarly = average(stride(from: press, to: press + 2, by: 1 / 32)) { self.build($0).left.rgb[0].peak }
        let leftLate = average(stride(from: press + 14, to: press + 16, by: 1 / 32)) { self.build($0).left.rgb[0].peak }
        XCTAssertGreaterThan(leftLate, leftEarly * 1.4)
        XCTAssertGreaterThan(build(press + 15).center.rgb[0].r, build(press + 1).center.rgb[0].r + 0.2, "colour climbs warm")

        func maxima(from start: Double) -> Int {
            let ys = stride(from: start, to: start + 1, by: 1 / 96).map { self.build($0).center.rgb[2].peak }
            return (1..<ys.count - 1).filter { ys[$0] > ys[$0 - 1] && ys[$0] >= ys[$0 + 1] }.count
        }
        XCTAssertGreaterThanOrEqual(maxima(from: 115), maxima(from: 102) + 2, "quarters → 16ths")
    }

    func testBuildHoldsPeakTensionPeriodicallyInsteadOfRestarting() {
        for beat in [press + 20.3, press + 41.9] {
            assertSame(build(beat), build(beat + 12), "plateau repeats every 3 bars")
        }
        XCTAssertGreaterThan(mean(build(press + 64).center), mean(build(press + 1).center))
    }

    func testDropDipsThenHitsBigThenSettlesOnAKickAndOffbeatFloor() {
        let dip = drop(-0.2), hit = drop(0), floor = drop(3.75)
        let plateau = average(stride(from: press + 20, to: press + 22, by: 1 / 32)) { self.mean(self.build($0).center) }
        XCTAssertLessThan(peak(dip.center), 0.08)
        XCTAssertEqual(dip.left.rgb[0].peak, 0)
        XCTAssertEqual(dip.center.cob, [0, 0, 0])
        XCTAssertGreaterThan(hit.center.rgb.map(\.peak).min()!, 0.9, "impact lights every segment")
        XCTAssertGreaterThan(mean(hit.center), plateau + 0.2)
        XCTAssertGreaterThan(hit.left.rgb[0].peak, 0.9)
        XCTAssertGreaterThan(hit.center.cob.min()!, 0.2)
        XCTAssertGreaterThan(hit.center.rgb[0].r, hit.center.rgb[0].b + 0.3, "warm impact, not white")
        XCTAssertLessThan(peak(floor.center), 0.25, "clean low floor")
        XCTAssertGreaterThan(peak(drop(5).center), peak(drop(5.4).center) + 0.2, "kick")
        XCTAssertGreaterThan(drop(4.5).left.rgb[0].peak, drop(4).left.rgb[0].peak + 0.15, "left offbeat accent")
        XCTAssertGreaterThan(drop(5.5).left.rgb[0].peak, drop(5).left.rgb[0].peak + 0.05, "left offbeat")
        XCTAssertGreaterThan(peak(drop(8).center), peak(drop(7.6).center) + 0.4, "re-impact")
        XCTAssertLessThan(peak(drop(8).center) - 0.01, peak(hit.center))
        for rd in [9.3, 40.1, 77.55] { assertSame(drop(rd), drop(rd + 96)) }
    }

    func testBuildAndDropStayCappedFiniteAndWithoutStrobeChannels() {
        let phases: [Double] = [-1e9, -3, -0.25, -0.03, 0, 0.01, 3.99, 15.99, 16, 31.6, 1e9, .nan, .infinity, -.infinity]
        for scene in [SceneID.aurora, .respiro] {
            for phase in phases + stride(from: -1, to: 40, by: 0.13).map({ $0 }) {
                for energy in [0, 0.47, 1, .nan] {
                    let f = Choreography.render(scene, SceneContext(beat: phase + 0.37, phrase: phase, energy: energy))
                    XCTAssertTrue(f.isFinite)
                    for c in f.left.rgb + f.center.rgb + f.right.rgb {
                        XCTAssertTrue(c.peak <= 1 && min(c.r, c.g, c.b) >= 0)
                        XCTAssertEqual(c.w, 0)
                    }
                    XCTAssertTrue(f.center.cob.allSatisfy { (0...1).contains($0) })
                    XCTAssertTrue((f.left.cob + f.right.cob).allSatisfy { (0...1).contains($0) })
                }
            }
        }
    }

    func testHoldGestureIgnoresSlowUserRateAndReleaseLandsOnTheDownbeat() {
        var seq = SceneSequencer(scene: .ambra, rate: 0.25)
        seq.request(.aurora, beat: 100.37, now: 0, gridTrusted: true, rateOverride: 1, forceRestart: true)
        seq.advance(beat: 101.2, bpm: 125, now: 0.4, gridTrusted: true)
        XCTAssertEqual(seq.targetScene, .aurora)
        let held = Choreography.render(.aurora, SceneContext(beat: 101.2, phrase: 101.2 - 100.87, energy: 0.47))
        assertSame(seq.render(beat: 101.2, energy: 0.47, now: 0.4), held, "Build at Link rate, ×¼ ignored")

        // Early release on beat 2 of the bar waits for the downbeat with a dark dip just before.
        seq.request(.respiro, beat: 114, now: 6.4, gridTrusted: true, rateOverride: 1, forceRestart: true)
        XCTAssertEqual(seq.pendingScene, .respiro)
        seq.advance(beat: 115.9, bpm: 125, now: 7.3, gridTrusted: true)
        let dip = seq.render(beat: 115.9, energy: 0.47, now: 7.3)
        XCTAssertLessThan(mean(dip.center), mean(build(115.9).center) * 0.75)
        seq.advance(beat: 116, bpm: 125, now: 7.35, gridTrusted: true)
        XCTAssertGreaterThan(seq.render(beat: 116, energy: 0.47, now: 7.35).center.rgb.map(\.peak).min()!, 0.9)

        // A release just after the downbeat hits now instead of a bar later.
        var late = SceneSequencer(scene: .aurora, rate: 0.25)
        late.request(.respiro, beat: 120.2, now: 0, gridTrusted: true, rateOverride: 1, forceRestart: true)
        XCTAssertNil(late.pendingScene)
        XCTAssertGreaterThan(peak(late.render(beat: 120.2, energy: 0.47, now: 0).center), 0.8)
    }
}
