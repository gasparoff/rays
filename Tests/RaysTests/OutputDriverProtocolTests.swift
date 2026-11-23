import XCTest
@testable import RaysOutput
@testable import RaysTempo
@testable import RaysCore
@testable import RaysEngine

/// The smallest driver the protocol allows: only the core members, everything about discovery
/// and node selection comes from the defaults in `OutputDriver`'s extension.
final class CoreOnlyDriver: OutputDriver {
    static let id = "core-only"
    var driverID: String { Self.id }
    private(set) var isOpen = false
    private(set) var frames: [[PortAddress: [UInt8]]] = []
    var socketError: String? { nil }
    var sendError: String? { nil }

    func open(queue: DispatchQueue, now: @escaping () -> TimeInterval) { isOpen = true }
    func close() { isOpen = false }

    func target(now: TimeInterval, patchUniverses: [PortAddress]) -> OutputTarget? {
        guard isOpen else { return nil }
        return OutputTarget(
            ip: IPv4Address(0, 0, 0, 0), name: "Core only", universes: patchUniverses, verified: false, fresh: false)
    }

    @discardableResult
    func sendDMX(_ frames: [PortAddress: [UInt8]], to target: OutputTarget) -> Bool {
        self.frames.append(frames)
        return true
    }

    func diagnosis(now: TimeInterval) -> [String] { [] }
}

final class OutputDriverProtocolTests: XCTestCase {
    func testACoreOnlyDriverGetsInertDefaults() {
        let d: OutputDriver = CoreOnlyDriver()
        XCTAssertEqual(d.reopenInterval, 2)
        d.pollIfDue(now: 0)
        d.forcePoll(now: 0)
        d.select(identity: "node")
        XCTAssertEqual(d.nodes(now: 0), [])
        XCTAssertEqual(d.interfaces, [])
        XCTAssertNil(d.pollError)
        d.preferredIdentity = "node"
        d.manualIP = IPv4Address(10, 0, 0, 1)
        d.onPreferredIdentityChanged = { _ in XCTFail("a driver without discovery never auto-selects") }
        XCTAssertNil(d.preferredIdentity, "no node to remember: the write is ignored")
        XCTAssertNil(d.manualIP)
        XCTAssertNil(d.onPreferredIdentityChanged)
    }

    /// Defaults are protocol requirements, so a driver's own members still win when the engine
    /// calls it through `OutputDriver`.
    func testDriversOwnMembersWinOverTheDefaultsThroughTheProtocol() {
        let usb: OutputDriver = DMXUSBProDriver(port: FakeSerialPort(), devices: { [] })
        usb.preferredIdentity = "/dev/cu.usbserial-X"
        XCTAssertEqual(usb.preferredIdentity, "/dev/cu.usbserial-X")
        XCTAssertEqual(usb.reopenInterval, 2)

        let sacn: OutputDriver = SACNDriver(transport: FakeTransport(), interfaces: { [Fixture.lan] })
        XCTAssertEqual(sacn.reopenInterval, 3)
        sacn.forcePoll(now: 0)
        XCTAssertEqual(sacn.interfaces, [Fixture.lan])
        sacn.manualIP = IPv4Address(10, 0, 0, 9)
        XCTAssertEqual(sacn.manualIP, IPv4Address(10, 0, 0, 9))

        let artnet: OutputDriver = ArtNetController(transport: FakeTransport(), interfaces: { [] })
        artnet.onPreferredIdentityChanged = { _ in }
        XCTAssertNotNil(artnet.onPreferredIdentityChanged)
        artnet.preferredIdentity = "node"
        XCTAssertEqual(artnet.preferredIdentity, "node")
    }

    func testRegistryBuildsACoreOnlyDriver() {
        var registry = OutputDriverRegistry.builtIn
        registry.register(.init(id: CoreOnlyDriver.id, name: "Core only") { _, _ in CoreOnlyDriver() })
        let driver = registry.make(id: CoreOnlyDriver.id, transport: FakeTransport(), interfaces: { [] })
        XCTAssertTrue(driver is CoreOnlyDriver)
        XCTAssertEqual(driver.driverID, CoreOnlyDriver.id)
    }

    func testEngineDrivesACoreOnlyDriverEndToEnd() throws {
        let driver = CoreOnlyDriver()
        var registry = OutputDriverRegistry()
        registry.register(.init(id: CoreOnlyDriver.id, name: "Core only") { _, _ in driver })
        let clock = ManualClock()
        let engine = LightEngine(
            tempo: LocalTempoClock(bpm: 120, now: { clock.now }), transport: FakeTransport(), interfaces: { [] },
            clock: { clock.now }, runsTimer: false, outputDrivers: registry, outputDriverID: CoreOnlyDriver.id)
        var patch = Patch(fixtures: [.init(label: "Test", profileID: "generic.rgb3", universe: 0, address: 1)])
        patch.setConfirmed(true, library: ProfileLibrary())
        engine.start(); engine.setPatch(patch); engine.setMaster(1)
        var snapshot = EngineSnapshot()
        engine.onSnapshot = { snapshot = $0 }
        engine.stepForTesting()
        XCTAssertEqual(engine.outputDriverID, CoreOnlyDriver.id)
        XCTAssertTrue(engine.sync { driver.isOpen })
        XCTAssertEqual(engine.sync { driver.frames.count }, 0, "output never turns on by itself")
        XCTAssertEqual(snapshot.readiness, .ready)

        engine.setArmed(true)
        engine.stepForTesting()
        XCTAssertTrue(snapshot.armed)
        XCTAssertGreaterThan(engine.sync { driver.frames.count }, 0)

        engine.setArmed(false)
        engine.shutdown()
        XCTAssertFalse(driver.isOpen)
        let u0 = try XCTUnwrap(PortAddress(0))
        let last = try XCTUnwrap(driver.frames.last?[u0])
        XCTAssertTrue(last.allSatisfy { $0 == 0 }, "disarm ends on black")
    }

    /// The unverified manual target is named in the user's language, not hardcoded Italian.
    func testArtNetManualTargetNameIsLocalized() throws {
        let c = ArtNetController(transport: FakeTransport(), interfaces: { [Fixture.lan] })
        c.manualIP = IPv4Address(192, 168, 1, 99)
        let target = try XCTUnwrap(c.target(now: 0, patchUniverses: [try XCTUnwrap(PortAddress(0))]))
        XCTAssertEqual(target.name, String(localized: "Manual IP"))
        XCTAssertEqual(target.name, "Manual IP", "English is the source language in tests")
        XCTAssertFalse(target.verified)
    }
}
