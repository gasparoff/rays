import XCTest
import Darwin
@testable import RaysOutput
@testable import RaysTempo
@testable import RaysCore
@testable import RaysEngine

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

/// A widget that stops reading: the first write waits until `release` is signalled.
final class BlockingSerialPort: SerialPort, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[UInt8]] = []
    private var held = false
    private(set) var isOpen = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    var written: [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }
    func open(path: String) throws { isOpen = true }
    func write(_ bytes: [UInt8]) throws {
        lock.lock()
        let first = !held
        held = true
        lock.unlock()
        if first {
            entered.signal()
            release.wait()
        }
        lock.lock(); frames.append(bytes); lock.unlock()
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
        // Returning ETIMEDOUT (instead of hanging in write(2)) is what bounds the writer queue.
        XCTAssertThrowsError(try port.write(DMXUSBPro.sendDMX([UInt8](repeating: 255, count: 512)))) { error in
            XCTAssertEqual((error as? SocketError)?.code, ETIMEDOUT)
        }
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
        d.waitForPendingWrites()
        XCTAssertEqual(port.written.count, 1)
        XCTAssertEqual(port.written[0][5], 10)
        port.failWrite = true
        XCTAssertTrue(d.sendDMX([u0: [1]], to: target), "queued: the error is only known once the writer tried")
        d.waitForPendingWrites()
        XCTAssertFalse(port.isOpen, "the writer closes the port on a write error")
        XCTAssertFalse(d.sendDMX([u0: [2]], to: target), "the next frame reports the error")
        XCTAssertFalse(d.isOpen)
        XCTAssertNotNil(d.sendError)
        XCTAssertNil(d.target(now: 0, patchUniverses: [u0]))

        port.failWrite = false
        d.open(queue: DispatchQueue(label: "t"), now: { 0 })
        XCTAssertTrue(d.isOpen, "replugged: the engine's next open works again")
        XCTAssertTrue(d.sendDMX([u0: [3]], to: try XCTUnwrap(d.target(now: 0, patchUniverses: [u0]))))
        d.waitForPendingWrites()
        XCTAssertEqual(port.written.last?[5], 3)
        XCTAssertNil(d.sendError)
    }

    /// The engine queue never waits for the serial port: frames queue on the driver's writer, and
    /// a frame the widget has not taken yet is replaced by the newest one.
    func testSendNeverWaitsForTheWidgetAndKeepsOnlyTheNewestFrame() throws {
        let port = BlockingSerialPort()
        let d = DMXUSBProDriver(port: port, devices: { ["/dev/cu.usbserial-A"] })
        d.open(queue: DispatchQueue(label: "t"), now: { 0 })
        let u0 = try XCTUnwrap(PortAddress(0))
        let target = try XCTUnwrap(d.target(now: 0, patchUniverses: [u0]))
        XCTAssertTrue(d.sendDMX([u0: [1]], to: target))
        XCTAssertEqual(port.entered.wait(timeout: .now() + 10), .success, "the writer is now stuck inside frame 1")
        // The port is still blocked: these calls can only return because they don't touch it.
        XCTAssertTrue(d.sendDMX([u0: [2]], to: target))
        XCTAssertTrue(d.sendDMX([u0: [3]], to: target))
        XCTAssertEqual(port.written, [], "nothing has reached the widget yet")
        port.release.signal()
        d.waitForPendingWrites()
        XCTAssertEqual(port.written.map { $0[5] }, [1, 3], "frame 2 was replaced by the newer frame 3")
    }

    /// Blackout always wins: the black frames sent on disarm are written before the port closes,
    /// even when the widget is still busy with the previous frame.
    func testCloseWritesTheLastQueuedBlackFrameBeforeClosingThePort() throws {
        let port = BlockingSerialPort()
        let d = DMXUSBProDriver(port: port, devices: { ["/dev/cu.usbserial-A"] })
        d.open(queue: DispatchQueue(label: "t"), now: { 0 })
        let u0 = try XCTUnwrap(PortAddress(0))
        let target = try XCTUnwrap(d.target(now: 0, patchUniverses: [u0]))
        d.sendDMX([u0: [UInt8](repeating: 255, count: 512)], to: target)
        XCTAssertEqual(port.entered.wait(timeout: .now() + 10), .success)
        let black = [UInt8](repeating: 0, count: 512)
        for _ in 0..<3 { d.sendDMX([u0: black], to: target) }
        port.release.signal()
        d.close()
        XCTAssertFalse(port.isOpen)
        XCTAssertFalse(d.isOpen)
        XCTAssertEqual(port.written.count, 2)
        XCTAssertEqual(port.written.last, DMXUSBPro.sendDMX(black))
        XCTAssertFalse(d.sendDMX([u0: [9]], to: target), "nothing is sent after close")
        d.waitForPendingWrites()
        XCTAssertEqual(port.written.count, 2)
    }

    /// End to end through the engine: disarm and shutdown leave the widget on a black frame.
    func testEngineEndsOnABlackFrameOverDMXUSBPro() throws {
        let port = FakeSerialPort()
        var registry = OutputDriverRegistry()
        registry.register(
            .init(id: DMXUSBProDriver.driverID, name: "DMX USB Pro") { _, _ in
                DMXUSBProDriver(port: port, devices: { ["/dev/cu.usbserial-T"] })
            })
        let clock = ManualClock()
        let engine = LightEngine(
            tempo: LocalTempoClock(bpm: 120, now: { clock.now }), transport: FakeTransport(), interfaces: { [] },
            clock: { clock.now }, runsTimer: false, outputDrivers: registry, outputDriverID: DMXUSBProDriver.driverID)
        var patch = Patch(fixtures: [.init(label: "Test", profileID: "generic.rgb3", universe: 0, address: 1)])
        patch.setConfirmed(true, library: ProfileLibrary())
        engine.start(); engine.setPatch(patch); engine.setMaster(1)
        engine.setArmed(true)
        var snapshot = EngineSnapshot()
        engine.onSnapshot = { snapshot = $0 }
        engine.stepForTesting()
        XCTAssertTrue(snapshot.armed)
        engine.setArmed(false)
        engine.shutdown()
        XCTAssertEqual(port.openedPaths, ["/dev/cu.usbserial-T"])
        XCTAssertFalse(port.isOpen)
        let last = try XCTUnwrap(port.written.last)
        XCTAssertTrue(last[5..<(last.count - 1)].allSatisfy { $0 == 0 }, "the last frame on the wire is black")
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
