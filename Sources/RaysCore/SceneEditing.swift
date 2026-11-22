import Foundation

// Deterministic scene-editor operations: undo/redo history, mapping the rhythm grid onto a shared
// beat axis, step painting and envelope handles. Foundation only: no effect on the engine, the
// saved format or the presets.

// MARK: - Undo history

/// Bounded undo/redo of whole editor states. Continuous edits with the same key (a slider drag,
/// typing a name, one paint stroke) collapse into one step while they keep arriving within `coalesceWindow`.
public struct EditHistory<State: Equatable> {
    public let limit: Int
    public let coalesceWindow: TimeInterval
    public private(set) var undoStack: [State] = []
    public private(set) var redoStack: [State] = []
    private var lastKey: String?
    private var lastTime: TimeInterval = -.infinity

    public init(limit: Int = 100, coalesceWindow: TimeInterval = 1) {
        self.limit = max(1, limit)
        self.coalesceWindow = coalesceWindow
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Call with the state *before* a change. `key` nil = never merged with the previous step.
    public mutating func record(_ before: State, key: String?, at time: TimeInterval) {
        defer { lastKey = key; lastTime = time }
        redoStack.removeAll()
        if let key, key == lastKey, time - lastTime <= coalesceWindow, time >= lastTime, !undoStack.isEmpty { return }
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    }

    /// The next edit starts a new step even if it has the same key.
    public mutating func breakCoalescing() { lastKey = nil }

    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        if redoStack.count > limit { redoStack.removeFirst(redoStack.count - limit) }
        lastKey = nil
        return previous
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        lastKey = nil
        return next
    }
}

// MARK: - Shared rhythm timeline

/// Common beat axis for tracks with different resolutions and cycles. Every visible cell keeps the
/// index of the step it repeats, so editing any repetition edits the one stored step.
public struct RhythmViewport: Equatable, Sendable {
    /// Selectable visible spans in beats (1, 2 and 4 bars).
    public static let spans = [4, 8, 16]

    /// First visible beat (multiple of `span`) and number of visible beats.
    public private(set) var start: Int
    public private(set) var span: Int
    /// Length of the whole timeline: the longest cycle, at least one bar.
    public private(set) var total: Int

    public init(start: Int = 0, span: Int = 4, total: Int = 4) {
        self.start = 0; self.span = 4; self.total = 4
        update(total: total, span: span, start: start)
    }

    /// Timeline length for a set of tracks (cycles are 1…16 beats, so the longest is a multiple of all).
    public static func totalBeats(_ tracks: [ProgramTrack]) -> Int {
        max(4, tracks.map { $0.sanitized.lengthBeats }.max() ?? 4)
    }

    public var spanChoices: [Int] { Self.spans.filter { $0 <= max(4, total) } }
    public var pageCount: Int { max(1, (total + span - 1) / span) }
    public var page: Int { start / max(1, span) }
    public var end: Int { start + span }

    /// Keeps the span among the choices and the start on a whole page inside the timeline.
    public mutating func update(total newTotal: Int? = nil, span newSpan: Int? = nil, start newStart: Int? = nil) {
        total = max(4, newTotal ?? total)
        let wanted = newSpan ?? span
        span = Self.spans.last { $0 <= min(wanted, total) } ?? 4
        let s = max(0, newStart ?? start)
        let lastPage = max(0, pageCount - 1)
        start = min(s / span, lastPage) * span
    }

    public mutating func showPage(_ page: Int) { update(start: page * span) }

    /// One visible step cell of the rhythm grid.
    public struct Cell: Equatable, Sendable {
        /// Index into `ProgramTrack.steps`.
        public var source: Int
        /// 0 for the first pass through the cycle, then 1, 2… for repeats.
        public var repetition: Int
        /// Position and width in beats on the common axis.
        public var beat: Double
        public var width: Double
        /// True on the first step of a beat.
        public var onBeat: Bool
    }

    /// Visible cells of a track: `span × stepsPerBeat` cells, each mapped back to its stored step.
    public func cells(stepsPerBeat: Int, lengthBeats: Int) -> [Cell] {
        let res = max(1, stepsPerBeat)
        let count = max(1, res * max(1, lengthBeats))
        let first = start * res
        return (0..<(span * res)).map { k in
            let g = first + k
            return Cell(
                source: g % count, repetition: g / count, beat: Double(g) / Double(res),
                width: 1 / Double(res), onBeat: g % res == 0)
        }
    }

    /// Stored step under a horizontal position (0…1 across the visible span), nil outside.
    public func sourceStep(atFraction x: Double, stepsPerBeat: Int, lengthBeats: Int) -> Int? {
        guard x.isFinite, x >= 0, x < 1 else { return nil }
        let res = max(1, stepsPerBeat)
        let count = max(1, res * max(1, lengthBeats))
        let g = start * res + Int((x * Double(span * res)).rounded(.down))
        return g % count
    }

    /// Fraction (0…1) of the visible span where pattern time `beat` falls, nil when it is on another page.
    public func playheadFraction(patternBeat beat: Double?) -> Double? {
        guard let beat, beat.isFinite, total > 0 else { return nil }
        var t = beat.truncatingRemainder(dividingBy: Double(total))
        if t < 0 { t += Double(total) }
        guard t >= Double(start), t < Double(end) else { return nil }
        return (t - Double(start)) / Double(span)
    }
}

// MARK: - Step painting

/// Click cycles a step strong → soft → off; a drag paints the value chosen on its first cell.
public enum StepPaint {
    public static let strong = 1.0
    public static let soft = 0.5

    public static func next(after value: Double) -> Double {
        value <= 0 ? strong : (value >= 0.999 ? soft : 0)
    }

    /// One stroke: the first cell is cycled, every other cell receives that same value.
    public struct Stroke: Equatable, Sendable {
        public let value: Double
        public private(set) var touched: Set<Int>

        public init(first step: Int, current: Double) {
            value = StepPaint.next(after: current)
            touched = [step]
        }

        /// Applies the stroke value to `step`; returns false when nothing changes.
        public mutating func paint(_ step: Int, in steps: inout [Double]) -> Bool {
            guard steps.indices.contains(step) else { return false }
            touched.insert(step)
            guard steps[step] != value else { return false }
            steps[step] = value
            return true
        }
    }
}

// MARK: - Hit envelope

/// Quick shapes for one hit. They only change attack, hold and release; floor, peak and colour stay.
public enum HitShapePreset: String, CaseIterable, Identifiable, Sendable {
    case dry, soft, long
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dry: return "Secco"
        case .soft: return "Morbido"
        case .long: return "Lungo"
        }
    }

    public var times: (attack: Double, hold: Double, release: Double) {
        switch self {
        case .dry: return (0.02, 0, 0.25)
        case .soft: return (0.1, 0.08, 0.5)
        case .long: return (0.25, 0.25, 2)
        }
    }

    public func apply(to track: ProgramTrack) -> ProgramTrack {
        var t = track
        (t.attack, t.hold, t.release) = times
        return t.sanitized
    }

    /// The preset whose times the track uses exactly (to the hundredth of a beat), if any.
    public static func matching(_ track: ProgramTrack) -> HitShapePreset? {
        allCases.first { p in
            let x = p.times
            return abs(track.attack - x.attack) < 0.005 && abs(track.hold - x.hold) < 0.005 && abs(track.release - x.release) < 0.005
        }
    }
}

/// Draggable points of the envelope drawing. Time is in beats from the hit (negative = before it).
public enum EnvelopeHandle: String, CaseIterable, Sendable {
    /// Start of the attack, at floor level: moves attack (earlier = longer) and floor.
    case attackStart
    /// The hit itself: fixed in time, moves the peak.
    case hit
    /// End of the hold plateau: moves hold and peak.
    case holdEnd
    /// End of the release, back at floor: moves release and floor.
    case releaseEnd

    public func position(of t: ProgramTrack) -> (time: Double, level: Double) {
        switch self {
        case .attackStart: return (-t.attack, t.floor)
        case .hit: return (0, t.peak)
        case .holdEnd: return (t.hold, t.peak)
        case .releaseEnd: return (t.hold + t.release, t.floor)
        }
    }

    /// New track after dragging this handle to (time, level). Values are rounded to 0.01 and kept
    /// inside the model bounds; the floor never rises above the peak.
    public func drag(_ track: ProgramTrack, time: Double, level: Double) -> ProgramTrack {
        var t = track.sanitized
        let lvl = round2(clamp(level, 0, 1))
        switch self {
        case .attackStart:
            t.attack = round2(clamp(-time, 0, ProgramTrack.maxAttack))
            t.floor = min(lvl, t.peak)
        case .hit:
            t.peak = lvl
            t.floor = min(t.floor, t.peak)
        case .holdEnd:
            t.hold = round2(clamp(time, 0, ProgramTrack.maxHold))
            t.peak = lvl
            t.floor = min(t.floor, t.peak)
        case .releaseEnd:
            t.release = round2(clamp(time - t.hold, 0, ProgramTrack.maxRelease))
            t.floor = min(lvl, t.peak)
        }
        return t.sanitized
    }
}

extension ProgramTrack {
    /// Sets the floor, kept at or below the peak.
    public func withFloor(_ value: Double) -> ProgramTrack {
        var t = self
        t.floor = min(clamp(value, 0, 1), clamp(peak, 0, 1))
        return t.sanitized
    }

    /// Sets the peak; a floor above it comes down with it.
    public func withPeak(_ value: Double) -> ProgramTrack {
        var t = self
        t.peak = clamp(value, 0, 1)
        t.floor = min(t.floor, t.peak)
        return t.sanitized
    }
}

@inline(__always) private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    x.isFinite ? min(hi, max(lo, x)) : lo
}

@inline(__always) private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
