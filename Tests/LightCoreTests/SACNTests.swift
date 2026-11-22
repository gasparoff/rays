import XCTest
@testable import RaysOutput

/// Packet layout per ANSI E1.31-2018, sections 4–7 (root, framing and DMP layers).
final class SACNTests: XCTestCase {
    let cid = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

    private func u16(_ p: [UInt8], _ i: Int) -> Int { Int(p[i]) << 8 | Int(p[i + 1]) }

    func testFullUniverseDataPacketLayout() throws {
        let data = (0..<512).map { UInt8($0 & 0xFF) }
        let p = try SACN.dataPacket(cid: cid, sourceName: "RAYS", priority: 100, sequence: 7, universe: 1, data: data)
        XCTAssertEqual(p.count, 638)
        // Root layer
        XCTAssertEqual(u16(p, 0), 0x0010, "preamble size")
        XCTAssertEqual(u16(p, 2), 0x0000, "post-amble size")
        XCTAssertEqual(Array(p[4..<16]), [0x41, 0x53, 0x43, 0x2D, 0x45, 0x31, 0x2E, 0x31, 0x37, 0x00, 0x00, 0x00])
        XCTAssertEqual(u16(p, 16), 0x7000 | 622, "root flags & length")
        XCTAssertEqual(Array(p[18..<22]), [0, 0, 0, 4], "VECTOR_ROOT_E131_DATA")
        XCTAssertEqual(Array(p[22..<38]), [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                           0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF], "CID")
        // Framing layer
        XCTAssertEqual(u16(p, 38), 0x7000 | 600, "framing flags & length")
        XCTAssertEqual(Array(p[40..<44]), [0, 0, 0, 2], "VECTOR_E131_DATA_PACKET")
        XCTAssertEqual(Array(p[44..<48]), Array("RAYS".utf8))
        XCTAssertTrue(p[48..<108].allSatisfy { $0 == 0 }, "source name is NUL padded to 64 bytes")
        XCTAssertEqual(p[108], 100, "priority")
        XCTAssertEqual(u16(p, 109), 0, "synchronization address")
        XCTAssertEqual(p[111], 7, "sequence")
        XCTAssertEqual(p[112], 0, "options")
        XCTAssertEqual(u16(p, 113), 1, "universe")
        // DMP layer
        XCTAssertEqual(u16(p, 115), 0x7000 | 523, "DMP flags & length")
        XCTAssertEqual(p[117], 0x02, "VECTOR_DMP_SET_PROPERTY")
        XCTAssertEqual(p[118], 0xA1, "address & data type")
        XCTAssertEqual(u16(p, 119), 0x0000, "first property address")
        XCTAssertEqual(u16(p, 121), 0x0001, "address increment")
        XCTAssertEqual(u16(p, 123), 513, "property value count")
        XCTAssertEqual(p[125], 0x00, "DMX start code")
        XCTAssertEqual(Array(p[126...]), data)
    }

    func testShortFramesLongNamesPriorityAndUniverseLimits() throws {
        let p = try SACN.dataPacket(cid: cid, sourceName: String(repeating: "é", count: 40), priority: 250,
                                    sequence: 0, options: [.streamTerminated], universe: 63999, data: [1, 2, 3])
        XCTAssertEqual(p.count, 129)
        XCTAssertEqual(u16(p, 16), 0x7000 | (129 - 16))
        XCTAssertEqual(u16(p, 115), 0x7000 | (129 - 115))
        XCTAssertEqual(u16(p, 123), 4)
        XCTAssertEqual(p[107], 0, "name keeps a terminating NUL")
        XCTAssertEqual(p[108], 200, "priority is clamped to 200")
        XCTAssertEqual(p[112], 0x40)
        XCTAssertEqual(u16(p, 113), 63999)
        XCTAssertThrowsError(try SACN.dataPacket(cid: cid, sourceName: "", priority: 100, sequence: 0, universe: 0, data: []))
        XCTAssertThrowsError(try SACN.dataPacket(cid: cid, sourceName: "", priority: 100, sequence: 0, universe: 64000, data: []))
        XCTAssertEqual(SACN.multicastAddress(universe: 1), IPv4Address(239, 255, 0, 1))
        XCTAssertEqual(SACN.multicastAddress(universe: 0x1234), IPv4Address(239, 255, 0x12, 0x34))
    }

    func testDriverSendsMulticastPerUniverseWithIncrementingSequence() throws {
        let t = FakeTransport()
        let d = SACNDriver(transport: t, interfaces: { [Fixture.lan] })
        d.open(queue: DispatchQueue(label: "t"), now: { 0 })
        let u0 = try XCTUnwrap(PortAddress(0)), u1 = try XCTUnwrap(PortAddress(1))
        let target = try XCTUnwrap(d.target(now: 0, patchUniverses: [u0, u1]))
        XCTAssertEqual(target.universes, [u0, u1])
        XCTAssertTrue(d.sendDMX([u0: [UInt8](repeating: 9, count: 512), u1: [UInt8](repeating: 1, count: 512)], to: target))
        d.sendDMX([u0: [UInt8](repeating: 0, count: 512)], to: target)
        XCTAssertEqual(t.sent.map(\.to), [IPv4Address(239, 255, 0, 1), IPv4Address(239, 255, 0, 2), IPv4Address(239, 255, 0, 1)])
        XCTAssertEqual(Set(t.sent.map(\.port)), [5568])
        XCTAssertEqual(t.sent.map { $0.bytes[111] }, [0, 0, 1])
        XCTAssertEqual(t.sent.map { u16($0.bytes, 113) }, [1, 2, 1])
        XCTAssertEqual(d.nodes(now: 0), [])
    }

    func testUnicastNeedsAnAddressAndOffsetIsConfigurable() throws {
        let t = FakeTransport()
        var config = SACNDriver.Configuration()
        config.mode = .unicast
        config.universeOffset = 0
        let d = SACNDriver(transport: t, interfaces: { [] }, configuration: config)
        let u1 = try XCTUnwrap(PortAddress(1)), u0 = try XCTUnwrap(PortAddress(0))
        XCTAssertNil(d.target(now: 0, patchUniverses: [u1]))
        d.manualIP = IPv4Address(192, 168, 1, 77)
        let target = try XCTUnwrap(d.target(now: 0, patchUniverses: [u0, u1]))
        XCTAssertEqual(target.universes, [u1], "universe 0 is not a valid sACN universe with offset 0")
        d.sendDMX([u1: [0]], to: target)
        XCTAssertEqual(t.sent.first?.to, IPv4Address(192, 168, 1, 77))
        XCTAssertEqual(t.sent.first.map { u16($0.bytes, 113) }, 1)
    }

    func testRegistryCanBuildTheSACNDriver() {
        var registry = OutputDriverRegistry.builtIn
        registry.register(.init(id: SACNDriver.driverID, name: "sACN") { SACNDriver(transport: $0, interfaces: $1) })
        XCTAssertTrue(registry.make(id: "sacn", transport: FakeTransport(), interfaces: { [] }) is SACNDriver)
    }
}
