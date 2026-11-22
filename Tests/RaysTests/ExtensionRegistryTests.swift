import XCTest
@testable import RaysOutput
@testable import RaysTempo
@testable import RaysEngine

final class ExtensionRegistryTests: XCTestCase {
    func testBuiltInOutputDriverIsArtNetAndUnknownIDsFallBackToIt() {
        let registry = OutputDriverRegistry.builtIn
        XCTAssertEqual(registry.descriptors.map(\.id), ["artnet"])
        let driver = registry.make(transport: FakeTransport(), interfaces: { [] })
        XCTAssertTrue(driver is ArtNetController)
        XCTAssertEqual(driver.reopenInterval, ArtNetController.pollInterval)
        XCTAssertTrue(registry.make(id: "missing", transport: FakeTransport(), interfaces: { [] }) is ArtNetController)
    }

    func testRegisteringADriverReplacesOnlyThatID() {
        var registry = OutputDriverRegistry.builtIn
        let alt = OutputDriverRegistry.Descriptor(id: "artnet-alt", name: "Alt") { ArtNetController(transport: $0, interfaces: $1) }
        registry.register(alt)
        registry.register(alt)
        XCTAssertEqual(registry.descriptors.map(\.id), ["artnet", "artnet-alt"])
        XCTAssertEqual(registry.descriptor(id: "artnet-alt")?.name, "Alt")
    }

    func testEngineUsesTheDriverFromTheRegistry() {
        var made = 0
        var registry = OutputDriverRegistry()
        registry.register(.init(id: "probe", name: "Probe") { transport, interfaces in
            made += 1
            return ArtNetController(transport: transport, interfaces: interfaces)
        })
        _ = LightEngine(tempo: LocalTempoClock(), transport: FakeTransport(), interfaces: { [] },
                        runsTimer: false, outputDrivers: registry, outputDriverID: "probe")
        XCTAssertEqual(made, 1)
    }

    func testTempoRegistryBuildsTheInternalClockAndRegisteredSources() {
        var registry = TempoSourceRegistry.builtIn
        let clock = registry.make(id: TempoSourceRegistry.internalClockID, bpm: 128)
        XCTAssertTrue(clock is LocalTempoClock)
        XCTAssertEqual(clock.capture().bpm, 128)
        XCTAssertTrue(registry.make(id: "unknown", bpm: 90) is LocalTempoClock)

        registry.register(.init(id: "fixed", name: "Fixed") { DownbeatTempoSource(source: LocalTempoClock(bpm: $0)) })
        let fixed = registry.make(id: "fixed", bpm: 100)
        XCTAssertTrue(fixed is DownbeatTempoSource)
        XCTAssertEqual(fixed.capture().bpm, 100)
    }
}
