import XCTest
@testable import LightCore

final class ArtNetTests: XCTestCase {
    func testArtDmxExactByteLayout() throws {
        let data = (0..<512).map { UInt8($0 & 0xFF) }
        let p = try ArtNet.artDmx(sequence: 7, portAddress: PortAddress(1)!, data: data)
        XCTAssertEqual(p.count, 530)
        XCTAssertEqual(Array(p[0..<8]), Array("Art-Net".utf8) + [0])
        XCTAssertEqual(p[8], 0x00, "OpCode low byte first (little-endian)")
        XCTAssertEqual(p[9], 0x50)
        XCTAssertEqual(p[10], 0x00, "ProtVer high byte first")
        XCTAssertEqual(p[11], 14)
        XCTAssertEqual(p[12], 7, "Sequence")
        XCTAssertEqual(p[13], 0, "Physical")
        XCTAssertEqual(p[14], 1, "SubUni = low byte of Port-Address")
        XCTAssertEqual(p[15], 0, "Net")
        XCTAssertEqual(p[16], 0x02, "Length high byte (512)")
        XCTAssertEqual(p[17], 0x00)
        XCTAssertEqual(Array(p[18...]), data)
    }

    func testArtDmxPadsTo512AndRejectsOversize() throws {
        let p = try ArtNet.artDmx(sequence: 1, portAddress: PortAddress(0)!, data: [255, 128, 1])
        XCTAssertEqual(p.count, 530)
        XCTAssertEqual(Array(p[18..<21]), [255, 128, 1])
        XCTAssertTrue(p[21...].allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try ArtNet.artDmx(sequence: 1, portAddress: PortAddress(0)!, data: [UInt8](repeating: 0, count: 513)))
    }

    func testPortAddressIsZeroBasedAndBounded() {
        XCTAssertEqual(PortAddress(0)?.subUni, 0)
        XCTAssertEqual(PortAddress(0)?.net, 0)
        XCTAssertEqual(PortAddress(1)?.subUni, 1)
        let pa = PortAddress(net: 1, subNet: 2, universe: 3)
        XCTAssertEqual(pa.rawValue, 0x123)
        XCTAssertEqual(pa.subUni, 0x23)
        XCTAssertEqual(pa.net, 1)
        XCTAssertNil(PortAddress(-1))
        XCTAssertNil(PortAddress(32768))
        XCTAssertNotNil(PortAddress(32767))
    }

    func testSequenceSkipsZero() {
        XCTAssertEqual(ArtNet.nextSequence(after: 0), 1)
        XCTAssertEqual(ArtNet.nextSequence(after: 254), 255)
        XCTAssertEqual(ArtNet.nextSequence(after: 255), 1)
    }

    func testArtPollLayout() {
        let p = ArtNet.artPoll()
        XCTAssertEqual(p.count, 14)
        XCTAssertEqual(ArtNet.opCode(of: p), 0x2000)
        XCTAssertEqual(Array(p[8..<12]), [0x00, 0x20, 0x00, 14])
    }

    func testParsesOdeMk3PollReply() throws {
        let r = try ArtPollReply.parse(Fixture.pollReply())
        XCTAssertEqual(r.ip, IPv4Address(192, 168, 1, 50))
        XCTAssertEqual(r.udpPort, 6454)
        XCTAssertEqual(r.estaManufacturer, 0x454E)
        XCTAssertEqual(r.oem, 0x1234)
        XCTAssertEqual(r.shortName, "ODE Mk3")
        XCTAssertEqual(r.longName, "ENTTEC ODE Mk3")
        XCTAssertEqual(r.outputPorts.map(\.portAddress), [PortAddress(0)!, PortAddress(1)!])
        XCTAssertEqual(r.macString, "00:50:c2:11:22:33")
        XCTAssertEqual(r.bindIndex, 1)
    }

    func testPollReplyNetAndSubnetComposePortAddress() throws {
        let r = try ArtPollReply.parse(Fixture.pollReply(net: 2, sub: 3, swOut: [4, 5]))
        XCTAssertEqual(r.outputPorts.map(\.portAddress.rawValue), [0x234, 0x235])
    }

    func testInputOnlyPortsAreNotOutputs() throws {
        let r = try ArtPollReply.parse(Fixture.pollReply(portTypes: [0x40, 0x80]))
        XCTAssertEqual(r.outputPorts.map(\.portAddress), [PortAddress(1)!])
    }

    func testMalformedPollRepliesAreRejected() {
        XCTAssertThrowsError(try ArtPollReply.parse([])) { XCTAssertEqual($0 as? ArtNetError, .tooShort(0)) }
        XCTAssertThrowsError(try ArtPollReply.parse(Fixture.pollReply(length: 120))) { XCTAssertEqual($0 as? ArtNetError, .tooShort(120)) }
        var bad = Fixture.pollReply(); bad[3] = UInt8(ascii: "x")
        XCTAssertThrowsError(try ArtPollReply.parse(bad)) { XCTAssertEqual($0 as? ArtNetError, .badHeader) }
        XCTAssertThrowsError(try ArtPollReply.parse(ArtNet.artPoll())) { XCTAssertEqual($0 as? ArtNetError, .unexpectedOpCode(0x2000)) }
        // Art-Net specification minimum is 207 bytes; future optional fields may
        // be absent, but truncated required fields are rejected.
        XCTAssertThrowsError(try ArtPollReply.parse(Fixture.pollReply(length: 197)))
        XCTAssertEqual(try ArtPollReply.parse(Fixture.pollReply(length: 207)).bindIndex, 0)
    }

    func testUnterminatedNameIsBoundedToField() throws {
        let r = try ArtPollReply.parse(Fixture.pollReply(shortName: String(repeating: "A", count: 30)))
        XCTAssertEqual(r.shortName.count, 18, "an unterminated 18-byte name never reads into LongName")
    }

    func testIPv4Parsing() {
        XCTAssertEqual(IPv4Address(string: "192.168.0.10"), IPv4Address(192, 168, 0, 10))
        XCTAssertNil(IPv4Address(string: "192.168.0"))
        XCTAssertNil(IPv4Address(string: "192.168.0.256"))
        XCTAssertNil(IPv4Address(string: "a.b.c.d"))
        XCTAssertTrue(IPv4Address(169, 254, 3, 4).isLinkLocal)
    }
}
