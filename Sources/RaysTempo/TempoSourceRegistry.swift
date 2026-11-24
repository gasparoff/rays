import Foundation

/// Builds tempo sources by identifier. Start from `.builtIn` (internal clock) and `register`
/// sources that live in other modules, such as Ableton Link in the app target.
///
/// Pro DJ Link is not a `TempoSource`: console beats are fed into the Link timeline
/// (`LinkTempoSource.followBeat`), so the lights, Live and other Link peers share one grid.
public struct TempoSourceRegistry: Sendable {
    /// Builds a source starting at the given tempo. `@Sendable`, so descriptors can be shared
    /// constants (`MIDIClockTempoSource.descriptor`).
    public typealias Factory = @Sendable (_ initialBPM: Double) -> TempoSource

    /// A tempo source the registry can build.
    public struct Descriptor: Sendable {
        public var id: String
        public var name: String
        public var make: Factory
        public init(id: String, name: String, make: @escaping Factory) {
            self.id = id; self.name = name; self.make = make
        }
    }

    public static let internalClockID = "internal"

    public private(set) var descriptors: [Descriptor] = []

    public init() {}

    /// Internal free-running clock only.
    public static var builtIn: TempoSourceRegistry {
        var registry = TempoSourceRegistry()
        registry.register(Descriptor(id: internalClockID, name: "Clock interno") { LocalTempoClock(bpm: $0) })
        return registry
    }

    /// Adds a source, replacing any existing one with the same id.
    public mutating func register(_ descriptor: Descriptor) {
        descriptors.removeAll { $0.id == descriptor.id }
        descriptors.append(descriptor)
    }

    public func descriptor(id: String) -> Descriptor? { descriptors.first { $0.id == id } }

    /// The requested source, or the internal clock when that id is unknown.
    public func make(id: String, bpm: Double) -> TempoSource {
        (descriptor(id: id) ?? descriptor(id: Self.internalClockID))?.make(bpm) ?? LocalTempoClock(bpm: bpm)
    }
}
