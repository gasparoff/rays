import Foundation

/// An Art-Net node seen via ArtPollReply. Multiple replies (BindIndex) from one device are merged.
public struct DiscoveredNode: Identifiable, Equatable, Sendable {
    /// Stable identity: MAC when reported, otherwise the IP (cannot survive IP changes).
    public var id: String
    /// Source address of the reply: the address actually reachable from this Mac.
    public var ip: IPv4Address
    /// Address declared inside the reply (may differ on misconfigured nodes).
    public var reportedIP: IPv4Address
    public var shortName: String
    public var longName: String
    public var nodeReport: String
    public var mac: String?
    public var estaManufacturer: UInt16
    public var oem: UInt16
    public var firmwareVersion: UInt16
    public var portsByBind: [UInt8: [PortAddress]]
    public var lastSeen: TimeInterval
    public var isEnttec: Bool
    public var isStale = false

    public var outputUniverses: [PortAddress] { Array(Set(portsByBind.values.joined())).sorted() }
    public var displayName: String { longName.isEmpty ? (shortName.isEmpty ? ip.description : shortName) : longName }
}

public enum EnttecMatcher {
    /// ESTA manufacturer code registered to ENTTEC ("EN").
    public static let estaCode: UInt16 = 0x454E

    public static func matches(esta: UInt16, shortName: String, longName: String) -> Bool {
        if esta == estaCode { return true }
        let text = (shortName + " " + longName).uppercased()
        if text.contains("ENTTEC") { return true }
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains("ODE")
    }
}

public struct NodeRegistry: Sendable {
    public private(set) var nodes: [String: DiscoveredNode] = [:]
    public var staleAfter: TimeInterval = 10
    public var forgetAfter: TimeInterval = 90

    public init() {}

    @discardableResult
    public mutating func ingest(_ reply: ArtPollReply, from sender: IPv4Address, at now: TimeInterval) -> DiscoveredNode {
        let identity = reply.macString.map { "mac:" + $0 } ?? "ip:" + sender.description
        var node = nodes[identity] ?? DiscoveredNode(
            id: identity, ip: sender, reportedIP: reply.ip, shortName: "", longName: "", nodeReport: "",
            mac: reply.macString, estaManufacturer: 0, oem: 0, firmwareVersion: 0,
            portsByBind: [:], lastSeen: now, isEnttec: false)
        node.ip = sender
        node.reportedIP = reply.ip
        node.shortName = reply.shortName
        node.longName = reply.longName
        node.nodeReport = reply.nodeReport
        node.estaManufacturer = reply.estaManufacturer
        node.oem = reply.oem
        node.firmwareVersion = reply.firmwareVersion
        node.portsByBind[reply.bindIndex] = reply.outputPorts.map(\.portAddress)
        node.lastSeen = now
        node.isStale = false
        node.isEnttec = EnttecMatcher.matches(esta: reply.estaManufacturer, shortName: reply.shortName, longName: reply.longName)
        // An IP-keyed entry for a node that now reports a MAC is superseded.
        if identity.hasPrefix("mac:") { nodes.removeValue(forKey: "ip:" + sender.description) }
        nodes[identity] = node
        return node
    }

    /// Marks stale nodes and forgets very old ones (except `keeping`).
    public mutating func refresh(now: TimeInterval, keeping: String?) {
        for (key, var node) in nodes {
            let age = now - node.lastSeen
            if age > forgetAfter && key != keeping {
                nodes.removeValue(forKey: key)
            } else {
                node.isStale = age > staleAfter
                nodes[key] = node
            }
        }
    }

    public func node(id: String?) -> DiscoveredNode? { id.flatMap { nodes[$0] } }

    public func node(at ip: IPv4Address) -> DiscoveredNode? { nodes.values.first { $0.ip == ip } }

    public var sortedNodes: [DiscoveredNode] {
        nodes.values.sorted { ($0.isEnttec ? 0 : 1, $0.ip) < ($1.isEnttec ? 0 : 1, $1.ip) }
    }

    /// Auto-selection is only allowed when exactly one fresh ENTTEC device is visible.
    /// Generic Art-Net nodes are never auto-selected.
    public func autoSelectCandidate(now: TimeInterval) -> DiscoveredNode? {
        let candidates = nodes.values.filter { $0.isEnttec && now - $0.lastSeen <= staleAfter }
        return candidates.count == 1 ? candidates.first : nil
    }
}
