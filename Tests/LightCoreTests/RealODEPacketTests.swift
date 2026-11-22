import Foundation
import XCTest
@testable import RaysOutput

final class RealODEPacketTests: XCTestCase {
    func testActualODEMk3TwoBoundPortRepliesMergeOnUniverseOne() throws {
        var registry = NodeRegistry()
        let b1 = Array(Data(base64Encoded: "QXJ0LU5ldAAAIcCoAAo2GQEFAAABkAACTkVPREUgTWszAAAAAAAAAAAAAABPREUgTWszIDIgcG9ydAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABgAAAAAAAAACCAAAAAAAAAAEAAAAAAAAAAAAA0J/ZAAABwKgACgENAACAgAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")!)
        let r1 = try ArtPollReply.parse(b1)
        XCTAssertEqual(r1.bindIndex, 1)
        XCTAssertEqual(r1.outputPorts.map(\.portAddress), [PortAddress(1)!])
        registry.ingest(r1, from: .init(192, 168, 0, 10), at: 1000)
        let b2 = Array(Data(base64Encoded: "QXJ0LU5ldAAAIcCoAAo2GQEFAAABkAACTkVPREUgTWszAAAAAAAAAAAAAABPREUgTWszIDIgcG9ydAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABgAAAAAAAAACCAAAAAAAAAAEAAAAAAAAAAAAA0J/ZAAABwKgACgINAACAgAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")!)
        let r2 = try ArtPollReply.parse(b2)
        XCTAssertEqual(r2.bindIndex, 2)
        XCTAssertEqual(r2.outputPorts.map(\.portAddress), [PortAddress(1)!])
        registry.ingest(r2, from: .init(192, 168, 0, 10), at: 1000)
        XCTAssertEqual(registry.nodes.count, 1)
        let node = try XCTUnwrap(registry.autoSelectCandidate(now: 1000))
        XCTAssertEqual(node.portsByBind.count, 2)
        XCTAssertEqual(node.mac, "d0:9f:d9:00:00:01")
        XCTAssertEqual(node.outputUniverses, [PortAddress(1)!])
    }
}
