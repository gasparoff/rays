import Foundation

public enum SACNError: Error, Equatable, LocalizedError {
    case invalidUniverse(Int)
    public var errorDescription: String? {
        switch self { case .invalidUniverse(let u): return "Universo sACN \(u) fuori da 1…63999" }
    }
}

/// Streaming ACN (ANSI E1.31-2018) data packets: root layer, framing layer, DMP layer.
/// Only DMX data packets (start code 0) are built; synchronization and universe discovery
/// packets are not sent.
public enum SACN {
    public static let port: UInt16 = 5568
    /// E1.31 universes are 1...63999 (0 and 64000+ are reserved).
    public static let universes: ClosedRange<UInt16> = 1...63999
    public static let defaultPriority: UInt8 = 100
    public static let maxPriority: UInt8 = 200
    /// "ASC-E1.17" followed by three NULs.
    public static let packetIdentifier: [UInt8] = Array("ASC-E1.17".utf8) + [0, 0, 0]
    static let vectorRootData: UInt32 = 0x0000_0004
    static let vectorFramingData: UInt32 = 0x0000_0002
    static let vectorDMPSetProperty: UInt8 = 0x02

    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let preview = Options(rawValue: 0x80)
        public static let streamTerminated = Options(rawValue: 0x40)
        public static let forceSynchronization = Options(rawValue: 0x20)
    }

    /// 239.255.<hi>.<lo>, the multicast group of a universe.
    public static func multicastAddress(universe: UInt16) -> IPv4Address {
        IPv4Address(239, 255, UInt8(universe >> 8), UInt8(universe & 0xFF))
    }

    /// One DMX data packet. `data` holds up to 512 slots (shorter frames are sent as is,
    /// longer ones are truncated); `sourceName` is UTF-8, truncated to 63 bytes + NUL.
    public static func dataPacket(cid: UUID, sourceName: String, priority: UInt8, sequence: UInt8,
                                  options: Options = [], universe: UInt16, data: [UInt8]) throws -> [UInt8] {
        guard universes.contains(universe) else { throw SACNError.invalidUniverse(Int(universe)) }
        let slots = Array(data.prefix(512))
        let total = 126 + slots.count
        var p: [UInt8] = []
        p.reserveCapacity(total)
        // Root layer
        p += [0x00, 0x10, 0x00, 0x00]
        p += packetIdentifier
        p += flagsAndLength(total - 16)
        p += be32(vectorRootData)
        p += withUnsafeBytes(of: cid.uuid) { Array($0) }
        // Framing layer
        p += flagsAndLength(total - 38)
        p += be32(vectorFramingData)
        var name = Array(sourceName.utf8.prefix(63))
        name += [UInt8](repeating: 0, count: 64 - name.count)
        p += name
        p.append(min(priority, maxPriority))
        p += [0x00, 0x00]                 // synchronization address: none
        p.append(sequence)
        p.append(options.rawValue)
        p += be16(universe)
        // DMP layer
        p += flagsAndLength(total - 115)
        p.append(vectorDMPSetProperty)
        p.append(0xA1)                    // address type & data type
        p += [0x00, 0x00]                 // first property address
        p += [0x00, 0x01]                 // address increment
        p += be16(UInt16(slots.count + 1))
        p.append(0x00)                    // DMX512 start code
        p += slots
        return p
    }

    static func flagsAndLength(_ length: Int) -> [UInt8] { be16(0x7000 | UInt16(length & 0x0FFF)) }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}

/// sACN output: one packet per patch universe, multicast to 239.255.x.y or unicast to one
/// receiver. Patch universes are Art-Net Port-Addresses (0-based); sACN universe =
/// Port-Address + `universeOffset` (default 1, the common Art-Net 0 = sACN 1 convention).
/// sACN has no node discovery: the target is always the configured destination.
/// Not thread-safe: use from the engine's serial queue.
public final class SACNDriver: OutputDriver {
    public enum Mode: String, Codable, Sendable { case multicast, unicast }

    public struct Configuration: Codable, Equatable, Sendable {
        public var mode: Mode = .multicast
        public var unicastIP: IPv4Address?
        public var priority: UInt8 = SACN.defaultPriority
        public var sourceName = "RAYS"
        public var universeOffset = 1
        /// Component identifier; keep it stable per installation (persist it).
        public var cid = UUID()
        public init() {}
    }

    public static let driverID = "sacn"
    public var driverID: String { Self.driverID }
    public var reopenInterval: TimeInterval { 3 }

    public var configuration: Configuration
    private let transport: DatagramTransport
    private let interfaceProvider: () -> [NetworkInterface]
    private var sequences: [UInt16: UInt8] = [:]
    public private(set) var interfaces: [NetworkInterface] = []
    public private(set) var socketError: String?
    public private(set) var sendError: String?
    public var pollError: String? { nil }
    public var preferredIdentity: String?
    public var manualIP: IPv4Address? {
        get { configuration.mode == .unicast ? configuration.unicastIP : nil }
        set { configuration.unicastIP = newValue; configuration.mode = newValue == nil ? .multicast : .unicast }
    }
    public var onPreferredIdentityChanged: ((String?) -> Void)?
    private var lastInterfaceScan: TimeInterval = -.infinity

    public init(transport: DatagramTransport, interfaces: @escaping () -> [NetworkInterface] = NetworkInterface.current,
                configuration: Configuration = Configuration()) {
        self.transport = transport
        self.interfaceProvider = interfaces
        self.configuration = configuration
    }

    public var isOpen: Bool { transport.isOpen }

    public func open(queue: DispatchQueue, now: @escaping () -> TimeInterval) {
        do {
            try transport.open(port: 0, queue: queue) { _, _ in }   // send-only, ephemeral port
            socketError = nil
        } catch {
            socketError = error.localizedDescription
        }
    }

    public func close() {
        transport.close()
        sequences.removeAll()
    }

    public func pollIfDue(now: TimeInterval) {
        guard now - lastInterfaceScan >= 3 else { return }
        lastInterfaceScan = now
        interfaces = interfaceProvider()
    }

    public func forcePoll(now: TimeInterval) {
        lastInterfaceScan = -.infinity
        pollIfDue(now: now)
    }

    public func nodes(now: TimeInterval) -> [DiscoveredNode] { [] }
    public func select(identity: String?) { preferredIdentity = identity }

    public func sacnUniverse(_ portAddress: PortAddress) -> UInt16? {
        let u = Int(portAddress.rawValue) + configuration.universeOffset
        return (1...63999).contains(u) ? UInt16(u) : nil
    }

    public func target(now: TimeInterval, patchUniverses: [PortAddress]) -> OutputTarget? {
        let universes = patchUniverses.filter { sacnUniverse($0) != nil }
        switch configuration.mode {
        case .multicast:
            let first = universes.first.flatMap(sacnUniverse) ?? 1
            return OutputTarget(ip: SACN.multicastAddress(universe: first), name: "sACN multicast",
                                universes: universes, verified: false, fresh: false, endpoint: "multicast 239.255.x.x")
        case .unicast:
            guard let ip = configuration.unicastIP else { return nil }
            return OutputTarget(ip: ip, name: "sACN unicast", universes: universes, verified: false, fresh: false)
        }
    }

    @discardableResult
    public func sendDMX(_ frames: [PortAddress: [UInt8]], to target: OutputTarget) -> Bool {
        var ok = true
        for (portAddress, data) in frames.sorted(by: { $0.key < $1.key }) where target.universes.contains(portAddress) {
            guard let universe = sacnUniverse(portAddress) else { continue }
            let seq = sequences[universe, default: 255] &+ 1
            sequences[universe] = seq
            let destination = configuration.mode == .multicast ? SACN.multicastAddress(universe: universe) : target.ip
            do {
                let packet = try SACN.dataPacket(cid: configuration.cid, sourceName: configuration.sourceName,
                                                 priority: configuration.priority, sequence: seq,
                                                 universe: universe, data: data)
                try transport.send(packet, to: destination, port: SACN.port)
            } catch {
                ok = false
                sendError = error.localizedDescription
            }
        }
        if ok { sendError = nil }
        return ok
    }

    public func diagnosis(now: TimeInterval) -> [String] {
        var out: [String] = []
        if let socketError { out.append(socketError) }
        if interfaces.isEmpty { out.append("Nessuna rete IPv4 attiva trovata.") }
        if configuration.mode == .unicast, configuration.unicastIP == nil {
            out.append("sACN unicast: imposta l'indirizzo IP del ricevitore.")
        }
        out.append("sACN non ha una scoperta dei dispositivi: RAYS non può verificare che un ricevitore stia ascoltando.")
        return out
    }
}
