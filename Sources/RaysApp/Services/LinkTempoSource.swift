import Foundation
import LinkBridge
import RaysTempo

/// TempoSource backed by the real Ableton Link SDK (via LinkBridge).
/// Link is enabled automatically; with zero peers its timeline runs locally and the UI says so.
/// Tempo is only committed on explicit user action (tap / ± / field).
final class LinkTempoSource: TempoSource, @unchecked Sendable {
    private let lock = NSLock()
    private var lastExternalBeat: TimeInterval = -.infinity
    private var link: OpaquePointer?
    private let fallback: LocalTempoClock
    static let quantum = 4.0
    static let sourceID = "link"
    static let descriptor = TempoSourceRegistry.Descriptor(id: sourceID, name: "Ableton Link") { LinkTempoSource(bpm: $0) }

    init(bpm: Double = 120) {
        let initialBPM = TempoRange.clamp(bpm)
        fallback = LocalTempoClock(bpm: initialBPM)
        link = ls_link_create(initialBPM)
        if let link { ls_link_set_enabled(link, true) }
    }

    var isAvailable: Bool { lock.lock(); defer { lock.unlock() }; return link != nil }

    func capture() -> TempoSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard let link else { return fallback.capture() }
        let s = ls_link_capture(link, Self.quantum)
        return TempoSnapshot(bpm: s.tempo, beat: s.beat, phase: s.phase, isPlaying: s.isPlaying,
                             peers: Int(s.numPeers), kind: .link, linkEnabled: s.isEnabled,
                             startStopSync: s.isStartStopSyncEnabled,
                             externalClock: ProcessInfo.processInfo.systemUptime - lastExternalBeat < 2)
    }

    func setTempo(_ bpm: Double) {
        lock.lock(); defer { lock.unlock() }
        let clamped = TempoRange.clamp(bpm)
        if let link { ls_link_set_tempo(link, clamped) } else { fallback.setTempo(clamped) }
    }

    /// Feeds one validated console-master beat into the real Link session (`beatInBar` 1...4).
    func followBeat(bpm: Double, beatInBar: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let link, bpm.isFinite, (20...400).contains(bpm), (1...4).contains(beatInBar) else { return }
        lastExternalBeat = ProcessInfo.processInfo.systemUptime
        ls_link_follow_beat(link, TempoRange.clamp(bpm), Int32(beatInBar - 1))
    }

    func setStartStopSync(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let link { ls_link_set_start_stop_sync(link, enabled) }
    }

    /// Call after the engine is stopped.
    func clearExternalClock() {
        lock.lock(); defer { lock.unlock() }
        lastExternalBeat = -.infinity
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let link { ls_link_destroy(link) }
        link = nil
    }
}
