import Foundation
@testable import LightCore

final class FakeTransport: DatagramTransport {
    struct Sent: Equatable { var bytes: [UInt8]; var to: IPv4Address; var port: UInt16 }
    var sent: [Sent] = []
    var isOpen = false
    var failBind = false
    var receive: (([UInt8], IPv4Address) -> Void)?

    func open(port: UInt16, queue: DispatchQueue, onReceive: @escaping ([UInt8], IPv4Address) -> Void) throws {
        if failBind { throw SocketError(operation: "bind", code: EADDRINUSE, port: port) }
        isOpen = true
        receive = onReceive
    }

    func close() { isOpen = false }

    func send(_ bytes: [UInt8], to address: IPv4Address, port: UInt16) throws {
        sent.append(Sent(bytes: bytes, to: address, port: port))
    }

    var dmxPackets: [Sent] { sent.filter { ArtNet.opCode(of: $0.bytes) == ArtNet.OpCode.dmx.rawValue } }
    var pollPackets: [Sent] { sent.filter { ArtNet.opCode(of: $0.bytes) == ArtNet.OpCode.poll.rawValue } }
}

final class ManualClock {
    var now: TimeInterval = 1000
}

enum Fixture {
    static let lan = NetworkInterface(name: "en0", address: IPv4Address(192, 168, 1, 20),
                                      netmask: IPv4Address(255, 255, 255, 0), broadcast: IPv4Address(192, 168, 1, 255))

    /// Builds a full-length (239 byte) ArtPollReply like an ODE MK3 would send.
    static func pollReply(ip: IPv4Address = IPv4Address(192, 168, 1, 50), shortName: String = "ODE Mk3",
                          longName: String = "ENTTEC ODE Mk3", esta: UInt16 = 0x454E,
                          mac: [UInt8] = [0x00, 0x50, 0xC2, 0x11, 0x22, 0x33],
                          net: UInt8 = 0, sub: UInt8 = 0, swOut: [UInt8] = [0, 1],
                          portTypes: [UInt8] = [0x80, 0x80], bindIndex: UInt8 = 1, length: Int = 239) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: max(length, 239))
        b.replaceSubrange(0..<8, with: ArtNet.header)
        b[8] = 0x00; b[9] = 0x21
        b.replaceSubrange(10..<14, with: ip.octets)
        b[14] = 0x36; b[15] = 0x19
        b[16] = 0x01; b[17] = 0x02
        b[18] = net; b[19] = sub
        b[20] = 0x12; b[21] = 0x34
        b[24] = UInt8(esta & 0xFF); b[25] = UInt8(esta >> 8)
        for (i, c) in shortName.utf8.prefix(18).enumerated() { b[26 + i] = c }
        for (i, c) in longName.utf8.prefix(63).enumerated() { b[44 + i] = c }
        for (i, c) in "#0001 [0000] OK".utf8.enumerated() { b[108 + i] = c }
        b[172] = 0; b[173] = UInt8(portTypes.count)
        for (i, t) in portTypes.enumerated() { b[174 + i] = t }
        for (i, u) in swOut.enumerated() { b[190 + i] = u }
        b.replaceSubrange(201..<207, with: mac)
        b.replaceSubrange(207..<211, with: ip.octets)
        b[211] = bindIndex
        return Array(b.prefix(length))
    }
}
