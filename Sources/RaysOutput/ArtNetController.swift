import Foundation

/// Where DMX goes. `verified` is true only when the node answered ArtPoll.
public struct OutputTarget: Equatable, Sendable {
    public var ip: IPv4Address
    public var name: String
    public var universes: [PortAddress]
    public var verified: Bool
    public var fresh: Bool
    /// Non-IP endpoint (e.g. a serial device path) or a description such as "multicast".
    public var endpoint: String? = nil

    /// What the UI shows next to the target name.
    public var displayAddress: String { endpoint ?? ip.description }
}

/// Art-Net discovery + unicast ArtDmx. Not thread-safe: use from a single serial queue.
public final class ArtNetController {
    public static let pollInterval: TimeInterval = 3

    private let transport: DatagramTransport
    private let interfaceProvider: () -> [NetworkInterface]
    public private(set) var registry = NodeRegistry()
    public private(set) var interfaces: [NetworkInterface] = []
    public private(set) var socketError: String?
    public private(set) var pollError: String?
    public private(set) var sendError: String?
    public private(set) var lastPollTime: TimeInterval = -.infinity
    public private(set) var pollCount = 0
    private var sequences: [PortAddress: UInt8] = [:]

    /// Identity of the node chosen by the user or auto-selected (persisted by the app).
    public var preferredIdentity: String?
    /// Manual IPv4 fallback; unverified until that address answers ArtPoll.
    public var manualIP: IPv4Address?
    public var onPreferredIdentityChanged: ((String?) -> Void)?

    public init(transport: DatagramTransport, interfaces: @escaping () -> [NetworkInterface] = NetworkInterface.current) {
        self.transport = transport
        self.interfaceProvider = interfaces
    }

    public var isOpen: Bool { transport.isOpen }

    public func open(queue: DispatchQueue, now: @escaping () -> TimeInterval) {
        do {
            try transport.open(port: ArtNet.port, queue: queue) { [weak self] bytes, sender in
                self?.handle(bytes, from: sender, now: now())
            }
            socketError = nil
        } catch {
            socketError = error.localizedDescription
        }
    }

    public func close() { transport.close() }

    /// Sends ArtPoll to each active LAN broadcast address (and the manual IP, if any). Never scans hosts.
    public func pollIfDue(now: TimeInterval) {
        guard now - lastPollTime >= Self.pollInterval else { return }
        lastPollTime = now
        interfaces = interfaceProvider()
        registry.refresh(now: now, keeping: preferredIdentity)
        guard transport.isOpen else { return }
        let packet = ArtNet.artPoll()
        var errors: [String] = []
        var destinations = interfaces.map(\.broadcast)
        if let manualIP { destinations.append(manualIP) }
        for destination in Set(destinations) {
            do { try transport.send(packet, to: destination, port: ArtNet.port) } catch {
                errors.append("\(destination): \(error.localizedDescription)")
            }
        }
        pollCount += 1
        pollError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    public func forcePoll(now: TimeInterval) {
        lastPollTime = -.infinity
        pollIfDue(now: now)
    }

    public func handle(_ bytes: [UInt8], from sender: IPv4Address, now: TimeInterval) {
        guard ArtNet.opCode(of: bytes) == ArtNet.OpCode.pollReply.rawValue,
            let reply = try? ArtPollReply.parse(bytes)
        else { return }  // ignores our own ArtPoll/ArtDmx and malformed data
        registry.ingest(reply, from: sender, at: now)
        if preferredIdentity == nil, manualIP == nil, let candidate = registry.autoSelectCandidate(now: now) {
            preferredIdentity = candidate.id
            onPreferredIdentityChanged?(candidate.id)
        }
    }

    public func select(identity: String?) {
        preferredIdentity = identity
        if identity != nil { manualIP = nil }
        sequences.removeAll()
    }

    public func nodes(now: TimeInterval) -> [DiscoveredNode] {
        registry.sortedNodes.map { node in
            var n = node
            n.isStale = now - node.lastSeen > registry.staleAfter
            return n
        }
    }

    public func target(now: TimeInterval, patchUniverses: [PortAddress]) -> OutputTarget? {
        if let manualIP {
            if let node = registry.node(at: manualIP) {
                return OutputTarget(
                    ip: manualIP, name: node.displayName, universes: node.outputUniverses,
                    verified: true, fresh: now - node.lastSeen <= registry.staleAfter)
            }
            return OutputTarget(ip: manualIP, name: "IP manuale", universes: patchUniverses, verified: false, fresh: false)
        }
        guard let node = registry.node(id: preferredIdentity) else { return nil }
        return OutputTarget(
            ip: node.ip, name: node.displayName, universes: node.outputUniverses,
            verified: true, fresh: now - node.lastSeen <= registry.staleAfter)
    }

    /// Unicast ArtDmx for each universe; returns true when every packet was written.
    @discardableResult
    public func sendDMX(_ frames: [PortAddress: [UInt8]], to target: OutputTarget) -> Bool {
        var ok = true
        for (universe, data) in frames.sorted(by: { $0.key < $1.key }) where target.universes.contains(universe) {
            let seq = ArtNet.nextSequence(after: sequences[universe] ?? 0)
            sequences[universe] = seq
            do {
                let packet = try ArtNet.artDmx(sequence: seq, portAddress: universe, data: data)
                try transport.send(packet, to: target.ip, port: ArtNet.port)
            } catch {
                ok = false
                sendError = error.localizedDescription
            }
        }
        if ok { sendError = nil }
        return ok
    }

    // MARK: Diagnosis

    public func diagnosis(now: TimeInterval) -> [String] {
        NetworkDiagnosis.messages(
            interfaces: interfaces, nodes: nodes(now: now), manualIP: manualIP,
            socketError: socketError, pollCount: pollCount)
    }
}

/// Human-readable hints when no Art-Net node can be reached.
public enum NetworkDiagnosis {
    public static let odeFallbackIP = IPv4Address(192, 168, 0, 10)

    public static func messages(
        interfaces: [NetworkInterface], nodes: [DiscoveredNode], manualIP: IPv4Address?,
        socketError: String?, pollCount: Int
    ) -> [String] {
        var out: [String] = []
        if let socketError { out.append(socketError) }
        if interfaces.isEmpty {
            out.append(String(localized: "No active IPv4 network found. Connect the Mac and the Art-Net node to the same router or switch."))
            return out
        }
        let enttec = nodes.filter(\.isEnttec)
        if enttec.isEmpty, pollCount >= 2 {
            if interfaces.contains(where: { $0.address.isLinkLocal }) {
                out.append(
                    """
                    Una porta del Mac ha un indirizzo auto-assegnato 169.254.x.x: probabilmente è un cavo diretto senza DHCP. \
                    In questo caso l'ODE MK3 usa l'indirizzo di riserva 192.168.0.10/24, che è in un'altra rete: \
                    senza configurare un indirizzo a mano non possono parlarsi. Soluzione consigliata: collegare ODE MK3 \
                    e Mac allo stesso router con DHCP (la connessione Internet resta invariata).
                    """)
            }
            if interfaces.contains(where: { $0.contains(odeFallbackIP) }), manualIP == nil {
                out.append(
                    String(localized: "The Mac is on the 192.168.0.x network: if the ODE MK3 didn't get a DHCP address it may be at 192.168.0.10. You can try it as a manual IP (it stays “not verified” until it answers).")
                )
            }
            out.append(
                String(localized: "No ENTTEC node answered ArtPoll. Check power/PoE and the cable, and that the node and the Mac are on the same network (same router with DHCP).")
            )
        }
        if enttec.count > 1 {
            out.append(String(localized: "Found \(String(describing: enttec.count)) ENTTEC devices: choose the one to use in Setup."))
        }
        if let manualIP, !interfaces.contains(where: { $0.contains(manualIP) }) {
            out.append(
                String(localized: "The manual IP \(String(describing: manualIP)) is not on any of the Mac's local networks: packets would go through the default router and probably not arrive.")
            )
        }
        return out
    }
}
