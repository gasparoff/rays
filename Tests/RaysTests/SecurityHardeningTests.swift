import XCTest

@testable import RaysOutput

/// Inputs that cross a trust boundary: unauthenticated LAN packets and the root shell command.
final class SecurityHardeningTests: XCTestCase {
    func testInterfaceNameIsCheckedCharacterByCharacter() {
        for name in ["en0", "en8", "en12", "en999"] {
            XCTAssertTrue(DirectCablePolicy.isWiredInterfaceName(name), name)
        }
        // A trailing newline satisfies the regex anchor `$`; it must never reach the root shell.
        let unsafe = ["en8\n", "en8\r", " en8", "en8 ", "en", "en1234", "eth0", "bridge0", "en٣", "en８", "EN8", "en8;id"]
        for name in unsafe {
            XCTAssertFalse(DirectCablePolicy.isWiredInterfaceName(name), name.debugDescription)
            XCTAssertNil(DirectCablePolicy.removalCommand(interface: name), name.debugDescription)
            let decision = DirectCablePolicy.evaluate(interface: name, isWired: true, isActive: true, addresses: [])
            guard case .unavailable = decision else { return XCTFail("Must refuse \(name.debugDescription)") }
        }
    }

    func testSpoofedReplyFloodCannotGrowRegistryOrEvictFreshNodes() throws {
        var registry = NodeRegistry()
        registry.capacity = 8
        let realReply = try ArtPollReply.parse(Fixture.pollReply())
        let real = registry.ingest(realReply, from: IPv4Address(192, 168, 1, 50), at: 0)
        for i in 0..<500 {
            let mac: [UInt8] = [0x02, 0, 0, 0, UInt8(i >> 8), UInt8(i & 0xFF)]
            let fake = try ArtPollReply.parse(Fixture.pollReply(shortName: "Fake", longName: "Fake", esta: 0, mac: mac))
            registry.ingest(fake, from: IPv4Address(192, 168, 1, 99), at: 1, keeping: real.id)
        }
        XCTAssertEqual(registry.nodes.count, 8, "memory stays bounded")
        XCTAssertNotNil(registry.node(id: real.id), "a fresh node is never evicted")

        // Once the flood is stale it makes room for new nodes, but the selected node is kept.
        let laterReply = try ArtPollReply.parse(Fixture.pollReply(ip: IPv4Address(192, 168, 1, 51), mac: [0, 0x50, 0xC2, 9, 9, 9]))
        let later = registry.ingest(laterReply, from: IPv4Address(192, 168, 1, 51), at: 30, keeping: real.id)
        XCTAssertEqual(registry.nodes.count, 8)
        XCTAssertNotNil(registry.node(id: later.id))
        XCTAssertNotNil(registry.node(id: real.id), "the preferred node survives even when stale")
    }
}
