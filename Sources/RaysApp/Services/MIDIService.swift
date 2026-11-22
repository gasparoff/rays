import CoreMIDI
import Foundation
import RaysCore
import RaysControl
import RaysEngine

/// Native CoreMIDI input. Sources named like an Xone K2 use the built-in K2 layout; sources
/// matching a loaded `ControllerProfile` use that layout; with `learnFromAllInputs` every other
/// source is connected too (learned bindings only). Hot-plug re-scans automatically.
@MainActor
final class MIDIService: ObservableObject {
    /// Connected Xone K2 sources.
    @Published private(set) var connectedNames: [String] = []
    /// Connected non-K2 sources with the layout routing them (nil = Learn only).
    @Published private(set) var connectedControllers: [(name: String, profile: ControllerProfile?)] = []
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
    private enum Route: Equatable { case k2, profile(ControllerProfile), learnOnly }
    private var connected: [MIDIEndpointRef: Route] = [:]
    /// Connection tag (refCon) -> route, so each message is routed by the port it came from.
    private var routesByTag: [Int: Route] = [:]
    private var tags: [MIDIEndpointRef: Int] = [:]
    private var nextTag = 1
    private let save: (MIDIMap) -> Void
    /// Non-K2 layouts (the K2 always uses the built-in `XoneK2` profiles).
    let profiles: [ControllerProfile]
    private struct LEDGroup { var destinations: [MIDIEndpointRef]; var last: [UInt8: XoneK2.LED] = [:] }
    private var profileLEDs: [String: LEDGroup] = [:]

    init(map: MIDIMap, profiles: [ControllerProfile] = [], save: @escaping (MIDIMap) -> Void) {
        self.map = map
        self.router = MIDIRouter(map: map)
        self.save = save
        let k2IDs = Set(XoneK2.Layout.allCases.map { XoneK2.profile(for: $0).id })
        self.profiles = profiles.filter { !k2IDs.contains($0.id) }
    }

    private func route(forSourceNamed name: String) -> Route? {
        if MIDIRouter.isK2(name) { return .k2 }
        if let p = profiles.first(where: { $0.matches(portName: name) }) { return .profile(p) }
        return router.map.learnFromAllInputs ? .learnOnly : nil
    }

    func start() {
        guard client == 0 else { return }
        let status = MIDIClientCreateWithBlock("Light System" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.rescan() }
        }
        guard status == noErr else { error = "CoreMIDI non disponibile (\(status))."; return }
        let portStatus = MIDIInputPortCreateWithProtocol(client, "K2 in" as CFString, ._1_0, &port) { [weak self] list, refCon in
            let bytes = Self.bytes(from: list)
            guard !bytes.isEmpty else { return }
            let tag = Int(bitPattern: refCon)
            DispatchQueue.main.async { self?.receive(bytes, tag: tag) }
        }
        guard portStatus == noErr else { error = "Porta MIDI non disponibile (\(portStatus))."; return }
        MIDIOutputPortCreate(client, "K2 luci" as CFString, &outPort)
        rescan()
    }

    func rescan() {
        guard port != 0 else { return }
        var names: [String] = []
        var others: [(name: String, profile: ControllerProfile?)] = []
        var wanted: [MIDIEndpointRef: Route] = [:]
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            let text = Self.displayName(source)
            guard let route = route(forSourceNamed: text) else { continue }
            wanted[source] = route
            switch route {
            case .k2: names.append(text)
            case let .profile(p): others.append((text, p))
            case .learnOnly: others.append((text, nil))
            }
        }
        for (source, _) in connected where wanted[source] == nil {
            MIDIPortDisconnectSource(port, source)
            if let tag = tags.removeValue(forKey: source) { routesByTag[tag] = nil }
        }
        for (source, route) in wanted where connected[source] != route {
            if connected[source] != nil { MIDIPortDisconnectSource(port, source) }
            if let old = tags[source] { routesByTag[old] = nil }
            let tag = nextTag; nextTag += 1
            tags[source] = tag; routesByTag[tag] = route
            MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: tag))
        }
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
        connectedControllers = others.sorted { $0.name < $1.name }
        let allDestinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
        let nextDestinations = allDestinations.filter { MIDIRouter.isK2(Self.displayName($0)) }
        if destinations != nextDestinations { lastLEDs.removeAll() }
        destinations = nextDestinations
        var nextGroups: [String: LEDGroup] = [:]
        for profile in profiles where profile.leds != nil {
            let targets = allDestinations.filter {
                let name = Self.displayName($0)
                return !MIDIRouter.isK2(name) && profile.matches(portName: name)
            }
            guard !targets.isEmpty else { continue }
            var group = profileLEDs[profile.id] ?? LEDGroup(destinations: targets)
            if group.destinations != targets { group = LEDGroup(destinations: targets) }
            nextGroups[profile.id] = group
        }
        profileLEDs = nextGroups
    }

    private static func displayName(_ object: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name)
        return (name?.takeRetainedValue() as String?) ?? ""
    }

    /// Also connect inputs that match no layout, for Learn. Off by default.
    func setLearnFromAllInputs(_ on: Bool) {
        guard on != router.map.learnFromAllInputs else { return }
        releaseForMappingChange()
        router.map.learnFromAllInputs = on
        publishMap()
        rescan()
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
        clearProfileLEDs()
        router.resetInputState()
        router.learning = nil; learning = nil; lastLearned = nil
        onCommand?(.accent(false))
        // Reassigning a held Build must never turn its later release into an accidental Drop.
        if holdingBuild { holdingBuild = false; onCommand?(.stop) }
    }

    private func receive(_ bytes: [UInt8], tag: Int) {
        guard let route = routesByTag[tag] else { return }
        for event in MIDIDecoder.decode(bytes) {
            let result: MIDIRouter.Result
            switch route {
            case .k2: result = router.handle(event, fromK2: true, current: currentValue)
            case let .profile(p): result = router.handle(event, profile: p, current: currentValue)
            case .learnOnly: result = router.handle(event, current: currentValue)
            }
            switch result {
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

    /// Effective control for an action on a port routed by `profile` (for the on-screen guide).
    func effectiveControl(_ action: ControlAction, in profile: ControllerProfile) -> MIDIControl? {
        router.map.control(for: action, in: profile)
    }

    func feedback(_ snapshot: EngineSnapshot, sceneInBank: Bool = true,
                  selectedBank: SceneBank = .house, playingBank: SceneBank? = nil) {
        guard !destinations.isEmpty || !profileLEDs.isEmpty, outPort != 0 else { return }
        var state = K2FeedbackState(scene: snapshot.scene)
        state.sceneInBank = sceneInBank
        state.selectedBank = selectedBank; state.playingBank = playingBank
        state.pendingSceneInBank = snapshot.pendingSceneBank == selectedBank
        state.pendingScene = snapshot.pendingScene
        state.stopped = snapshot.stopped; state.stopFading = snapshot.stopFading
        state.live = snapshot.isLive; state.armed = snapshot.armed
        state.subdivision = snapshot.subdivision; state.accent = snapshot.accentActive
        state.blackout = snapshot.blackout; state.blinkOn = snapshot.tempo.phase.truncatingRemainder(dividingBy: 1) < 0.5
        profileFeedback(state)
        guard !destinations.isEmpty else { return }
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

    private func profileFeedback(_ state: K2FeedbackState) {
        for profile in profiles {
            guard var group = profileLEDs[profile.id], let leds = profile.leds else { continue }
            let next = K2Feedback.leds(map: router.map, profile: profile, state: state)
            let channel = profile.channel
            for base in Set(next.keys).union(group.last.keys) where next[base] != group.last[base] {
                let addresses = leds.addresses(base: base)
                for address in addresses { send([0x80 | channel, address, 0], to: group.destinations) }
                if let color = next[base], let i = [XoneK2.LED.red, .amber, .green].firstIndex(of: color), i < addresses.count {
                    send([0x90 | channel, addresses[i], 127], to: group.destinations)
                }
            }
            group.last = next
            profileLEDs[profile.id] = group
        }
    }

    private func clearProfileLEDs() {
        for profile in profiles {
            guard var group = profileLEDs[profile.id], let leds = profile.leds else { continue }
            for base in group.last.keys {
                for address in leds.addresses(base: base) { send([0x80 | profile.channel, address, 0], to: group.destinations) }
            }
            group.last.removeAll()
            profileLEDs[profile.id] = group
        }
    }

    func stop() {
        clearProfileLEDs()
        if let channel = lastLEDChannel { clearLEDs(channel: channel) }
        for source in connected.keys { MIDIPortDisconnectSource(port, source) }
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if outPort != 0 { MIDIPortDispose(outPort); outPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        connected.removeAll(); destinations.removeAll(); profileLEDs.removeAll()
        routesByTag.removeAll(); tags.removeAll()
    }

    private func clearLEDs(channel: UInt8) {
        for base in lastLEDs.keys { for address in XoneK2.ledAddresses(base: base) { send([0x80 | channel, address, 0]) } }
    }

    private func send(_ bytes: [UInt8]) { send(bytes, to: destinations) }

    private func send(_ bytes: [UInt8], to targets: [MIDIEndpointRef]) {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let packet = MIDIPacketListInit(list)
        bytes.withUnsafeBufferPointer { buffer in
            _ = MIDIPacketListAdd(list, 1024, packet, 0, bytes.count, buffer.baseAddress!)
        }
        for destination in targets { MIDISend(outPort, destination, list) }
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
