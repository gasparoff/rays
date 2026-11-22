import XCTest
@testable import RaysOutput

final class DiscoveryTests: XCTestCase {
    func testEnttecMatcher() {
        XCTAssertTrue(EnttecMatcher.matches(esta: 0x454E, shortName: "x", longName: ""))
        XCTAssertTrue(EnttecMatcher.matches(esta: 0, shortName: "ODE Mk3", longName: ""))
        XCTAssertTrue(EnttecMatcher.matches(esta: 0, shortName: "", longName: "Enttec Storm"))
        XCTAssertFalse(EnttecMatcher.matches(esta: 0, shortName: "ArtNet NODE", longName: "Generic Node"))
    }

    func testAutoSelectOnlySingleEnttec() {
        var reg = NodeRegistry()
        reg.ingest(try! ArtPollReply.parse(Fixture.pollReply(shortName: "Node", longName: "Generic", esta: 0, mac: [2, 0, 0, 0, 0, 9])),
                   from: IPv4Address(192, 168, 1, 60), at: 0)
        XCTAssertNil(reg.autoSelectCandidate(now: 0), "generic Art-Net nodes are never auto-selected")
        reg.ingest(try! ArtPollReply.parse(Fixture.pollReply()), from: IPv4Address(192, 168, 1, 50), at: 0)
        XCTAssertEqual(reg.autoSelectCandidate(now: 0)?.ip, IPv4Address(192, 168, 1, 50))
        reg.ingest(try! ArtPollReply.parse(Fixture.pollReply(ip: IPv4Address(192, 168, 1, 51), mac: [0, 0x50, 0xC2, 9, 9, 9])),
                   from: IPv4Address(192, 168, 1, 51), at: 0)
        XCTAssertNil(reg.autoSelectCandidate(now: 0), "two ENTTEC devices: user must choose")
    }

    func testIPChangeKeepsIdentityViaMAC() {
        var reg = NodeRegistry()
        let a = reg.ingest(try! ArtPollReply.parse(Fixture.pollReply()), from: IPv4Address(192, 168, 1, 50), at: 0)
        let b = reg.ingest(try! ArtPollReply.parse(Fixture.pollReply(ip: IPv4Address(192, 168, 1, 77))),
                           from: IPv4Address(192, 168, 1, 77), at: 5)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(reg.nodes.count, 1)
        XCTAssertEqual(reg.node(id: a.id)?.ip, IPv4Address(192, 168, 1, 77))
    }

    func testControllerPollsBroadcastsOnlyAndAutoSelects() {
        let t = FakeTransport()
        let c = ArtNetController(transport: t, interfaces: { [Fixture.lan] })
        var selected: String?
        c.onPreferredIdentityChanged = { selected = $0 }
        c.open(queue: .main, now: { 0 })
        c.pollIfDue(now: 0)
        c.pollIfDue(now: 1)  // too early, ignored
        XCTAssertEqual(t.pollPackets.map(\.to), [IPv4Address(192, 168, 1, 255)])
        c.pollIfDue(now: 3.1)
        XCTAssertEqual(t.pollPackets.count, 2)

        t.receive?(ArtNet.artPoll(), IPv4Address(192, 168, 1, 20))  // our own broadcast is ignored
        XCTAssertTrue(c.nodes(now: 0).isEmpty)
        t.receive?(Fixture.pollReply(), IPv4Address(192, 168, 1, 50))
        XCTAssertEqual(selected, "mac:00:50:c2:11:22:33")
        let target = c.target(now: 4, patchUniverses: [PortAddress(0)!])
        XCTAssertEqual(target?.ip, IPv4Address(192, 168, 1, 50))
        XCTAssertEqual(target?.verified, true)
        XCTAssertEqual(target?.fresh, true)
        XCTAssertEqual(c.target(now: 30, patchUniverses: [])?.fresh, false, "stale after 10 s without replies")
        XCTAssertTrue(c.nodes(now: 30).first!.isStale)
    }

    func testDMXIsUnicastOnlyToSubscribedUniversesWithSequence() throws {
        let t = FakeTransport()
        let c = ArtNetController(transport: t, interfaces: { [Fixture.lan] })
        c.open(queue: .main, now: { 0 })
        let target = OutputTarget(ip: IPv4Address(192, 168, 1, 50), name: "ODE", universes: [PortAddress(0)!],
                                  verified: true, fresh: true)
        let frames: [PortAddress: [UInt8]] = [PortAddress(0)!: [1, 2, 3], PortAddress(1)!: [9]]
        XCTAssertTrue(c.sendDMX(frames, to: target))
        XCTAssertTrue(c.sendDMX(frames, to: target))
        XCTAssertEqual(t.dmxPackets.count, 2, "universe 1 is not subscribed by the node")
        XCTAssertTrue(t.dmxPackets.allSatisfy { $0.to == IPv4Address(192, 168, 1, 50) && $0.port == 6454 })
        XCTAssertEqual(t.dmxPackets.map { $0.bytes[12] }, [1, 2])
        XCTAssertEqual(t.dmxPackets[0].bytes.count, 530)
    }

    func testManualIPIsUnverifiedUntilReply() {
        let t = FakeTransport()
        let c = ArtNetController(transport: t, interfaces: { [Fixture.lan] })
        c.open(queue: .main, now: { 0 })
        c.manualIP = IPv4Address(192, 168, 1, 50)
        c.forcePoll(now: 0)
        XCTAssertTrue(t.pollPackets.contains { $0.to == IPv4Address(192, 168, 1, 50) })
        XCTAssertEqual(c.target(now: 0, patchUniverses: [PortAddress(0)!])?.verified, false)
        t.receive?(Fixture.pollReply(), IPv4Address(192, 168, 1, 50))
        XCTAssertEqual(c.target(now: 0, patchUniverses: [])?.verified, true)
        XCTAssertNil(c.preferredIdentity, "no auto-select while a manual IP is in use")
    }

    func testBindFailureIsSurfaced() {
        let t = FakeTransport()
        t.failBind = true
        let c = ArtNetController(transport: t, interfaces: { [] })
        c.open(queue: .main, now: { 0 })
        XCTAssertNotNil(c.socketError)
        XCTAssertTrue(c.socketError!.contains("6454"))
    }

    func testDirectCableDiagnosis() {
        let linkLocal = NetworkInterface(name: "en7", address: IPv4Address(169, 254, 10, 2),
                                         netmask: IPv4Address(255, 255, 0, 0), broadcast: IPv4Address(169, 254, 255, 255))
        let msgs = NetworkDiagnosis.messages(interfaces: [linkLocal], nodes: [], manualIP: nil, socketError: nil, pollCount: 3)
        XCTAssertTrue(msgs.contains { $0.contains("169.254") && $0.contains("192.168.0.10") })
    }
}
