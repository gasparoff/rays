import Foundation

/// The application may add one temporary address to a wired adapter. It never
/// changes DHCP, the primary address, a network service, DNS, or a default route.
public struct DirectCablePolicy {
    public static let nodeAddress = "192.168.0.10"
    public static let localAddress = "192.168.0.20"
    public static let netmask = "255.255.255.0"

    /// An IPv4 address and netmask configured on one network interface.
    public struct Address: Equatable {
        public let interface: String
        public let ip: String
        public let mask: String
        public init(interface: String, ip: String, mask: String) {
            self.interface = interface; self.ip = ip; self.mask = mask
        }
    }

    /// What the app may do for the selected adapter.
    public enum Decision: Equatable {
        case ready
        case addAlias(command: String)
        case unavailable(String)
    }

    /// True only for a BSD Ethernet name such as `en8`: "en" and one to three ASCII digits,
    /// nothing else (no whitespace, no newline). Every command below embeds this name in a
    /// shell run with administrator rights, so it is checked character by character.
    public static func isWiredInterfaceName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (3...5).contains(bytes.count), bytes[0] == UInt8(ascii: "e"), bytes[1] == UInt8(ascii: "n") else { return false }
        return bytes.dropFirst(2).allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    public static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                let value = UInt8(part)
            else { return nil }
            result = (result << 8) | UInt32(value)
        }
        return result
    }

    public static func evaluate(
        interface: String, isWired: Bool, isActive: Bool,
        addresses: [Address]
    ) -> Decision {
        guard isWiredInterfaceName(interface), isWired, isActive
        else {
            return .unavailable(String(localized: "Connect the Ethernet cable from the Mac to the ENTTEC and power on the ODE."))
        }
        let target = ipv4(nodeAddress)!
        let alias = ipv4(localAddress)!
        let subnetMask = ipv4(netmask)!
        for item in addresses {
            guard let ip = ipv4(item.ip), ipv4(item.mask) != nil else { continue }
            if ip == target {
                return .unavailable(
                    String(localized: "A Mac interface is using the ENTTEC's address. Resolve the conflict before connecting."))
            }
            // Adding a connected /24 route must never divert an existing LAN,
            // Wi-Fi, VPN, or the Internet router to the lighting cable.
            if item.interface != interface && (ip & subnetMask) == (target & subnetMask) {
                return .unavailable(
                    String(
                        localized:
                            "The 192.168.0.x network is already used by \(String(describing: item.interface)). RAYS won't change it: connect the ODE to the same LAN or give the ODE a different address."
                    )
                )
            }
            if item.interface != interface && ip == alias {
                return .unavailable(String(localized: "The address reserved for the lights is already used by another interface."))
            }
        }
        // Check every other interface before accepting an existing wired address.
        // getifaddrs order must not hide a conflicting Wi-Fi subnet.
        if addresses.contains(where: { item in
            guard item.interface == interface, let ip = ipv4(item.ip), let mask = ipv4(item.mask) else { return false }
            return (ip & mask) == (target & mask)
        }) {
            return .ready
        }
        return .addAlias(command: "/sbin/ifconfig \(interface) alias \(localAddress) netmask \(netmask)")
    }

    public static func removalCommand(interface: String) -> String? {
        guard isWiredInterfaceName(interface) else { return nil }
        return "/sbin/ifconfig \(interface) inet \(localAddress) -alias"
    }
}
