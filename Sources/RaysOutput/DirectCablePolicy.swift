import Foundation

/// The application may add one temporary address to a wired adapter. It never
/// changes DHCP, the primary address, a network service, DNS, or a default route.
public struct DirectCablePolicy {
    public static let nodeAddress = "192.168.0.10"
    public static let localAddress = "192.168.0.20"
    public static let netmask = "255.255.255.0"

    public struct Address: Equatable {
        public let interface: String
        public let ip: String
        public let mask: String
        public init(interface: String, ip: String, mask: String) {
            self.interface = interface; self.ip = ip; self.mask = mask
        }
    }

    public enum Decision: Equatable {
        case ready
        case addAlias(command: String)
        case unavailable(String)
    }

    public static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(value)
        }
        return result
    }

    public static func evaluate(interface: String, isWired: Bool, isActive: Bool,
                                addresses: [Address]) -> Decision {
        guard interface.range(of: "^en[0-9]{1,3}$", options: .regularExpression) != nil,
              isWired, isActive else {
            return .unavailable("Collega il cavo Ethernet dal Mac all’ENTTEC e accendi l’ODE.")
        }
        let target = ipv4(nodeAddress)!
        let alias = ipv4(localAddress)!
        let subnetMask = ipv4(netmask)!
        for item in addresses {
            guard let ip = ipv4(item.ip), ipv4(item.mask) != nil else { continue }
            if ip == target {
                return .unavailable("Un’interfaccia del Mac usa l’indirizzo dell’ENTTEC. Risolvi il conflitto prima di collegarti.")
            }
            // Adding a connected /24 route must never divert an existing LAN,
            // Wi-Fi, VPN, or the Internet router to the lighting cable.
            if item.interface != interface && (ip & subnetMask) == (target & subnetMask) {
                return .unavailable("La rete 192.168.0.x è già usata da \(item.interface). Non modifico la rete: collega l’ODE alla stessa LAN oppure usa un indirizzo diverso per l’ODE.")
            }
            if item.interface != interface && ip == alias {
                return .unavailable("L’indirizzo dedicato alle luci è già usato da un’altra interfaccia.")
            }
        }
        // Check every other interface before accepting an existing wired address.
        // getifaddrs order must not hide a conflicting Wi-Fi subnet.
        if addresses.contains(where: { item in
            guard item.interface == interface, let ip = ipv4(item.ip), let mask = ipv4(item.mask) else { return false }
            return (ip & mask) == (target & mask)
        }) { return .ready }
        return .addAlias(command: "/sbin/ifconfig \(interface) alias \(localAddress) netmask \(netmask)")
    }

    public static func removalCommand(interface: String) -> String? {
        guard interface.range(of: "^en[0-9]{1,3}$", options: .regularExpression) != nil else { return nil }
        return "/sbin/ifconfig \(interface) inet \(localAddress) -alias"
    }
}
