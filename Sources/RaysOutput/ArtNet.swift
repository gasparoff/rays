import Foundation

// MARK: - IPv4

/// An IPv4 address, stored as four octets.
public struct IPv4Address: Hashable, Codable, Comparable, CustomStringConvertible, Sendable {
    /// Host-order value: a.b.c.d == a << 24 | b << 16 | c << 8 | d.
    public var value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    public init?(string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let octet = UInt8(part) else { return nil }
            result = result << 8 | UInt32(octet)
        }
        value = result
    }

    public var octets: [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    public var description: String { octets.map(String.init).joined(separator: ".") }
    public var isLinkLocal: Bool { value >> 16 == 0xA9FE }
    public var isLoopback: Bool { value >> 24 == 127 }
    public var isUnspecified: Bool { value == 0 }

    public func isInSameSubnet(as other: IPv4Address, mask: IPv4Address) -> Bool {
        value & mask.value == other.value & mask.value
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool { lhs.value < rhs.value }
}

// MARK: - Port-Address

/// Art-Net 15-bit Port-Address (Net 7 bit, Sub-Net 4 bit, Universe 4 bit). Zero-based:
/// ODE MK3 default port 1 = universe 0, port 2 = universe 1.
public struct PortAddress: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init?(_ value: Int) {
        guard (0...0x7FFF).contains(value) else { return nil }
        rawValue = UInt16(value)
    }

    public init(net: UInt8, subNet: UInt8, universe: UInt8) {
        rawValue = UInt16(net & 0x7F) << 8 | UInt16(subNet & 0x0F) << 4 | UInt16(universe & 0x0F)
    }

    public var net: UInt8 { UInt8(rawValue >> 8 & 0x7F) }
    public var subUni: UInt8 { UInt8(rawValue & 0xFF) }
    public var description: String { String(rawValue) }
    public static func < (lhs: PortAddress, rhs: PortAddress) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Packets

/// Errors building or parsing Art-Net packets.
public enum ArtNetError: Error, Equatable, LocalizedError {
    case tooShort(Int)
    case badHeader
    case unexpectedOpCode(UInt16)
    case dataTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .tooShort(let n): return "Pacchetto Art-Net troppo corto (\(n) byte)"
        case .badHeader: return "Intestazione Art-Net non valida"
        case .unexpectedOpCode(let op): return String(format: "OpCode Art-Net inatteso 0x%04X", op)
        case .dataTooLong(let n): return "Dati DMX troppo lunghi (\(n) > 512)"
        }
    }
}

/// Art-Net 4 packet builders and constants (ArtPoll, ArtDmx).
public enum ArtNet {
    public static let port: UInt16 = 6454
    public static let header: [UInt8] = Array("Art-Net".utf8) + [0]
    public static let protocolVersion: UInt16 = 14
    public static let dmxSlots = 512
    public static let dmxPacketLength = 18 + 512

    /// Art-Net operation codes used by RAYS.
    public enum OpCode: UInt16 {
        case poll = 0x2000
        case pollReply = 0x2100
        case dmx = 0x5000
    }

    /// Returns the little-endian OpCode after validating the 8-byte "Art-Net\0" header.
    public static func opCode(of bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= 10, Array(bytes[0..<8]) == header else { return nil }
        return UInt16(bytes[8]) | UInt16(bytes[9]) << 8
    }

    /// ArtPoll (14 byte): ID, OpCode LE, ProtVer hi/lo, Flags, DiagPriority.
    public static func artPoll(flags: UInt8 = 0, diagPriority: UInt8 = 0) -> [UInt8] {
        var p = header
        p += [UInt8(OpCode.poll.rawValue & 0xFF), UInt8(OpCode.poll.rawValue >> 8)]
        p += [UInt8(protocolVersion >> 8), UInt8(protocolVersion & 0xFF)]
        p += [flags, diagPriority]
        return p
    }

    /// ArtDmx with all 512 slots. Shorter data is zero-padded; longer data is rejected.
    public static func artDmx(sequence: UInt8, physical: UInt8 = 0, portAddress: PortAddress, data: [UInt8]) throws -> [UInt8] {
        guard data.count <= dmxSlots else { throw ArtNetError.dataTooLong(data.count) }
        var p = [UInt8]()
        p.reserveCapacity(dmxPacketLength)
        p += header
        p += [UInt8(OpCode.dmx.rawValue & 0xFF), UInt8(OpCode.dmx.rawValue >> 8)]
        p += [UInt8(protocolVersion >> 8), UInt8(protocolVersion & 0xFF)]
        p += [sequence, physical, portAddress.subUni, portAddress.net]
        p += [UInt8(dmxSlots >> 8), UInt8(dmxSlots & 0xFF)]
        p += data
        if data.count < dmxSlots { p += [UInt8](repeating: 0, count: dmxSlots - data.count) }
        return p
    }

    /// Sequence counter 1...255 (0 means "disabled" in Art-Net, so it is skipped).
    public static func nextSequence(after current: UInt8) -> UInt8 {
        current >= 255 ? 1 : current + 1
    }
}

// MARK: - ArtPollReply

/// A parsed ArtPollReply: node identity, names and output ports.
public struct ArtPollReply: Equatable, Sendable {
    /// One output port of a node.
    public struct Port: Equatable, Sendable {
        public var index: Int
        public var typeByte: UInt8
        public var portAddress: PortAddress
        public var goodOutput: UInt8
        public var isOutput: Bool { typeByte & 0x80 != 0 }
        public var isDMX512: Bool { typeByte & 0x3F == 0 }
    }

    public static let minimumLength = 207

    public var ip: IPv4Address
    public var udpPort: UInt16
    public var firmwareVersion: UInt16
    public var netSwitch: UInt8
    public var subSwitch: UInt8
    public var oem: UInt16
    public var status1: UInt8
    public var estaManufacturer: UInt16
    public var shortName: String
    public var longName: String
    public var nodeReport: String
    public var numPorts: Int
    public var ports: [Port]
    public var mac: [UInt8]?
    public var bindIP: IPv4Address?
    public var bindIndex: UInt8

    /// DMX512 output ports (the universes the node subscribes to / outputs).
    public var outputPorts: [Port] { ports.filter { $0.isOutput && $0.isDMX512 && $0.goodOutput & 1 == 0 } }

    public var macString: String? {
        guard let mac, mac.count == 6, mac.contains(where: { $0 != 0 }) else { return nil }
        return mac.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func parse(_ b: [UInt8]) throws -> ArtPollReply {
        guard b.count >= 10 else { throw ArtNetError.tooShort(b.count) }
        guard let op = ArtNet.opCode(of: b) else { throw ArtNetError.badHeader }
        guard op == ArtNet.OpCode.pollReply.rawValue else { throw ArtNetError.unexpectedOpCode(op) }
        guard b.count >= minimumLength else { throw ArtNetError.tooShort(b.count) }

        let net = b[18], sub = b[19]
        var ports: [Port] = []
        for i in 0..<4 {
            let type = b[174 + i]
            guard type & 0x80 != 0 || type & 0x40 != 0 else { continue }
            ports.append(
                Port(
                    index: i, typeByte: type,
                    portAddress: PortAddress(net: net, subNet: sub, universe: b[190 + i]),
                    goodOutput: b[182 + i]))
        }
        let mac: [UInt8]? = b.count >= 207 ? Array(b[201..<207]) : nil
        let bindIP: IPv4Address? = b.count >= 211 ? IPv4Address(b[207], b[208], b[209], b[210]) : nil
        let bindIndex: UInt8 = b.count >= 212 ? b[211] : 0

        return ArtPollReply(
            ip: IPv4Address(b[10], b[11], b[12], b[13]),
            udpPort: UInt16(b[14]) | UInt16(b[15]) << 8,
            firmwareVersion: UInt16(b[16]) << 8 | UInt16(b[17]),
            netSwitch: net, subSwitch: sub,
            oem: UInt16(b[20]) << 8 | UInt16(b[21]),
            status1: b[23],
            estaManufacturer: UInt16(b[24]) | UInt16(b[25]) << 8,
            shortName: cString(b[26..<44]),
            longName: cString(b[44..<108]),
            nodeReport: cString(b[108..<172]),
            numPorts: Int(UInt16(b[172]) << 8 | UInt16(b[173])),
            ports: ports, mac: mac, bindIP: bindIP, bindIndex: bindIndex)
    }

    static func cString(_ slice: ArraySlice<UInt8>) -> String {
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }
}
