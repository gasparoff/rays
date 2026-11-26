import Foundation
import Network
import RaysTempo

/// Follows openDJ on this Mac over OSC (only when the beat source is "openDJ"): subscribes to its
/// beat and phrase events and renews the subscription, so an openDJ started later is found too.
/// Beats are passed on like Pro DJ Link beats: into the Ableton Link timeline.
@MainActor
final class OpenDJListener: ObservableObject {
    static let staleAfter: TimeInterval = 2
    static let renewEvery: TimeInterval = 3
    /// openDJ's beats arrive a few milliseconds after they play, each a little later or earlier
    /// than the last. Within this many beats the Link timeline is left alone, so the lights don't
    /// shift on every beat and a session openDJ also leads over Link isn't pulled away from it.
    nonisolated static let beatTolerance = 0.05

    @Published private(set) var timeline = OpenDJTimeline()
    @Published private(set) var lastBeatTime: Date?
    @Published private(set) var lastHeard: Date?

    /// Called on the listener's queue for every beat, so a busy main thread doesn't delay it.
    /// Set it before `start()`.
    var onBeat: (@Sendable (Double, Int) -> Void)?
    var isLive: Bool { lastBeatTime.map { Date().timeIntervalSince($0) < Self.staleAfter } ?? false }
    /// openDJ answers every renewal unless it is set to send only; then only its beats show it is there.
    var isAnswering: Bool { lastHeard.map { Date().timeIntervalSince($0) < Self.renewEvery * 2.5 } ?? false }

    private let queue = DispatchQueue(label: "rays.opendj")
    private var connection: NWConnection?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        renew()
        timer = Timer.scheduledTimer(withTimeInterval: Self.renewEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renew() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        connection?.cancel(); connection = nil
        timeline = OpenDJTimeline(); lastBeatTime = nil; lastHeard = nil
    }

    private func renew() {
        objectWillChange.send()  // expires the visible status even without events
        let connection = connection ?? connect()
        connection.send(content: OpenDJEvent.subscription, completion: .contentProcessed { _ in })
    }

    /// openDJ answers on the port a message came from, so one socket both subscribes and listens.
    /// It listens on IPv4 only: "localhost" could pick IPv6 and never reach it.
    private func connect() -> NWConnection {
        let port = NWEndpoint.Port(rawValue: OpenDJEvent.defaultPort) ?? 9000
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .udp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .waiting: DispatchQueue.main.async { self?.drop(connection) }
            default: break
            }
        }
        self.connection = connection
        Self.receive(on: connection, onBeat: onBeat) { [weak self, weak connection] result in
            DispatchQueue.main.async {
                switch result {
                case let .success(events): self?.heard(events, on: connection)
                case .failure: self?.drop(connection)
                }
            }
        }
        connection.start(queue: queue)
        return connection
    }

    /// With openDJ closed the port refuses the packet and the socket reports it: the next renewal
    /// opens a new one.
    private func drop(_ old: NWConnection?) {
        guard let old, old === connection else { return }
        old.cancel()
        connection = nil
    }

    private func heard(_ events: [OpenDJEvent], on source: NWConnection?) {
        guard let source, source === connection else { return }
        lastHeard = Date()
        for event in events {
            timeline.apply(event)
            if case .beat = event { lastBeatTime = lastHeard }
        }
    }

    private nonisolated static func receive(
        on connection: NWConnection, onBeat: (@Sendable (Double, Int) -> Void)?,
        report: @escaping @Sendable (Result<[OpenDJEvent], NWError>) -> Void
    ) {
        connection.receiveMessage { data, _, _, error in
            if let data {
                let messages = OSCMessage.decode(data)
                let events = messages.compactMap(OpenDJEvent.init)
                for case let .beat(beatInBar, _, bpm) in events { onBeat?(bpm, beatInBar) }
                if !messages.isEmpty { report(.success(events)) }
            }
            if let error {
                report(.failure(error))
            } else {
                receive(on: connection, onBeat: onBeat, report: report)
            }
        }
    }
}
