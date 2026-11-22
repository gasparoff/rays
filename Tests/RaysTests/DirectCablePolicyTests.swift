import XCTest
@testable import RaysOutput

final class DirectCablePolicyTests: XCTestCase {
    func testObservedDirectCablePreservesWiFi() {
        let addresses = [DirectCablePolicy.Address(interface: "en0", ip: "192.168.5.130", mask: "255.255.255.0"),
                         .init(interface: "en8", ip: "169.254.223.65", mask: "255.255.0.0")]
        XCTAssertEqual(DirectCablePolicy.evaluate(interface: "en8", isWired: true, isActive: true, addresses: addresses),
                       .addAlias(command: "/sbin/ifconfig en8 alias 192.168.0.20 netmask 255.255.255.0"))
    }

    func testNeverChangesWiFiOrInactiveCable() {
        for (name, wired, active) in [("en0", false, true), ("en8", true, false), ("en8;whoami", true, true)] {
            guard case .unavailable = DirectCablePolicy.evaluate(interface: name, isWired: wired, isActive: active, addresses: []) else {
                return XCTFail("Must refuse unsafe interface")
            }
        }
    }

    func testRefusesOverlappingWiFiSubnet() {
        let addresses = [DirectCablePolicy.Address(interface: "en0", ip: "192.168.0.55", mask: "255.255.255.0")]
        guard case .unavailable = DirectCablePolicy.evaluate(interface: "en8", isWired: true, isActive: true, addresses: addresses) else {
            return XCTFail("An alias must not divert an existing LAN")
        }
    }

    func testExistingAliasDoesNotHideLaterWiFiConflict() {
        let addresses = [DirectCablePolicy.Address(interface: "en8", ip: "192.168.0.20", mask: "255.255.255.0"),
                         .init(interface: "en0", ip: "192.168.0.55", mask: "255.255.255.0")]
        for ordered in [addresses, addresses.reversed().map { $0 }] {
            guard case .unavailable = DirectCablePolicy.evaluate(interface: "en8", isWired: true, isActive: true, addresses: ordered) else {
                return XCTFail("A conflict must not depend on getifaddrs order")
            }
        }
    }

    func testAlreadyPreparedDoesNotRunAnotherCommand() {
        let addresses = [DirectCablePolicy.Address(interface: "en8", ip: "192.168.0.20", mask: "255.255.255.0")]
        XCTAssertEqual(DirectCablePolicy.evaluate(interface: "en8", isWired: true, isActive: true, addresses: addresses), .ready)
    }

    func testRejectsLocalNodeAddressAndCommandInjection() {
        let addresses = [DirectCablePolicy.Address(interface: "en8", ip: "192.168.0.10", mask: "255.255.255.0")]
        guard case .unavailable = DirectCablePolicy.evaluate(interface: "en8", isWired: true, isActive: true, addresses: addresses) else {
            return XCTFail("Mac must not claim the ODE address")
        }
        XCTAssertNil(DirectCablePolicy.removalCommand(interface: "en8\nwhoami"))
        XCTAssertNil(DirectCablePolicy.ipv4("192.168.0.999"))
        XCTAssertNil(DirectCablePolicy.ipv4("192.168.0.20;id"))
    }

    func testInterfaceNameIsCheckedCharacterByCharacter() {
        for name in ["en0", "en8", "en12", "en999"] {
            XCTAssertTrue(DirectCablePolicy.isWiredInterfaceName(name), name)
        }
        // A trailing newline satisfies the regex anchor `$`; it must never reach the root shell.
        for name in ["en8\n", "en8\r", " en8", "en8 ", "en", "en1234", "eth0", "bridge0", "en٣", "en８", "EN8", "en8;id"] {
            XCTAssertFalse(DirectCablePolicy.isWiredInterfaceName(name), name.debugDescription)
            XCTAssertNil(DirectCablePolicy.removalCommand(interface: name), name.debugDescription)
            guard case .unavailable = DirectCablePolicy.evaluate(interface: name, isWired: true, isActive: true, addresses: [])
            else { return XCTFail("Must refuse \(name.debugDescription)") }
        }
    }
}
