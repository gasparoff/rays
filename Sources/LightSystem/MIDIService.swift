import CoreMIDI
import Foundation
import LightCore

/// Native CoreMIDI input for the Xone K2. Only sources whose name contains "K2"
/// are connected; hot-plug re-scans automatically. Unlearned controls do nothing.
@MainActor
final class MIDIService: ObservableObject {
    @Published private(set) var connectedNames: [String] = []
    @Published private(set) var map: MIDIMap
    @Published private(set) var learning: ControlAction?
    @Published private(set) var lastLearned: String?
    @Published private(set) var error: String?

    var onCommand: ((MIDICommand) -> Void)?
    var currentValue: (ControlAction) -> Double = { _ in 0 }
    @Published private(set) var pickupMessage: String?
    private var outPort = MIDIPortRef()
    private var destinations: [MIDIEndpointRef] = []
    private var lastLEDs: [UInt8: XoneK2.LED] = [:]
    private var holdingBuild = false
    private var lastLEDChannel: UInt8?


    private var router: MIDIRouter
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []
    private let save: (MIDIMap) -> Void

    init(map: MIDIMap, save: @escaping (MIDIMap) -> Void) {
        self.map = map
        self.router = MIDIRouter(map: map)
        self.save = save
    }

    func start() {
        guard client == 0 else { return }
        let status = MIDIClientCreateWithBlock("Light System" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.rescan() }
        }
        guard status == noErr else { error = "CoreMIDI non disponibile (\(status))."; return }
        let portStatus = MIDIInputPortCreateWithProtocol(client, "K2 in" as CFString, ._1_0, &port) { [weak self] list, _ in
            let bytes = Self.bytes(from: list)
            guard !bytes.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(bytes) }
        }
        guard portStatus == noErr else { error = "Porta MIDI non disponibile (\(portStatus))."; return }
        MIDIOutputPortCreate(client, "K2 luci" as CFString, &outPort)
        rescan()
    }

    func rescan() {
        guard port != 0 else { return }
        var names: [String] = []
        var wanted: Set<MIDIEndpointRef> = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            let text = (name?.takeRetainedValue() as String?) ?? ""
            guard MIDIRouter.isK2(text) else { continue }
            wanted.insert(source)
            names.append(text)
        }
        for source in wanted.subtracting(connected) { MIDIPortConnectSource(port, source, nil) }
        for source in connected.subtracting(wanted) { MIDIPortDisconnectSource(port, source) }
        if connected != wanted {
            router.resetInputState()
            router.resetDetectedChannel()
            lastLEDs.removeAll()
            if wanted.isEmpty {
                onCommand?(.accent(false))
                if holdingBuild { onCommand?(.stop); holdingBuild = false }
            }
        }
        connected = wanted
        connectedNames = names.sorted()
        let nextDestinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination).filter { target in
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(target, kMIDIPropertyDisplayName, &name)
            return MIDIRouter.isK2((name?.takeRetainedValue() as String?) ?? "")
        }
        if destinations != nextDestinations { lastLEDs.removeAll() }
        destinations = nextDestinations
    }

    func learn(_ action: ControlAction?) {
        if action != nil { releaseForMappingChange() }
        router.learning = action
        learning = action
        lastLearned = nil
    }

    func unbind(_ action: ControlAction) {
        releaseForMappingChange()
        router.map.unbind(action)
        publishMap()
    }

    func setLayout(_ layout: XoneK2.Layout) {
        guard layout != router.map.k2Layout else { return }
        releaseForMappingChange()
        router.map.k2Layout = layout
        publishMap()
    }

    private func releaseForMappingChange() {
        if let channel = lastLEDChannel { clearLEDs(channel: channel) }
        lastLEDs.removeAll()
        router.resetInputState()
        router.learning = nil; learning = nil; lastLearned = nil
        onCommand?(.accent(false))
        // Reassigning a held Build must never turn its later release into an accidental Drop.
        if holdingBuild { holdingBuild = false; onCommand?(.stop) }
    }

    private func receive(_ bytes: [UInt8]) {
        for event in MIDIDecoder.decode(bytes) {
            switch router.handle(event, fromK2: true, current: currentValue) {
            case .none: break
            case let .learned(action, control):
                learning = nil
                lastLearned = "\(action.label) ← \(control.label)"
                publishMap()
            case let .command(command):
                pickupMessage = nil
                if case let .buildHold(held) = command { holdingBuild = held }
                onCommand?(command)
            case let .waiting(action, _):
                pickupMessage = "\(action.label): porta il fader al valore sullo schermo"
            }
        }
    }

    private func publishMap() {
        map = router.map
        save(router.map)
    }

    var channel: Int { Int(router.k2Channel) + 1 }
    func effectiveControl(_ action: ControlAction) -> MIDIControl? { router.map.k2Control(for: action, channel: router.k2Channel) }

    func resetTakeover(_ action: ControlAction? = nil) { router.resetTakeover(action) }

    func feedback(_ snapshot: EngineSnapshot, sceneInBank: Bool = true,
                  selectedBank: SceneBank = .house, playingBank: SceneBank? = nil) {
        guard !destinations.isEmpty, outPort != 0 else { return }
        var state = K2FeedbackState(scene: snapshot.scene)
        state.sceneInBank = sceneInBank
        state.selectedBank = selectedBank; state.playingBank = playingBank
        state.pendingSceneInBank = snapshot.pendingSceneBank == selectedBank
        state.pendingScene = snapshot.pendingScene
        state.stopped = snapshot.stopped; state.stopFading = snapshot.stopFading
        state.live = snapshot.isLive; state.armed = snapshot.armed
        state.subdivision = snapshot.subdivision; state.accent = snapshot.accentActive
        state.blackout = snapshot.blackout; state.blinkOn = snapshot.tempo.phase.truncatingRemainder(dividingBy: 1) < 0.5
        let channel = router.k2Channel
        let next = K2Feedback.leds(map: router.map, channel: channel, state: state)
        if lastLEDChannel != channel {
            if let old = lastLEDChannel { clearLEDs(channel: old) }
            lastLEDs.removeAll(); lastLEDChannel = channel
        }
        for base in Set(next.keys).union(lastLEDs.keys) where next[base] != lastLEDs[base] {
            for address in XoneK2.ledAddresses(base: base) { send([0x80 | channel, address, 0]) }
            if let note = next[base]?.note(base: base) { send([0x90 | channel, note, 127]) }
        }
        lastLEDs = next
    }

    func stop() {
        if let channel = lastLEDChannel { clearLEDs(channel: channel) }
        for source in connected { MIDIPortDisconnectSource(port, source) }
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if outPort != 0 { MIDIPortDispose(outPort); outPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        connected.removeAll(); destinations.removeAll()
    }

    private func clearLEDs(channel: UInt8) {
        for base in lastLEDs.keys { for address in XoneK2.ledAddresses(base: base) { send([0x80 | channel, address, 0]) } }
    }

    private func send(_ bytes: [UInt8]) {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let packet = MIDIPacketListInit(list)
        bytes.withUnsafeBufferPointer { buffer in
            _ = MIDIPacketListAdd(list, 1024, packet, 0, bytes.count, buffer.baseAddress!)
        }
        for destination in destinations { MIDISend(outPort, destination, list) }
    }

    /// Flattens MIDI 1.0 channel-voice UMP words back to classic status/data bytes.
    private nonisolated static func bytes(from list: UnsafePointer<MIDIEventList>) -> [UInt8] {
        var out: [UInt8] = []
        for packet in list.unsafeSequence() {
            let words = MIDIEventPacket.WordCollection(packet)
            for word in words where word >> 28 == 0x2 {   // UMP type 2: MIDI 1.0 channel voice
                out.append(UInt8((word >> 16) & 0xFF))
                out.append(UInt8((word >> 8) & 0x7F))
                out.append(UInt8(word & 0x7F))
            }
        }
        return out
    }
}
