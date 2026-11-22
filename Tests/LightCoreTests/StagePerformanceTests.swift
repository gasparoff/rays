import Foundation
import XCTest
@testable import RaysOutput
@testable import RaysCore
@testable import RaysEngine

final class LatestMailboxTests: XCTestCase {
    func testPostsCoalesceIntoOneWakeUpCarryingTheNewestValue() {
        let box = LatestMailbox<Int>()
        XCTAssertTrue(box.post(1))
        for i in 2...100 { XCTAssertFalse(box.post(i)) }
        XCTAssertEqual(box.take(), 100)
        XCTAssertNil(box.take())
    }

    func testTakeReArmsWakeUps() {
        let box = LatestMailbox<Int>()
        XCTAssertTrue(box.post(1))
        XCTAssertEqual(box.take(), 1)
        XCTAssertTrue(box.post(2), "a value posted after a take must wake the consumer again")
        XCTAssertEqual(box.take(), 2)
    }

    /// Regression for the unbounded `DispatchQueue.main.async` per snapshot: while the consumer queue is
    /// blocked, a burst of 30 Hz frames schedules a single block, which then delivers only the newest frame.
    func testBlockedConsumerGetsOneDeliveryOfTheNewestSnapshot() {
        let box = LatestMailbox<EngineSnapshot>()
        let consumer = DispatchQueue(label: "test.consumer")
        let gate = DispatchSemaphore(value: 0)
        consumer.async { gate.wait() }
        var delivered: [UInt64] = []
        for frame in 1...300 {
            var snap = EngineSnapshot()
            snap.framesSent = UInt64(frame)
            snap.fixtures = [FixtureVisual(id: "c", label: "Centro", profileID: "varytec-tri380-25ch", role: .center,
                                           universe: 0, address: 1, rgb: Array(repeating: LightColor(1, 0, 0), count: 6),
                                           cob: [0, 0, 0], status: .live)]
            box.post(snap, on: consumer) { delivered.append($0.framesSent) }
        }
        gate.signal()
        consumer.sync {}
        XCTAssertEqual(delivered, [300])
    }

    func testConcurrentProducerNeverLosesTheFinalValueOrStacksWakeUps() {
        let box = LatestMailbox<Int>()
        let consumer = DispatchQueue(label: "test.consumer")
        let lock = NSLock()
        var outstanding = 0, maxOutstanding = 0, last = 0, deliveries = 0
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for i in 0..<2_000 {
                let value = worker * 10_000 + i
                if box.post(value) {
                    lock.lock(); outstanding += 1; maxOutstanding = max(maxOutstanding, outstanding); lock.unlock()
                    consumer.async {
                        lock.lock(); outstanding -= 1; lock.unlock()
                        if let v = box.take() { last = v; deliveries += 1 }
                    }
                }
            }
        }
        consumer.sync {}
        XCTAssertEqual(maxOutstanding, 1)
        XCTAssertNil(box.take(), "everything posted was drained")
        XCTAssertGreaterThan(deliveries, 0)
        XCTAssertTrue((0..<4).map { $0 * 10_000 + 1_999 }.contains(last), "the final delivery is some producer's last value")
    }
}

final class StageLayoutTests: XCTestCase {
    func testMirrorsKeepAllFacetsAndTileTheFace() {
        let layout = StageLayout(size: CGSize(width: 990, height: 460), large: [false, true, false])
        XCTAssertEqual(layout.fixtures.map(\.facets.count), [49, 100, 49])
        for fixture in layout.fixtures {
            func area(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
                abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
            }
            let facetArea = fixture.facets.reduce(0) { $0 + area($1.a, $1.b, $1.c) }
            XCTAssertEqual(facetArea, area(fixture.top, fixture.left, fixture.right), accuracy: 1e-6)
        }
    }

    func testCentreFixtureShowsSixRGBZonesAndThreeCOBStrips() {
        let layout = StageLayout(size: CGSize(width: 990, height: 460), large: [false, true, false])
        let centre = layout.fixtures[1]
        let counts = (0..<6).map { s in centre.facets.filter { $0.segment == s }.count }
        // Facet count per zone of the original angular mapping (centroids on a wedge boundary fall clockwise).
        XCTAssertEqual(counts, [15, 18, 18, 22, 18, 9])
        XCTAssertEqual(centre.strips.count, 3)
        XCTAssertEqual(layout.fixtures[0].strips.count, 1)
        XCTAssertEqual(layout.fixtures[2].strips.count, 1)
        // Top strip is vertical and above the centre, the two lower ones are mirror images.
        XCTAssertEqual(centre.strips[0].from.x, centre.center.x)
        XCTAssertLessThan(centre.strips[0].to.y, centre.center.y)
        XCTAssertEqual(centre.strips[1].to.x - centre.center.x, centre.center.x - centre.strips[2].to.x, accuracy: 1e-9)

        let zones = (0..<6).map { LightColor(Double($0) / 5, 0, 0) }
        for facet in centre.facets {
            XCTAssertEqual(StageLayout.zoneColor(zones, segment: facet.segment), zones[facet.segment])
            XCTAssertEqual(StageLayout.zoneColor([LightColor(0, 1, 0)], segment: facet.segment), LightColor(0, 1, 0))
        }
        XCTAssertEqual(StageLayout.zoneColor([], segment: 3), .black)
    }

    func testFacetShadingIsDeterministicAndBounded() {
        let a = StageLayout(size: CGSize(width: 990, height: 460), large: [true])
        let b = StageLayout(size: CGSize(width: 990, height: 460), large: [true])
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a.fixtures[0].facets.map(\.reflection)).count, 11, "reflectivity spans 0.0…1.0 in 0.1 steps")
        let dark = StageLayout.facetColor(.black, reflection: 0)
        XCTAssertEqual(dark.r, 0.04, accuracy: 1e-12)
        let full = StageLayout.facetColor(LightColor(1, 0.5, 0), reflection: 1)
        XCTAssertEqual(full.r, 1); XCTAssertEqual(full.g, 0.095 + 0.5, accuracy: 1e-12); XCTAssertEqual(full.b, 0.095, accuracy: 1e-12)
    }

}
