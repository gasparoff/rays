import XCTest
import Darwin
@testable import RaysOutput

final class FakeSerialPort: SerialPort {
    var isOpen = false
    var openedPaths: [String] = []
    var written: [[UInt8]] = []
    var failOpen = false, failWrite = false
    func open(path: String) throws {
        if failOpen { throw SocketError(operation: "open", code: ENOENT) }
        openedPaths.append(path); isOpen = true
    }
    func write(_ bytes: [UInt8]) throws {
        if failWrite { throw SocketError(operation: "write", code: ENXIO) }
        written.append(bytes)
    }
    func close() { isOpen = false }
}

/// Framing per the ENTTEC DMX USB Pro API (message 0x7E label len data 0xE7, label 6).
final class DMXUSBProTests: XCTestCase {
    func testFullFrameFraming() {
        let slots = (0..<512).map { UInt8($0 & 0xFF) }
        let m = DMXUSBPro.sendDMX(slots)
        XCTAssertEqual(m.count, 4 + 513 + 1)
        XCTAssertEqual(Array(m[0..<4]), [0x7E, 0x06, 0x01, 0x02], "label 6, length 513 little-endian")
        XCTAssertEqual(m[4], 0x00, "DMX start code")
        XCTAssertEqual(Array(m[5..<517]), slots)
        XCTAssertEqual(m.last, 0xE7)
    }

    func testStalledDeviceFailsFastInsteadOfBlockingTheEngine() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { Darwin.close(fds[0]) }
        let port = POSIXSerialPort(adopting: fds[1], writeTimeout: 0.05)
        defer { port.close() }
        // Nobody reads the pipe: fill its buffer so the next frame cannot be written.
        let chunk = [UInt8](repeating: 0, count: 4096)
        while chunk.withUnsafeBytes({ Darwin.write(fds[1], $0.baseAddress, $0.count) }) > 0 {}
        let start = Date()
        XCTAssertThrowsError(try port.write(DMXUSBPro.sendDMX([UInt8](repeating: 255, count: 512)))) { error in
            XCTAssertEqual((error as? SocketError)?.code, ETIMEDOUT)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "a stalled widget must not hold the engine queue")
    }

    func testHealthyDeviceReceivesTheWholeFrame() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { Darwin.close(fds[0]) }
        let port = POSIXSerialPort(adopting: fds[1])
        defer { port.close() }
        let frame = DMXUSBPro.sendDMX([1, 2, 3])
        try port.write(frame)
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fds[0], $0.baseAddress, $0.count) }
        XCTAssertEqual(Array(buffer[0..<n]), frame)
    }

    func testShortFramesArePaddedTo24SlotsAndLongOnesTruncated() {
        let m = DMXUSBPro.sendDMX([255, 128])
        XCTAssertEqual(Array(m[0..<4]), [0x7E, 0x06, 25, 0])
        XCTAssertEqual(Array(m[5..<7]), [255, 128])
        XCTAssertTrue(m[7..<29].allSatisfy { $0 == 0 })
        XCTAssertEqual(m.count, 4 + 25 + 1)
        XCTAssertEqual(DMXUSBPro.sendDMX([UInt8](repeating: 1, count: 600)).count, 4 + 513 + 1)
    }

    func testDriverOpensFirstDeviceSendsLowestPatchUniverseAndReopensAfterUnplug() throws {
        let port = FakeSerialPort()
        let d = DMXUSBProDriver(port: port, devices: { ["/dev/cu.usbserial-A", "/dev/cu.usbserial-B"] })
        let u0 = try XCTUnwrap(PortAddress(0)), u3 = try XCTUnwrap(PortAddress(3))
        XCTAssertNil(d.target(now: 0, patchUniverses: [u0]), "closed")
        d.open(queue: DispatchQueue(label: "t"), now: { 0 })
        XCTAssertEqual(port.openedPaths, ["/dev/cu.usbserial-A"])
        let target = try XCTUnwrap(d.target(now: 0, patchUniverses: [u3, u0]))
        XCTAssertEqual(target.universes, [u0])
        XCTAssertEqual(target.displayAddress, "/dev/cu.usbserial-A")
        XCTAssertTrue(d.sendDMX([u0: [10, 20], u3: [99]], to: target))
        XCTAssertEqual(port.written.count, 1)
        XCTAssertEqual(port.written[0][5], 10)
        port.failWrite = true
        XCTAssertFalse(d.sendDMX([u0: [1]], to: target))
        XCTAssertFalse(d.isOpen)
        XCTAssertNotNil(d.sendError)
    }

    func testConfiguredDeviceAndUniverseAndMissingDevice() throws {
        var config = DMXUSBProDriver.Configuration()
        config.devicePath = "/dev/cu.usbserial-B"
        config.universe = 3
        let port = FakeSerialPort()
        let d = DMXUSBProDriver(port: port, devices: { [] }, configuration: config)
        d.open(queue: DispatchQueue(label: "t"), now: { 0 })
        XCTAssertEqual(port.openedPaths, ["/dev/cu.usbserial-B"])
        XCTAssertEqual(d.target(now: 0, patchUniverses: [try XCTUnwrap(PortAddress(0))])?.universes, [try XCTUnwrap(PortAddress(3))])

        let empty = DMXUSBProDriver(port: FakeSerialPort(), devices: { [] })
        empty.open(queue: DispatchQueue(label: "t"), now: { 0 })
        XCTAssertFalse(empty.isOpen)
        XCTAssertNotNil(empty.socketError)
    }

    func testCandidateDevicesListsOnlyUSBSerialCallouts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["cu.usbserial-EN123", "tty.usbserial-EN123", "cu.Bluetooth-Incoming-Port", "cu.usbserial-A1"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        }
        XCTAssertEqual(DMXUSBPro.candidateDevices(in: dir.path), ["\(dir.path)/cu.usbserial-A1", "\(dir.path)/cu.usbserial-EN123"])
    }

    /// Real termios path against a pseudo-terminal: what the driver writes arrives byte-exact.
    func testPOSIXSerialPortWritesRawBytesThroughAPseudoTerminal() throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw XCTSkip("openpty unavailable") }
        defer { Darwin.close(master); Darwin.close(slave) }
        let port = POSIXSerialPort()
        try port.open(path: String(cString: name))
        defer { port.close() }
        let frame = DMXUSBPro.sendDMX([0x0A, 0x0D, 0x7E, 0xE7, 0x11, 0x13])  // CR/LF/XON/XOFF must pass untouched
        try port.write(frame)
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(2)
        while received.count < frame.count, Date() < deadline {
            let n = read(master, &buffer, buffer.count)
            if n > 0 { received += buffer[0..<n] }
        }
        XCTAssertEqual(received, frame)
        XCTAssertThrowsError(try POSIXSerialPort().open(path: "/dev/cu.usbserial-does-not-exist"))
    }
}
