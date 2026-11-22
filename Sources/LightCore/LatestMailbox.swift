import Foundation

/// Latest-only hand-off from the 30 Hz engine queue to the UI.
///
/// `post` keeps only the newest value and reports whether the consumer must be woken; at most one
/// wake-up is outstanding, so a busy main thread can never accumulate a backlog of stale snapshots
/// (each holding fixture and network arrays). It catches up with the newest frame instead.
/// The engine and DMX output are unaffected: they keep running at their own rate.
public final class LatestMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var wakePending = false

    public init() {}

    /// Stores `newValue`, replacing any value not yet taken. Returns true when the caller must
    /// schedule one `take()` (no wake-up was outstanding).
    @discardableResult
    public func post(_ newValue: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        value = newValue
        if wakePending { return false }
        wakePending = true
        return true
    }

    /// Takes the newest value and re-arms wake-ups. Values posted after this return true again.
    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        let newest = value
        value = nil
        wakePending = false
        return newest
    }

    /// Posts and, when needed, schedules a single drain on `queue` that delivers the newest value.
    public func post(_ newValue: Value, on queue: DispatchQueue, deliver: @escaping (Value) -> Void) {
        guard post(newValue) else { return }
        queue.async { [self] in
            if let newest = take() { deliver(newest) }
        }
    }
}
