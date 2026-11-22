import Foundation

public enum TempoSourceKind: String, Sendable {
    case link
    case local
}

public struct TempoSnapshot: Equatable, Sendable {
    public var bpm: Double
    /// Beat on the Link timeline (may be negative right after session start).
    public var beat: Double
    /// Phase within a 4-beat bar, 0..<4.
    public var phase: Double
    public var isPlaying: Bool
    public var peers: Int
    public var kind: TempoSourceKind
    public var linkEnabled: Bool
    public var startStopSync: Bool
    /// A fresh, playing external console clock is feeding the Link timeline.
    public var externalClock: Bool

    public init(bpm: Double, beat: Double, phase: Double, isPlaying: Bool = false, peers: Int = 0,
                kind: TempoSourceKind = .local, linkEnabled: Bool = false, startStopSync: Bool = false, externalClock: Bool = false) {
        self.bpm = bpm; self.beat = beat; self.phase = phase; self.isPlaying = isPlaying; self.peers = peers
        self.kind = kind; self.linkEnabled = linkEnabled; self.startStopSync = startStopSync; self.externalClock = externalClock
    }
}

public protocol TempoSource: AnyObject {
    func capture() -> TempoSnapshot
    /// Explicit user tempo change (tap / manual). Never called automatically.
    func setTempo(_ bpm: Double)
    func setStartStopSync(_ enabled: Bool)
}

/// A local phase correction for the lighting grid. The source keeps ownership of BPM and timing;
/// aligning the lights never commits a phase change to the shared Link session or console.
public final class DownbeatTempoSource: TempoSource, @unchecked Sendable {
    private let source: TempoSource
    private let lock = NSLock()
    private var offset = 0.0

    public init(source: TempoSource) { self.source = source }

    /// Capture on the caller's press, rather than at the next 30 Hz lighting frame.
    @discardableResult
    public func setDownbeat() -> Double? {
        lock.lock(); defer { lock.unlock() }
        let beat = source.capture().beat
        guard beat.isFinite else { return nil }
        let aligned = (beat / 4).rounded() * 4
        offset = aligned - beat
        return aligned
    }

    public func capture() -> TempoSnapshot {
        lock.lock(); defer { lock.unlock() }
        var snapshot = source.capture()
        snapshot.beat += offset
        snapshot.phase = pmod(snapshot.beat, 4)
        return snapshot
    }

    public func setTempo(_ bpm: Double) { source.setTempo(bpm) }
    public func setStartStopSync(_ enabled: Bool) { source.setStartStopSync(enabled) }
}

public enum TempoRange {
    public static let bpm: ClosedRange<Double> = 20...999
    public static func clamp(_ bpm: Double) -> Double {
        bpm.isFinite ? min(max(bpm, Self.bpm.lowerBound), Self.bpm.upperBound) : 120
    }
}

/// Local free-running clock used when Link is unavailable, and in tests.
public final class LocalTempoClock: TempoSource, @unchecked Sendable {
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var bpm: Double
    private var anchorBeat: Double = 0
    private var anchorTime: TimeInterval

    public init(bpm: Double = 120, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.bpm = TempoRange.clamp(bpm)
        anchorTime = now()
    }

    public func capture() -> TempoSnapshot {
        lock.lock(); defer { lock.unlock() }
        let beat = anchorBeat + (now() - anchorTime) * bpm / 60
        return TempoSnapshot(bpm: bpm, beat: beat, phase: pmod(beat, 4), isPlaying: true, kind: .local)
    }

    public func setTempo(_ newBPM: Double) {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        anchorBeat += (t - anchorTime) * bpm / 60
        anchorTime = t
        bpm = TempoRange.clamp(newBPM)
    }

    public func setStartStopSync(_ enabled: Bool) {}
}

/// Tap tempo: averages the last taps; a pause longer than `resetAfter` starts over.
public struct TapTempo: Sendable {
    public var resetAfter: TimeInterval = 2
    public var maxTaps = 8
    private var taps: [TimeInterval] = []

    public init() {}

    public var tapCount: Int { taps.count }

    public mutating func tap(at time: TimeInterval) -> Double? {
        if let last = taps.last, time - last > resetAfter || time <= last { taps.removeAll() }
        taps.append(time)
        if taps.count > maxTaps { taps.removeFirst(taps.count - maxTaps) }
        guard taps.count >= 2, let first = taps.first, let last = taps.last else { return nil }
        let interval = (last - first) / Double(taps.count - 1)
        guard interval > 0 else { return nil }
        return TempoRange.clamp(60 / interval)
    }
}

/// Positive modulo, finite-safe (same definition as in RaysCore, kept private to avoid a dependency).
@inline(__always) private func pmod(_ a: Double, _ m: Double) -> Double {
    guard a.isFinite, m > 0 else { return 0 }
    let r = a.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
}
