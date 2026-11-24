import Foundation
import XCTest
@testable import RaysOutput
@testable import RaysTempo
@testable import RaysEngine

/// A value shared between test threads, guarded by a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }

    var current: Value { withValue { $0 } }
}

/// Threading contracts of the engine's public callbacks.
final class EngineConcurrencyTests: XCTestCase {
    /// The app sets the handlers on the main thread while the engine reads them on its queue for
    /// every frame. Swapping them while frames run is safe and takes effect on the next frame.
    func testHandlersCanBeReplacedFromAnotherThreadWhileFramesRun() {
        let clock = ManualClock()
        let engine = LightEngine(
            tempo: LocalTempoClock(bpm: 120, now: { clock.now }), transport: FakeTransport(), interfaces: { [] },
            clock: { clock.now }, runsTimer: false)
        engine.start()
        let early = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            for _ in 0..<300 {
                if worker == 0 {
                    engine.onSnapshot = { _ in early.withValue { $0 += 1 } }
                    engine.onPreferredNodeChanged = { _ in }
                } else {
                    engine.stepForTesting()
                }
            }
        }
        XCTAssertLessThanOrEqual(early.current, 300, "at most one snapshot per frame")

        let latest = Locked(0)
        engine.onSnapshot = { _ in latest.withValue { $0 += 1 } }
        engine.stepForTesting()
        XCTAssertEqual(latest.current, 1, "the handler set last receives the next frame")
        engine.onSnapshot = nil
        engine.stepForTesting()
        XCTAssertEqual(latest.current, 1, "a removed handler is not called again")
        engine.shutdown()
    }

    /// Registries are built on the main thread and used on the engine queue.
    func testRegistriesCanBeHandedToAnotherQueue() {
        let outputs = OutputDriverRegistry.builtIn
        var tempos = TempoSourceRegistry.builtIn
        tempos.register(MIDIClockTempoSource.descriptor)
        let built = Locked<[String]>([])
        let queue = DispatchQueue(label: "test.registries")
        queue.sync {
            let driver = outputs.make(transport: FakeTransport(), interfaces: { [] })
            let source = tempos.make(id: MIDIClockTempoSource.sourceID, bpm: 100)
            built.withValue { $0 = [driver.driverID, String(describing: type(of: source))] }
        }
        XCTAssertEqual(built.current, [ArtNetController.driverID, "MIDIClockTempoSource"])
    }
}
