import Darwin
import Foundation

/// ENTTEC DMX USB Pro widget protocol (also spoken by compatible interfaces such as DMXking
/// ultraDMX Pro / Micro). Messages are `0x7E label lenLSB lenMSB data… 0xE7`; label 6
/// "Output Only Send DMX Packet Request" carries the start code and 24…512 slots.
public enum DMXUSBPro {
    public static let startOfMessage: UInt8 = 0x7E
    public static let endOfMessage: UInt8 = 0xE7
    public static let sendDMXLabel: UInt8 = 6
    /// The widget accepts 25…513 data bytes (start code + 24…512 slots).
    public static let minimumSlots = 24

    public static func message(label: UInt8, data: [UInt8]) -> [UInt8] {
        let n = min(data.count, 600)
        return [startOfMessage, label, UInt8(n & 0xFF), UInt8(n >> 8)] + data.prefix(n) + [endOfMessage]
    }

    /// Label 6 with start code 0; frames shorter than 24 slots are zero-padded, longer than 512 truncated.
    public static func sendDMX(_ slots: [UInt8]) -> [UInt8] {
        var s = Array(slots.prefix(512))
        if s.count < minimumSlots { s += [UInt8](repeating: 0, count: minimumSlots - s.count) }
        return message(label: sendDMXLabel, data: [0x00] + s)
    }

    /// Serial devices that may be a DMX USB Pro (FTDI-based widgets appear as /dev/cu.usbserial-*).
    public static func candidateDevices(in directory: String = "/dev") -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("cu.usbserial-") }.sorted().map { "\(directory)/\($0)" }
    }
}

/// Byte stream to a serial device, abstracted so the driver can be tested without hardware.
public protocol SerialPort: AnyObject {
    var isOpen: Bool { get }
    func open(path: String) throws
    func write(_ bytes: [UInt8]) throws
    func close()
}

/// POSIX termios serial port: raw 8N1, no flow control. USB widgets ignore the baud rate.
///
/// Writes run on the engine's queue, so they never block for long: the descriptor stays
/// non-blocking and a frame that can't be written within `writeTimeout` fails with
/// `ETIMEDOUT`. The driver then closes the port and the engine reopens it later, so a stalled
/// widget can't delay blackout, other commands or shutdown.
public final class POSIXSerialPort: SerialPort, @unchecked Sendable {
    private var fd: Int32 = -1
    /// Longest time one frame may wait for the device. A full frame is 518 bytes, well under a
    /// millisecond on a healthy USB link; the engine ticks every 33 ms.
    public let writeTimeout: TimeInterval
    public init(writeTimeout: TimeInterval = 0.02) { self.writeTimeout = writeTimeout }
    /// Adopts an already open descriptor (tests use a pipe). It is switched to non-blocking.
    init(adopting descriptor: Int32, writeTimeout: TimeInterval = 0.02) {
        self.writeTimeout = writeTimeout
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        fd = descriptor
    }
    deinit { close() }

    public var isOpen: Bool { fd >= 0 }

    public func open(path: String) throws {
        close()
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { throw SocketError(operation: "open \(path)", code: errno) }
        var t = termios()
        guard tcgetattr(f, &t) == 0 else { let e = errno; Darwin.close(f); throw SocketError(operation: "tcgetattr", code: e) }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSTOPB | CRTSCTS | PARENB)
        cfsetspeed(&t, speed_t(B57600))
        guard tcsetattr(f, TCSANOW, &t) == 0 else { let e = errno; Darwin.close(f); throw SocketError(operation: "tcsetattr", code: e) }
        fd = f  // stays O_NONBLOCK: `write` bounds every wait with poll(2)
    }

    public func write(_ bytes: [UInt8]) throws {
        guard fd >= 0 else { throw SocketError(operation: "write", code: EBADF) }
        let deadline = Date().addingTimeInterval(writeTimeout)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n >= 0 {
                offset += n
                continue
            }
            let e = errno
            if e == EINTR { continue }
            guard e == EAGAIN || e == EWOULDBLOCK else { throw SocketError(operation: "write", code: e) }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketError(operation: "write", code: ETIMEDOUT) }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&p, 1, Int32(max(1, (remaining * 1000).rounded(.up))))
            if ready < 0, errno != EINTR { throw SocketError(operation: "write", code: errno) }
            if ready == 0 { throw SocketError(operation: "write", code: ETIMEDOUT) }
        }
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

/// Output through an ENTTEC DMX USB Pro (or compatible) on one serial device: one DMX
/// universe, the configured patch universe (default: the lowest one in the patch).
/// Not thread-safe: use from the engine's serial queue.
public final class DMXUSBProDriver: OutputDriver {
    /// Device and universe for the DMX USB Pro driver.
    public struct Configuration: Codable, Equatable, Sendable {
        /// nil = first /dev/cu.usbserial-* device found.
        public var devicePath: String?
        /// Patch universe (Art-Net Port-Address) sent to the widget; nil = lowest in the patch.
        public var universe: Int?
        public init() {}

        enum CodingKeys: String, CodingKey { case devicePath, universe }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            devicePath = (try? c.decodeIfPresent(String.self, forKey: .devicePath)) ?? nil
            universe = (try? c.decodeIfPresent(Int.self, forKey: .universe)) ?? nil
        }
    }

    public static let driverID = "dmxusbpro"
    public var driverID: String { Self.driverID }
    public var reopenInterval: TimeInterval { 2 }

    public var configuration: Configuration
    private let port: SerialPort
    private let devices: () -> [String]
    public private(set) var openPath: String?
    public private(set) var socketError: String?
    public private(set) var sendError: String?
    public var pollError: String? { nil }
    public var interfaces: [NetworkInterface] { [] }
    public var manualIP: IPv4Address?
    public var onPreferredIdentityChanged: ((String?) -> Void)?
    public private(set) var availableDevices: [String] = []
    private var lastScan: TimeInterval = -.infinity

    public init(
        port: SerialPort = POSIXSerialPort(), devices: @escaping () -> [String] = { DMXUSBPro.candidateDevices() },
        configuration: Configuration = Configuration()
    ) {
        self.port = port
        self.devices = devices
        self.configuration = configuration
    }

    public var preferredIdentity: String? {
        get { configuration.devicePath }
        set { configuration.devicePath = newValue }
    }

    public var isOpen: Bool { port.isOpen }

    public func open(queue: DispatchQueue, now: @escaping () -> TimeInterval) {
        availableDevices = devices()
        guard let path = configuration.devicePath ?? availableDevices.first else {
            socketError = "Nessuna interfaccia DMX USB trovata (/dev/cu.usbserial-*). Collegala e riprova."
            return
        }
        do {
            try port.open(path: path)
            openPath = path
            socketError = nil
        } catch {
            openPath = nil
            socketError = error.localizedDescription
        }
    }

    public func close() {
        port.close()
        openPath = nil
    }

    public func pollIfDue(now: TimeInterval) {
        guard now - lastScan >= 2 else { return }
        lastScan = now
        availableDevices = devices()
    }

    public func forcePoll(now: TimeInterval) {
        lastScan = -.infinity
        pollIfDue(now: now)
    }

    public func nodes(now: TimeInterval) -> [DiscoveredNode] { [] }

    public func select(identity: String?) {
        guard identity != configuration.devicePath else { return }
        configuration.devicePath = identity
        close()
    }

    public func target(now: TimeInterval, patchUniverses: [PortAddress]) -> OutputTarget? {
        guard let path = openPath else { return nil }
        let chosen = configuration.universe.flatMap(PortAddress.init) ?? patchUniverses.min()
        guard let chosen else { return nil }
        return OutputTarget(
            ip: IPv4Address(0, 0, 0, 0), name: "DMX USB Pro", universes: [chosen],
            verified: false, fresh: false, endpoint: path)
    }

    @discardableResult
    public func sendDMX(_ frames: [PortAddress: [UInt8]], to target: OutputTarget) -> Bool {
        guard let universe = target.universes.first, let data = frames[universe] else { return true }
        do {
            try port.write(DMXUSBPro.sendDMX(data))
            sendError = nil
            return true
        } catch {
            sendError = error.localizedDescription
            close()  // unplugged: the engine reopens it on its retry interval
            return false
        }
    }

    public func diagnosis(now: TimeInterval) -> [String] {
        var out: [String] = []
        if let socketError { out.append(socketError) }
        if availableDevices.isEmpty {
            out.append(
                "Nessun dispositivo /dev/cu.usbserial-* trovato. Le interfacce FTDI (ENTTEC DMX USB Pro, DMXking ultraDMX) usano il driver seriale di macOS."
            )
        }
        out.append("DMX USB Pro: un solo universo. L'interfaccia non conferma la ricezione, quindi RAYS non può verificarla.")
        return out
    }
}
