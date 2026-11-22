import Foundation

/// One balanced activity for the lighting session, owned by the engine's serial queue.
/// Prevents App Nap and idle system sleep, but lets the display turn off normally.
/// Explicit sleep / lid closure still follow macOS's normal lifecycle.
public final class OutputActivity {
    public static let options: ProcessInfo.ActivityOptions = .userInitiated
    public static let reason = "RAYS — invio luci e riconnessione automatica"

    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?

    public init() {
        begin = { ProcessInfo.processInfo.beginActivity(options: Self.options, reason: Self.reason) }
        end = { ProcessInfo.processInfo.endActivity($0) }
    }

    /// Injectable only inside the module for lifecycle tests without changing power state.
    init(begin: @escaping () -> NSObjectProtocol, end: @escaping (NSObjectProtocol) -> Void) {
        self.begin = begin
        self.end = end
    }

    deinit { stop() }

    public func update(active: Bool) {
        if active {
            if token == nil { token = begin() }
        } else { stop() }
    }

    public func stop() {
        guard let token else { return }
        self.token = nil
        end(token)
    }
}
