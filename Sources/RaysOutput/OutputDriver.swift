import Foundation

/// A network DMX output protocol (Art-Net today; sACN or others can be added as new drivers).
///
/// The engine calls every method from its single serial queue, so drivers do not need to be
/// thread-safe. A driver owns discovery of its devices and the choice of the active target.
public protocol OutputDriver: AnyObject {
    /// Stable identifier, used to pick the driver from an `OutputDriverRegistry`.
    var driverID: String { get }
    /// How long the engine waits before trying to reopen a closed driver.
    var reopenInterval: TimeInterval { get }

    var isOpen: Bool { get }
    func open(queue: DispatchQueue, now: @escaping () -> TimeInterval)
    func close()

    /// Discovery: called every frame; the driver decides when to actually poll.
    func pollIfDue(now: TimeInterval)
    func forcePoll(now: TimeInterval)
    func nodes(now: TimeInterval) -> [DiscoveredNode]

    /// Identity of the node chosen by the user or auto-selected (persisted by the app).
    var preferredIdentity: String? { get set }
    /// Manual IPv4 fallback; unverified until that address answers discovery.
    var manualIP: IPv4Address? { get set }
    var onPreferredIdentityChanged: ((String?) -> Void)? { get set }
    func select(identity: String?)

    func target(now: TimeInterval, patchUniverses: [PortAddress]) -> OutputTarget?
    /// Sends one frame per universe; returns true when every packet was written.
    @discardableResult
    func sendDMX(_ frames: [PortAddress: [UInt8]], to target: OutputTarget) -> Bool

    // Status shown in Setup.
    var interfaces: [NetworkInterface] { get }
    var socketError: String? { get }
    var pollError: String? { get }
    var sendError: String? { get }
    func diagnosis(now: TimeInterval) -> [String]
}

/// Builds output drivers by identifier. Start from `.builtIn` and `register` new drivers.
public struct OutputDriverRegistry {
    public typealias Factory = (_ transport: DatagramTransport,
                                _ interfaces: @escaping () -> [NetworkInterface]) -> OutputDriver

    public struct Descriptor {
        public var id: String
        public var name: String
        public var make: Factory
        public init(id: String, name: String, make: @escaping Factory) {
            self.id = id; self.name = name; self.make = make
        }
    }

    public private(set) var descriptors: [Descriptor] = []
    public static let defaultDriverID = ArtNetController.driverID

    public init() {}

    /// Art-Net only.
    public static var builtIn: OutputDriverRegistry {
        var registry = OutputDriverRegistry()
        registry.register(Descriptor(id: ArtNetController.driverID, name: "Art-Net") { transport, interfaces in
            ArtNetController(transport: transport, interfaces: interfaces)
        })
        return registry
    }

    /// Adds a driver, replacing any existing one with the same id.
    public mutating func register(_ descriptor: Descriptor) {
        descriptors.removeAll { $0.id == descriptor.id }
        descriptors.append(descriptor)
    }

    public func descriptor(id: String) -> Descriptor? { descriptors.first { $0.id == id } }

    /// The requested driver, or Art-Net when that id is unknown.
    public func make(id: String = defaultDriverID, transport: DatagramTransport,
                     interfaces: @escaping () -> [NetworkInterface]) -> OutputDriver {
        let d = descriptor(id: id) ?? descriptor(id: Self.defaultDriverID)
        return d?.make(transport, interfaces) ?? ArtNetController(transport: transport, interfaces: interfaces)
    }
}

extension ArtNetController: OutputDriver {
    public static let driverID = "artnet"
    public var driverID: String { Self.driverID }
    public var reopenInterval: TimeInterval { Self.pollInterval }
}
