import Foundation
import RaysCore

/// Output safety rules as a pure state machine: whether DMX may be sent, and when the engine must
/// send black frames first. `LightEngine` does all the I/O; the gate only decides.
///
/// Invariants (covered by `OutputGateTests`):
/// - Blackout always wins: it ends a running diagnostic, and no diagnostic starts during it.
/// - Output is armed only by an explicit request or a diagnostic while the output is ready. Patch,
///   node or driver changes, lost readiness and the end of a diagnostic never arm it.
/// - A diagnostic returns the output to the armed state it found.
/// - `.sendBlack` is only returned by a transition that disarms an armed output.
struct OutputGate: Equatable, Sendable {
    /// A short static test running on the real output.
    struct Diagnostic: Equatable, Sendable {
        var color: LightColor
        var target: DiagnosticTarget
        /// Clock time at which the test ends by itself.
        var end: TimeInterval
        /// Output state to return to when the test ends.
        var armedBefore: Bool
    }

    /// What the engine must do after a transition, in this order.
    struct Effects: OptionSet, Sendable {
        let rawValue: Int
        /// Send zero frames to the current target: the output was armed until this transition.
        static let sendBlack = Effects(rawValue: 1 << 0)
        /// Cancel the momentary accent.
        static let killAccent = Effects(rawValue: 1 << 1)
        /// Render a frame now instead of waiting for the next tick.
        static let renderNow = Effects(rawValue: 1 << 2)
    }

    static let diagnosticDurations: ClosedRange<TimeInterval> = 0.5...10
    static let defaultDiagnosticDuration: TimeInterval = 5

    /// DMX is being sent (or would be, once a frame finds the output ready).
    private(set) var armed = false
    /// The user wants output; kept through outages so a returning device resumes by itself.
    private(set) var requested = false
    private(set) var blackout = false
    private(set) var diagnostic: Diagnostic?
    /// The engine timer and driver are running.
    private(set) var running = false
    /// Stopped for system sleep; armed state and request are kept for wake.
    private(set) var suspended = false

    var isTesting: Bool { diagnostic != nil }
    /// Output intent: on, or waiting for the device to come back.
    var wantsOutput: Bool { requested || armed }

    // MARK: Lifecycle

    /// Engine start or wake. False when it was already running.
    mutating func start() -> Bool {
        guard !running else { return false }
        running = true
        suspended = false
        return true
    }

    /// Engine stop: black frames if armed. Armed state and request are kept.
    mutating func stop() -> Effects {
        let effects: Effects = armed ? .sendBlack : []
        running = false
        return effects
    }

    /// System sleep. Nil when the engine is not running.
    mutating func suspend() -> Effects? {
        guard running else { return nil }
        let effects = stop()
        suspended = true
        return effects
    }

    /// Wake: true when the engine must start again.
    mutating func resume() -> Bool {
        guard suspended else { return false }
        return start()
    }

    /// App termination: black frames if armed, then output off and no pending request.
    mutating func shutdown() -> Effects {
        let effects = stop()
        armed = false
        requested = false
        return effects
    }

    // MARK: User actions

    /// The output button. On arms only when ready; off also cancels a pending request and a diagnostic.
    mutating func setOutput(_ on: Bool, ready: Bool) -> Effects {
        if on {
            if ready {
                requested = true
                armed = true
            }
            return []
        }
        let effects: Effects = armed ? .sendBlack : []
        requested = false
        diagnostic = nil
        armed = false
        return effects
    }

    /// Restores a saved output request before the device is discovered. Frames arm it once ready.
    mutating func restoreRequest() { requested = true }

    /// Blackout always wins: switching it on ends a diagnostic and kills the accent.
    mutating func setBlackout(_ on: Bool) -> Effects {
        blackout = on
        guard on else { return [] }
        return endDiagnostic().union([.killAccent, .renderNow])
    }

    /// Starts (or retargets) a diagnostic, arming the output for it. Ignored during blackout, when
    /// the output is not ready or for a non-finite color. `ready` is only evaluated when needed.
    mutating func startDiagnostic(
        _ color: LightColor, target: DiagnosticTarget, duration: TimeInterval, now: TimeInterval,
        ready: @autoclosure () -> Bool
    ) -> Effects {
        guard color.isFinite, !blackout, ready() else { return [] }
        let seconds = duration.isFinite ? duration : Self.defaultDiagnosticDuration
        let range = Self.diagnosticDurations
        diagnostic = Diagnostic(
            color: color.clamped, target: target, end: now + min(range.upperBound, max(range.lowerBound, seconds)),
            armedBefore: diagnostic?.armedBefore ?? armed)
        armed = true
        return .renderNow
    }

    /// Ends a diagnostic and restores the armed state from before it (black frames if it was off).
    mutating func endDiagnostic() -> Effects {
        guard let test = diagnostic else { return [] }
        diagnostic = nil
        guard !test.armedBefore else { return [] }
        let effects: Effects = armed ? .sendBlack : []
        armed = false
        return effects
    }

    /// The patch changed: disarm, drop the request and end any diagnostic without restoring it.
    mutating func patchChanged() -> Effects {
        let effects = destinationChanged()
        diagnostic = nil
        return effects
    }

    /// The node, manual IP or driver changed: disarm and drop the request.
    mutating func destinationChanged() -> Effects {
        requested = false
        guard armed else { return [] }
        armed = false
        return .sendBlack
    }

    // MARK: Frames

    /// Start of a frame: a diagnostic whose time is up ends.
    mutating func expireDiagnostic(now: TimeInterval) -> Effects {
        guard let test = diagnostic, now >= test.end else { return [] }
        return endDiagnostic()
    }

    /// After rendering a frame: lost readiness disarms (keeping the request, ending a diagnostic);
    /// a pending request arms once the output is ready again.
    mutating func frame(ready: Bool) -> Effects {
        var effects: Effects = []
        if armed, !ready {
            effects = .sendBlack
            armed = false
            diagnostic = nil
        }
        if requested, ready { armed = true }
        return effects
    }
}
