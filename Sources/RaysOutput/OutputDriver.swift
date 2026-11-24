import Foundation

/// A DMX output protocol: Art-Net, sACN and DMX USB Pro today, others can be added as new drivers.
///
/// The engine calls every member from its single serial queue, so drivers do not need to be
/// thread-safe towards the engine; work a driver moves off that queue (a serial writer, a
/// socket callback) is the driver's own business and must not block the caller.
///
/// A new driver implements only the core: `driverID`, `isOpen`, `open`, `close`, `target`,
/// `sendDMX`, `socketError`, `sendError` and `diagnosis`. Discovery and node selection
/// (`pollIfDue`, `nodes`, `preferredIdentity`, `manualIP`, `select`…) are requirements too, so the
/// engine always reaches a driver's own implementation, but they have defaults below for drivers
/// without devices to discover. See docs/adding-an-output.md.
public protocol OutputDriver: AnyObject {
    // MARK: Core (no default)

    /// Stable identifier, used to pick the driver from an `OutputDriverRegistry`.
    var driverID: String { get }
    var isOpen: Bool { get }
    func open(queue: DispatchQueue, now: @escaping () -> TimeInterval)
    func close()
    /// Where frames go now, or nil when there is nowhere to send (output stays off).
    func target(now: TimeInterval, patchUniverses: [PortAddress]) -> OutputTarget?
    /// Sends one frame per universe; returns true when every frame was accepted. Must not block.
    @discardableResult
    func sendDMX(_ frames: [PortAddress: [UInt8]], to target: OutputTarget) -> Bool
    /// Why the driver could not open, shown in Setup.
    var socketError: String? { get }
    /// Why the last frame could not be sent, shown in Setup.
    var sendError: String? { get }
    /// Hints for Setup, most important first.
    func diagnosis(now: TimeInterval) -> [String]

    // MARK: Optional (defaults in the extension below)

    /// How long the engine waits before trying to reopen a closed driver. Default: 2 s.
    var reopenInterval: TimeInterval { get }
    /// Discovery: called every frame; the driver decides when to actually poll. Default: nothing.
    func pollIfDue(now: TimeInterval)
    /// Discovery right now (Setup's refresh button, after opening). Default: nothing.
    func forcePoll(now: TimeInterval)
    /// Devices found by discovery. Default: none.
    func nodes(now: TimeInterval) -> [DiscoveredNode]
    /// Identity of the node chosen by the user or auto-selected (persisted by the app).
    /// Default: always nil, writes are ignored.
    var preferredIdentity: String? { get set }
    /// Manual IPv4 fallback; unverified until that address answers discovery.
    /// Default: always nil, writes are ignored.
    var manualIP: IPv4Address? { get set }
    /// Called when the driver itself changes `preferredIdentity` (auto-selection).
    /// Default: never called, writes are ignored.
    var onPreferredIdentityChanged: ((String?) -> Void)? { get set }
    /// The user picked a node in Setup. Default: nothing.
    func select(identity: String?)
    /// Local networks the driver sends on, shown in Setup. Default: none.
    var interfaces: [NetworkInterface] { get }
    /// Why discovery failed, shown in Setup. Default: nil.
    var pollError: String? { get }
}

/// Defaults for drivers without discovery or node selection. Each of these is a protocol
/// requirement, so a driver that declares its own version (with a public setter for the settable
/// ones) replaces the default even when the engine calls it through `OutputDriver`.
extension OutputDriver {
    public var reopenInterval: TimeInterval { 2 }
    public func pollIfDue(now: TimeInterval) {}
    public func forcePoll(now: TimeInterval) {}
    public func nodes(now: TimeInterval) -> [DiscoveredNode] { [] }
    public var preferredIdentity: String? {
        get { nil }
        set {}
    }
    public var manualIP: IPv4Address? {
        get { nil }
        set {}
    }
    public var onPreferredIdentityChanged: ((String?) -> Void)? {
        get { nil }
        set {}
    }
    public func select(identity: String?) {}
    public var interfaces: [NetworkInterface] { [] }
    public var pollError: String? { nil }
}

/// Builds output drivers by identifier. Start from `.builtIn` and `register` new drivers.
public struct OutputDriverRegistry {
    /// Builds a driver for the engine's transport and interface list.
    public typealias Factory = (
        _ transport: DatagramTransport,
        _ interfaces: @escaping () -> [NetworkInterface]
    ) -> OutputDriver

    /// A driver the registry can build.
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
        registry.register(
            Descriptor(id: ArtNetController.driverID, name: "Art-Net") { transport, interfaces in
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
    public func make(
        id: String = defaultDriverID, transport: DatagramTransport,
        interfaces: @escaping () -> [NetworkInterface]
    ) -> OutputDriver {
        let d = descriptor(id: id) ?? descriptor(id: Self.defaultDriverID)
        return d?.make(transport, interfaces) ?? ArtNetController(transport: transport, interfaces: interfaces)
    }
}

extension ArtNetController: OutputDriver {
    public static let driverID = "artnet"
    public var driverID: String { Self.driverID }
    public var reopenInterval: TimeInterval { Self.pollInterval }
}
