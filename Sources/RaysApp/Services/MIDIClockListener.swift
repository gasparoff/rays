import CoreMIDI
import Darwin
import Foundation
import RaysTempo

/// Listens to MIDI beat clock on every MIDI input (only when the beat source is "MIDI Clock").
/// Beats are passed on like Pro DJ Link beats: into the Ableton Link timeline.
@MainActor
final class MIDIClockListener: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastBPM: Double?
    @Published private(set) var lastBeatTime: Date?
    @Published private(set) var sourceNames: [String] = []
    @Published private(set) var error: String?

    /// Called on the main thread for every quarter note while the clock is running.
    var onBeat: ((Double, Int) -> Void)?
    let source = MIDIClockTempoSource()
    var isLive: Bool { lastBeatTime.map { Date().timeIntervalSince($0) < 2 } ?? false }

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []

    func start() {
        guard client == 0 else { return }
        let status = MIDIClientCreateWithBlock("RAYS MIDI Clock" as CFString, &client) { [weak self] n in
            guard n.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.rescan() }
        }
        guard status == noErr else { error = String(localized: "CoreMIDI unavailable (\(String(describing: status)))."); return }
        let clock = source
        let portStatus = MIDIInputPortCreateWithProtocol(client, "Clock in" as CFString, ._1_0, &port) { [weak self] list, _ in
            for (bytes, time) in Self.realtime(from: list) {
                let events = clock.receive(bytes, at: time)
                guard !events.isEmpty else { continue }
                DispatchQueue.main.async { self?.handle(events) }
            }
        }
        guard portStatus == noErr else { error = String(localized: "MIDI port unavailable (\(String(describing: portStatus)))."); return }
        error = nil
        rescan()
    }

    func stop() {
        for s in connected { MIDIPortDisconnectSource(port, s) }
        connected.removeAll()
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        isRunning = false
        lastBeatTime = nil
    }

    func rescan() {
        guard port != 0 else { return }
        var wanted: Set<MIDIEndpointRef> = []
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            wanted.insert(s)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(s, kMIDIPropertyDisplayName, &name)
            names.append((name?.takeRetainedValue() as String?) ?? "MIDI")
        }
        for s in wanted.subtracting(connected) { MIDIPortConnectSource(port, s, nil) }
        for s in connected.subtracting(wanted) { MIDIPortDisconnectSource(port, s) }
        connected = wanted
        sourceNames = names.sorted()
    }

    private func handle(_ events: [MIDIClockParser.Event]) {
        for event in events {
            switch event {
            case .start: isRunning = true
            case .stop: isRunning = false
            case let .beat(bpm, beatInBar):
                isRunning = true
                lastBeatTime = Date()
                if let bpm {
                    lastBPM = bpm
                    onBeat?(bpm, beatInBar)
                }
            }
        }
    }

    /// System real-time / common bytes (clock, start, continue, stop, song position) per packet,
    /// timed by the packet's host timestamp (systemUptime seconds).
    private nonisolated static func realtime(from list: UnsafePointer<MIDIEventList>) -> [([UInt8], TimeInterval)] {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let now = ProcessInfo.processInfo.systemUptime
        var out: [([UInt8], TimeInterval)] = []
        for packet in list.unsafeSequence() {
            var bytes: [UInt8] = []
            for word in MIDIEventPacket.WordCollection(packet) where word >> 28 == 0x1 {   // UMP type 1: system
                let status = UInt8((word >> 16) & 0xFF)
                bytes.append(status)
                if status == 0xF2 { bytes += [UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)] }
            }
            guard !bytes.isEmpty else { continue }
            let stamp = packet.pointee.timeStamp
            let t = stamp == 0 ? now : Double(stamp) * Double(info.numer) / Double(info.denom) / 1e9
            out.append((bytes, t))
        }
        return out
    }
}
