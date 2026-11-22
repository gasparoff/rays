import Foundation

/// MIDI beat clock (MIDI 1.0 System Real-Time): 24 Timing Clock (0xF8) per quarter note,
/// Start (0xFA), Continue (0xFB), Stop (0xFC) and Song Position Pointer (0xF2, in 16ths).
/// Pure, so it is testable without hardware. Beats are only reported while running
/// (after Start, Continue or a Song Position Pointer), because only then is the bar known.
public struct MIDIClockParser: Sendable {
    /// Something the clock reported.
    public enum Event: Equatable, Sendable {
        case start
        case stop
        /// A quarter note. `beatInBar` is 1...4 counted from Start / the song position.
        case beat(bpm: Double?, beatInBar: Int)
    }

    public static let ticksPerBeat = 24
    /// Ticks averaged for the tempo (one beat): smooths USB/MIDI jitter.
    public static let window = 24
    /// A gap longer than this restarts tempo estimation.
    public static let maxTickGap: TimeInterval = 0.5

    public private(set) var running = false
    /// Ticks since Start (or the song position).
    public private(set) var ticks = 0
    public private(set) var lastTick: TimeInterval?
    private var times: [TimeInterval] = []
    private var pending: [UInt8] = []
    private var pendingStatus: UInt8 = 0

    public init() {}

    /// Estimated tempo from the recent ticks, nil until enough ticks arrived.
    public var bpm: Double? {
        guard times.count >= 7, let first = times.first, let last = times.last, last > first else { return nil }
        let perTick = (last - first) / Double(times.count - 1)
        let bpm = 60 / (perTick * Double(Self.ticksPerBeat))
        return bpm.isFinite && (20...400).contains(bpm) ? bpm : nil
    }

    public mutating func receive(_ bytes: [UInt8], at time: TimeInterval) -> [Event] {
        var out: [Event] = []
        for byte in bytes {
            switch byte {
            case 0xF8: out += tick(at: time)
            case 0xFA: running = true; ticks = 0; out.append(.start)
            case 0xFB: running = true
            case 0xFC: if running { running = false; out.append(.stop) }
            case 0xF2: pendingStatus = 0xF2; pending.removeAll()
            case 0x80...0xFF:
                if byte < 0xF8 { pendingStatus = 0; pending.removeAll() }   // other status: drop SPP state
            default:
                guard pendingStatus == 0xF2 else { continue }
                pending.append(byte)
                if pending.count == 2 {
                    let sixteenths = Int(pending[0]) | Int(pending[1]) << 7
                    ticks = sixteenths * 6
                    running = true
                    pendingStatus = 0; pending.removeAll()
                }
            }
        }
        return out
    }

    private mutating func tick(at time: TimeInterval) -> [Event] {
        if let last = lastTick, time - last > Self.maxTickGap || time < last { times.removeAll() }
        lastTick = time
        times.append(time)
        if times.count > Self.window + 1 { times.removeFirst(times.count - Self.window - 1) }
        guard running else { return [] }
        defer { ticks += 1 }
        guard ticks % Self.ticksPerBeat == 0 else { return [] }
        return [.beat(bpm: bpm, beatInBar: (ticks / Self.ticksPerBeat) % 4 + 1)]
    }
}

/// TempoSource following an external MIDI clock. Feed it with `receive(_:at:)` from any
/// thread. Between ticks the beat is extrapolated by at most one tick.
public final class MIDIClockTempoSource: TempoSource, @unchecked Sendable {
    public static let sourceID = "midiclock"
    private let lock = NSLock()
    private var parser = MIDIClockParser()
    private var fallbackBPM: Double
    private let now: () -> TimeInterval

    public init(bpm: Double = 120, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fallbackBPM = TempoRange.clamp(bpm)
        self.now = now
    }

    @discardableResult
    public func receive(_ bytes: [UInt8], at time: TimeInterval) -> [MIDIClockParser.Event] {
        lock.lock(); defer { lock.unlock() }
        return parser.receive(bytes, at: time)
    }

    public func capture() -> TempoSnapshot {
        lock.lock(); defer { lock.unlock() }
        let bpm = parser.bpm ?? fallbackBPM
        let fresh = parser.lastTick.map { now() - $0 <= MIDIClockParser.maxTickGap } ?? false
        var beat = Double(max(parser.ticks - 1, 0)) / Double(MIDIClockParser.ticksPerBeat)
        if fresh, parser.running, let last = parser.lastTick {
            beat += min(max(0, now() - last) * bpm / 60, 1 / Double(MIDIClockParser.ticksPerBeat))
        }
        return TempoSnapshot(bpm: bpm, beat: beat, phase: pmod(beat, 4), isPlaying: parser.running && fresh,
                             kind: .midiClock, externalClock: parser.running && fresh)
    }

    /// The clock owns the tempo; a manual change only sets the value used before ticks arrive.
    public func setTempo(_ bpm: Double) {
        lock.lock(); defer { lock.unlock() }
        fallbackBPM = TempoRange.clamp(bpm)
    }

    public func setStartStopSync(_ enabled: Bool) {}

    public static let descriptor = TempoSourceRegistry.Descriptor(id: sourceID, name: "MIDI Clock") { MIDIClockTempoSource(bpm: $0) }
}
