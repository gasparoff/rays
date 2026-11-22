import Darwin
import Foundation

/// Datagram transport abstraction so the Art-Net logic can be tested without sockets.
public protocol DatagramTransport: AnyObject {
    /// Binds the receive/send socket. Received datagrams are delivered on `queue`.
    func open(port: UInt16, queue: DispatchQueue, onReceive: @escaping ([UInt8], IPv4Address) -> Void) throws
    func close()
    var isOpen: Bool { get }
    func send(_ bytes: [UInt8], to address: IPv4Address, port: UInt16) throws
}

/// A failed socket call with its errno, described for the user.
public struct SocketError: Error, LocalizedError, Equatable {
    public var operation: String
    public var code: Int32
    public var port: UInt16? = nil

    public var errorDescription: String? {
        let reason = String(cString: strerror(code))
        switch (operation, code) {
        case ("bind", EADDRINUSE):
            return String(localized: "UDP port \(String(describing: port.map(String.init) ?? "local")) is used by another app: quit it and try again (\(String(describing: reason))).")
        case ("send", EHOSTUNREACH), ("send", ENETUNREACH):
            return
                String(localized: "Network unreachable (\(String(describing: reason))). Check the Local Network permission in System Settings > Privacy & Security, and the connection.")
        case ("send", EACCES), ("send", EPERM):
            return String(localized: "Sending denied by the system (\(String(describing: reason))). Allow RAYS to access the local network.")
        default:
            return String(localized: "Socket error \(String(describing: operation)): \(String(describing: reason)) (\(String(describing: code)))")
        }
    }
}

/// BSD UDP socket bound to 0.0.0.0:port with broadcast enabled; replies arrive on the same socket.
public final class UDPSocket: DatagramTransport, @unchecked Sendable {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public init() {}
    deinit { close() }

    public var isOpen: Bool { fd >= 0 }

    public func open(port: UInt16, queue: DispatchQueue, onReceive: @escaping ([UInt8], IPv4Address) -> Void) throws {
        close()
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { throw SocketError(operation: "socket", code: errno) }
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        // Exclusive ownership: sharing this receive port with another console
        // could silently deliver discovery/beat packets to the wrong process.
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
        guard setsockopt(s, SOL_SOCKET, SO_BROADCAST, &one, size) == 0 else {
            let e = errno; Darwin.close(s); throw SocketError(operation: "setsockopt", code: e)
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let e = errno; Darwin.close(s); throw SocketError(operation: "bind", code: e, port: port) }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.drain(onReceive) }
        src.setCancelHandler { Darwin.close(s) }
        source = src
        src.resume()
    }

    private func drain(_ onReceive: ([UInt8], IPv4Address) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while fd >= 0 {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &len)
                    }
                }
            }
            guard n > 0 else { return }
            onReceive(Array(buffer[0..<n]), IPv4Address(UInt32(bigEndian: from.sin_addr.s_addr)))
        }
    }

    public func close() {
        guard fd >= 0 else { return }
        fd = -1
        if let source { source.cancel() }  // cancel handler closes the descriptor
        source = nil
    }

    public func send(_ bytes: [UInt8], to address: IPv4Address, port: UInt16) throws {
        guard fd >= 0 else { throw SocketError(operation: "send", code: EBADF) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = address.value.bigEndian
        let sent = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == bytes.count else { throw SocketError(operation: "send", code: errno) }
    }
}

// MARK: - Interfaces

/// An active IPv4 interface of this Mac.
public struct NetworkInterface: Equatable, Sendable, Identifiable {
    public var name: String
    public var address: IPv4Address
    public var netmask: IPv4Address
    public var broadcast: IPv4Address
    public var id: String { name + "/" + address.description }

    public func contains(_ ip: IPv4Address) -> Bool { address.isInSameSubnet(as: ip, mask: netmask) }

    /// Active, non-loopback IPv4 interfaces with a broadcast address.
    public static func current() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [NetworkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                let mask = ifa.pointee.ifa_netmask, let brd = ifa.pointee.ifa_dstaddr
            else { continue }
            func ipv4(_ p: UnsafeMutablePointer<sockaddr>) -> IPv4Address {
                p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4Address(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)) }
            }
            let iface = NetworkInterface(
                name: String(cString: ifa.pointee.ifa_name), address: ipv4(addr),
                netmask: ipv4(mask), broadcast: ipv4(brd))
            if !iface.address.isUnspecified, !iface.broadcast.isUnspecified { result.append(iface) }
        }
        return result
    }
}
