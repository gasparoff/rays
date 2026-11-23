import XCTest
@testable import RaysCore
@testable import RaysEngine

/// The output safety rules on their own, without an engine, driver or clock.
final class OutputGateTests: XCTestCase {
    private static let red = LightColor(1, 0, 0)

    /// Every state the gate can be in that matters for safety.
    private static var states: [(name: String, gate: OutputGate)] {
        func make(_ name: String, _ build: (inout OutputGate) -> Void) -> (name: String, gate: OutputGate) {
            var gate = OutputGate()
            _ = gate.start()
            build(&gate)
            return (name, gate)
        }
        return [
            (name: "stopped", gate: OutputGate()),
            make("off") { _ in },
            make("pending request") { $0.restoreRequest() },
            make("on") { _ = $0.setOutput(true, ready: true) },
            make("on, lost readiness") { g in
                _ = g.setOutput(true, ready: true)
                _ = g.frame(ready: false)
            },
            make("test from off") { _ = $0.startDiagnostic(OutputGateTests.red, target: .all, duration: 5, now: 0, ready: true) },
            make("test from on") { g in
                _ = g.setOutput(true, ready: true)
                _ = g.startDiagnostic(OutputGateTests.red, target: .segment(2), duration: 5, now: 0, ready: true)
            },
            make("pending request, test") { g in
                g.restoreRequest()
                _ = g.startDiagnostic(OutputGateTests.red, target: .cob(1), duration: 5, now: 0, ready: true)
            },
            make("blackout") { _ = $0.setBlackout(true) },
            make("on, blackout") { g in
                _ = g.setOutput(true, ready: true)
                _ = g.setBlackout(true)
            },
            make("suspended, on") { g in
                _ = g.setOutput(true, ready: true)
                _ = g.suspend()
            },
        ]
    }

    /// Every transition, with both readiness answers where it takes one.
    private static let transitions: [(name: String, apply: (inout OutputGate) -> OutputGate.Effects)] = [
        ("start", { g in _ = g.start(); return [] }),
        ("stop", { $0.stop() }),
        ("suspend", { $0.suspend() ?? [] }),
        ("resume", { g in _ = g.resume(); return [] }),
        ("shutdown", { $0.shutdown() }),
        ("output on, ready", { $0.setOutput(true, ready: true) }),
        ("output on, not ready", { $0.setOutput(true, ready: false) }),
        ("output off", { $0.setOutput(false, ready: true) }),
        ("restore request", { g in g.restoreRequest(); return [] }),
        ("blackout on", { $0.setBlackout(true) }),
        ("blackout off", { $0.setBlackout(false) }),
        ("test, ready", { $0.startDiagnostic(OutputGateTests.red, target: .all, duration: 5, now: 1, ready: true) }),
        ("test, not ready", { $0.startDiagnostic(OutputGateTests.red, target: .all, duration: 5, now: 1, ready: false) }),
        ("end test", { $0.endDiagnostic() }),
        ("test expires", { $0.expireDiagnostic(now: 1000) }),
        ("patch changed", { $0.patchChanged() }),
        ("destination changed", { $0.destinationChanged() }),
        ("frame, ready", { $0.frame(ready: true) }),
        ("frame, not ready", { $0.frame(ready: false) }),
    ]

    func testBlackFramesOnlyWhenAnArmedOutputIsDisarmed() {
        for (state, start) in Self.states {
            for (name, apply) in Self.transitions {
                var gate = start
                let effects = apply(&gate)
                if effects.contains(.sendBlack) {
                    XCTAssertTrue(start.armed, "\(state) → \(name): black frames without armed output")
                    XCTAssertFalse(gate.armed && name != "stop" && name != "suspend", "\(state) → \(name): black frames but still armed")
                }
                if start.armed, !gate.armed {
                    XCTAssertTrue(effects.contains(.sendBlack), "\(state) → \(name): disarmed without black frames")
                }
            }
        }
    }

    func testBlackoutWinsInEveryState() {
        for (state, start) in Self.states {
            var gate = start
            let effects = gate.setBlackout(true)
            XCTAssertTrue(gate.blackout, state)
            XCTAssertNil(gate.diagnostic, "\(state): blackout ends a diagnostic")
            XCTAssertTrue(effects.isSuperset(of: [.killAccent, .renderNow]), state)
            if let test = start.diagnostic, !test.armedBefore {
                XCTAssertFalse(gate.armed, "\(state): a test from off returns to off")
                XCTAssertTrue(effects.contains(.sendBlack), state)
            } else {
                XCTAssertEqual(gate.armed, start.armed, "\(state): blackout keeps the output state")
                XCTAssertFalse(effects.contains(.sendBlack), state)
            }

            var probed = false
            let before = gate
            XCTAssertEqual(
                gate.startDiagnostic(Self.red, target: .all, duration: 5, now: 0, ready: { probed = true; return true }()), [])
            XCTAssertEqual(gate, before, "\(state): no diagnostic during blackout")
            XCTAssertFalse(probed, "readiness is not even checked during blackout")

            for (name, apply) in Self.transitions where name != "blackout off" {
                var next = gate
                _ = apply(&next)
                XCTAssertTrue(next.blackout, "\(state) → \(name): only the user clears blackout")
                XCTAssertNil(next.diagnostic, "\(state) → \(name)")
            }
        }
    }

    func testPatchNodeAndDriverChangesNeverTurnOutputOn() {
        for (state, start) in Self.states {
            for change in [{ (g: inout OutputGate) in g.patchChanged() }, { (g: inout OutputGate) in g.destinationChanged() }] {
                var gate = start
                _ = change(&gate)
                XCTAssertFalse(gate.armed, state)
                XCTAssertFalse(gate.requested, "\(state): a change drops the pending request")
                _ = gate.frame(ready: true)
                XCTAssertFalse(gate.armed, "\(state): the next ready frame must not arm")
                _ = gate.endDiagnostic()
                _ = gate.frame(ready: true)
                XCTAssertFalse(gate.armed, "\(state): neither must the end of a diagnostic")
            }
            var patched = start
            _ = patched.patchChanged()
            XCTAssertNil(patched.diagnostic, "\(state): a patch change ends the diagnostic")
        }
    }

    func testEndOfDiagnosticNeverTurnsOutputOn() {
        for (state, start) in Self.states where start.diagnostic != nil {
            for end in [{ (g: inout OutputGate) in g.endDiagnostic() }, { (g: inout OutputGate) in g.expireDiagnostic(now: 1000) }] {
                var gate = start
                _ = gate.destinationChanged()
                _ = end(&gate)
                XCTAssertNil(gate.diagnostic, state)
                XCTAssertFalse(gate.armed, "\(state): output switched off during a test stays off")
            }
        }
    }

    func testDiagnosticRestoresTheArmedStateItFound() {
        var off = OutputGate()
        _ = off.start()
        XCTAssertEqual(off.startDiagnostic(Self.red, target: .all, duration: 5, now: 10, ready: true), .renderNow)
        XCTAssertTrue(off.armed)
        XCTAssertTrue(off.isTesting)
        XCTAssertFalse(off.requested, "a test is not an output request")
        XCTAssertEqual(off.endDiagnostic(), .sendBlack)
        XCTAssertFalse(off.armed)

        var on = OutputGate()
        _ = on.start()
        _ = on.setOutput(true, ready: true)
        _ = on.startDiagnostic(Self.red, target: .all, duration: 5, now: 10, ready: true)
        XCTAssertEqual(on.endDiagnostic(), [])
        XCTAssertTrue(on.armed)
        XCTAssertTrue(on.requested)

        var retargeted = OutputGate()
        _ = retargeted.start()
        _ = retargeted.startDiagnostic(Self.red, target: .all, duration: 5, now: 10, ready: true)
        _ = retargeted.startDiagnostic(Self.red, target: .segment(1), duration: 5, now: 11, ready: true)
        XCTAssertEqual(retargeted.diagnostic?.target, .segment(1))
        XCTAssertEqual(retargeted.diagnostic?.armedBefore, false, "a second test keeps the state from before the first")
        XCTAssertEqual(retargeted.endDiagnostic(), .sendBlack)
        XCTAssertFalse(retargeted.armed)
    }

    func testDiagnosticExpiresAtItsEnd() {
        var gate = OutputGate()
        _ = gate.start()
        _ = gate.startDiagnostic(LightColor(2, -1, 0.5, 1), target: .all, duration: 3, now: 100, ready: true)
        XCTAssertEqual(gate.diagnostic?.color, LightColor(1, 0, 0.5, 1), "colors are clamped")
        XCTAssertEqual(gate.expireDiagnostic(now: 102.9), [])
        XCTAssertTrue(gate.isTesting)
        XCTAssertEqual(gate.expireDiagnostic(now: 103), .sendBlack)
        XCTAssertFalse(gate.isTesting)
        XCTAssertFalse(gate.armed)
        XCTAssertEqual(gate.expireDiagnostic(now: 104), [])
    }

    func testDiagnosticNeedsReadyOutputAndAFiniteColorAndBoundsItsDuration() {
        var gate = OutputGate()
        _ = gate.start()
        XCTAssertEqual(gate.startDiagnostic(Self.red, target: .all, duration: 5, now: 0, ready: false), [])
        XCTAssertEqual(gate.startDiagnostic(LightColor(.nan, 0, 0), target: .all, duration: 5, now: 0, ready: true), [])
        XCTAssertFalse(gate.armed)
        XCTAssertNil(gate.diagnostic)
        for (duration, length) in [(0.1, 0.5), (60, 10), (.infinity, 5), (.nan, 5), (2, 2)] as [(Double, Double)] {
            _ = gate.startDiagnostic(Self.red, target: .all, duration: duration, now: 0, ready: true)
            XCTAssertEqual(gate.diagnostic?.end, length, "duration \(duration)")
        }
    }

    func testLostReadinessKeepsTheRequestAndResumesOnlyIt() {
        var gate = OutputGate()
        _ = gate.start()
        _ = gate.setOutput(true, ready: true)
        _ = gate.startDiagnostic(Self.red, target: .all, duration: 5, now: 0, ready: true)
        XCTAssertEqual(gate.frame(ready: false), .sendBlack)
        XCTAssertFalse(gate.armed)
        XCTAssertTrue(gate.requested)
        XCTAssertNil(gate.diagnostic, "an outage ends the test")
        XCTAssertEqual(gate.frame(ready: false), [])
        XCTAssertEqual(gate.frame(ready: true), [])
        XCTAssertTrue(gate.armed, "the returning device resumes the user's output")

        var test = OutputGate()
        _ = test.start()
        _ = test.startDiagnostic(Self.red, target: .all, duration: 5, now: 0, ready: true)
        _ = test.frame(ready: false)
        _ = test.frame(ready: true)
        XCTAssertFalse(test.armed, "a test from off leaves no request behind")
        XCTAssertFalse(test.requested)
    }

    func testOutputButton() {
        var gate = OutputGate()
        _ = gate.start()
        XCTAssertEqual(gate.setOutput(true, ready: false), [])
        XCTAssertFalse(gate.armed)
        XCTAssertFalse(gate.requested, "pressing on while not ready does not leave a request")
        gate.restoreRequest()
        XCTAssertTrue(gate.wantsOutput)
        XCTAssertFalse(gate.armed, "a restored request waits for a ready frame")
        XCTAssertEqual(gate.setOutput(false, ready: true), [], "nothing was armed: no black frames")
        XCTAssertFalse(gate.wantsOutput)
        _ = gate.setOutput(true, ready: true)
        _ = gate.startDiagnostic(Self.red, target: .all, duration: 5, now: 0, ready: true)
        XCTAssertEqual(gate.setOutput(false, ready: true), .sendBlack)
        XCTAssertFalse(gate.armed)
        XCTAssertNil(gate.diagnostic)
        XCTAssertFalse(gate.requested)
    }

    func testLifecycleKeepsOutputIntentAcrossSleep() {
        var gate = OutputGate()
        XCTAssertNil(gate.suspend(), "not running")
        XCTAssertFalse(gate.resume())
        XCTAssertTrue(gate.start())
        XCTAssertFalse(gate.start(), "already running")
        _ = gate.setOutput(true, ready: true)
        XCTAssertEqual(gate.suspend(), .sendBlack)
        XCTAssertTrue(gate.suspended)
        XCTAssertFalse(gate.running)
        XCTAssertTrue(gate.armed, "armed state is kept for wake; the next frame decides")
        XCTAssertTrue(gate.requested)
        XCTAssertTrue(gate.resume())
        XCTAssertFalse(gate.suspended)
        XCTAssertFalse(gate.resume())
        XCTAssertEqual(gate.shutdown(), .sendBlack)
        XCTAssertFalse(gate.running)
        XCTAssertFalse(gate.wantsOutput)
        XCTAssertEqual(gate.shutdown(), [])
    }
}
