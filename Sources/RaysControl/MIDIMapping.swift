import Foundation
import RaysCore

/// One physical control on a MIDI controller (e.g. an Xone K2 button or fader).
public struct MIDIControl: Codable, Hashable, Sendable {
    /// Note or control-change message.
    public enum Kind: String, Codable, Sendable { case note, cc }
    public var kind: Kind
    /// 0-based MIDI channel.
    public var channel: UInt8
    public var number: UInt8

    public init(_ kind: Kind, channel: UInt8, number: UInt8) {
        self.kind = kind; self.channel = channel & 0x0F; self.number = number & 0x7F
    }

    public var label: String { "\(kind == .note ? "Nota" : "CC") \(number) · can. \(channel + 1)" }
}

/// One decoded note or CC message.
public struct MIDIEvent: Equatable, Sendable {
    public var control: MIDIControl
    public var value: UInt8
    /// Note-on with velocity > 0. Note-off (or note-on velocity 0) is `false`.
    public var isNoteOn: Bool

    public init(control: MIDIControl, value: UInt8, isNoteOn: Bool) {
        self.control = control; self.value = value; self.isNoteOn = isNoteOn
    }
}

/// Decodes raw MIDI 1.0 bytes into note/CC events. Realtime, SysEx and other
/// channel messages are skipped; running status is supported.
public enum MIDIDecoder {
    public static func decode(_ bytes: [UInt8]) -> [MIDIEvent] {
        var events: [MIDIEvent] = []
        var status: UInt8 = 0
        var data: [UInt8] = []
        var inSysEx = false
        for byte in bytes {
            if byte >= 0xF8 { continue }  // realtime may interleave anywhere
            if byte == 0xF0 { inSysEx = true; continue }
            if inSysEx {
                if byte & 0x80 == 0 { continue }
                inSysEx = false  // F7 or any status byte ends SysEx
            }
            if byte & 0x80 != 0 {
                status = byte >= 0xF0 ? 0 : byte  // system common cancels running status
                data.removeAll()
                continue
            }
            guard status != 0 else { continue }
            data.append(byte)
            let type = status & 0xF0
            let needed = (type == 0xC0 || type == 0xD0) ? 1 : 2
            guard data.count == needed else { continue }
            let channel = status & 0x0F
            switch type {
            case 0x90:
                events.append(MIDIEvent(control: .init(.note, channel: channel, number: data[0]), value: data[1], isNoteOn: data[1] > 0))
            case 0x80:
                events.append(MIDIEvent(control: .init(.note, channel: channel, number: data[0]), value: 0, isNoteOn: false))
            case 0xB0:
                events.append(MIDIEvent(control: .init(.cc, channel: channel, number: data[0]), value: data[1], isNoteOn: false))
            default: break
            }
            data.removeAll()
        }
        return events
    }
}

/// Console functions a controller may drive. Raw values are persisted in midi.json.
public enum ControlAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case scene1, scene2, scene3, scene4, scene5, scene6
    case master, levelLeft, levelCenter, levelRight, energy, accentLevel
    case accent, buildDrop, blackout, stop, output
    case rateQuarter, rateHalf, rateNormal, rateDouble
    case bankHouse, bankClub, sceneFirstBeat, cancelPending
    public var id: String { rawValue }

    /// Faders/pots: absolute 0...127 (soft takeover) or learned relative encoders.
    public var isContinuous: Bool {
        switch self {
        case .master, .energy, .levelLeft, .levelCenter, .levelRight, .accentLevel: return true
        default: return false
        }
    }

    /// Acts while held: press starts, release (note-off / CC < 64) ends.
    public var isMomentary: Bool { self == .accent || self == .buildDrop }

    public var sceneIndex: Int? {
        let all: [ControlAction] = [.scene1, .scene2, .scene3, .scene4, .scene5, .scene6]
        return all.firstIndex(of: self)
    }

    public var role: FixtureRole? {
        switch self {
        case .levelLeft: return .left
        case .levelCenter: return .center
        case .levelRight: return .right
        default: return nil
        }
    }

    public var rate: Subdivision? {
        switch self {
        case .rateQuarter: return .four
        case .rateHalf: return .two
        case .rateNormal: return .one
        case .rateDouble: return .half
        default: return nil
        }
    }

    public var label: String {
        if let i = sceneIndex { return SceneID.allCases[i].title }
        if let r = rate { return "Velocità \(r.label)" }
        switch self {
        case .master: return "Luminosità generale"
        case .levelLeft: return "Livello sinistra"
        case .levelCenter: return "Livello centro"
        case .levelRight: return "Livello destra"
        case .energy: return "Energia"
        case .accentLevel: return "Livello Flash"
        case .accent: return "Flash (tieni)"
        case .buildDrop: return "Build → Drop (tieni)"
        case .blackout: return "Blackout"
        case .stop: return "Stop"
        case .output: return "Luci on/off"
        case .bankHouse: return "Banco House"
        case .bankClub: return "Banco Club"
        case .sceneFirstBeat: return "Primo beat della scena"
        case .cancelPending: return "Annulla coda"
        default: return rawValue
        }
    }
}

/// What a MIDI control asks the app to do, after Learn, presets and soft takeover.
public enum MIDICommand: Equatable, Sendable {
    case scene(SceneID)
    case master(Double)
    case energy(Double)
    case level(FixtureRole, Double)
    case accentLevel(Double)
    case accent(Bool)
    case buildHold(Bool)
    case rate(Subdivision)
    case stop
    case toggleBlackout
    case toggleOutput
    case bank(SceneBank)
    case sceneFirstBeat
    case cancelPending

    static func continuous(_ action: ControlAction, _ v: Double) -> MIDICommand? {
        if let role = action.role { return .level(role, v) }
        switch action {
        case .master: return .master(v)
        case .energy: return .energy(v)
        case .accentLevel: return .accentLevel(v)
        default: return nil
        }
    }
}

/// Allen & Heath Xone:K2 factory layout (user guide AP8509, Latching Layers OFF).
public enum XoneK2 {
    /// The two built-in Xone:K2 layouts.
    public enum Layout: String, Codable, CaseIterable, Identifiable, Sendable {
        case classic, liveV2
        public var id: String { rawValue }
        public var label: String { self == .classic ? "Classica" : "Live v2" }
    }
    /// Factory MIDI channel 15 (0-based 14).
    public static let factoryChannel: UInt8 = 14
    /// Endless encoders send two's-complement relative values (1 = +1, 127 = −1). Never absolute.
    public static let relativeEncoderCCs: Set<UInt8> = [0, 1, 2, 3, 20, 21]
    /// Button matrix rows A–D, E–H, I–L, M–P (top to bottom).
    public static let matrix: [[UInt8]] = [[36, 37, 38, 39], [32, 33, 34, 35], [28, 29, 30, 31], [24, 25, 26, 27]]
    /// Notes whose tri-colour LED is addressable as red = n, amber = n + 36, green = n + 72.
    public static let ledNotes: ClosedRange<UInt8> = 24...55
    /// Bottom Layer/Exit LEDs use their own three-note addressing scheme.
    public static func ledAddresses(base: UInt8) -> [UInt8] {
        if base == 12 || base == 15 { return [base, base + 4, base + 8] }
        return ledNotes.contains(base) ? [base, base + 36, base + 72] : []
    }

    /// The default performance page: faders = L / C / R / master, column-4 pots = accent level
    /// and energy, pads = scenes (A–C, E–G), Stop (D), rates (I–L), accent hold (M), blackout (P).
    /// H, N, O, the other pots, the encoders and the bottom buttons stay free for Learn.
    /// Mirrored by `Controllers/xone-k2-classic.json` (verified by tests).
    public static let classicProfile = k2Profile(
        id: "allen-heath.xone-k2.classic", name: "Xone:K2 — Classica", encoderResolution: nil,
        bindings: [
            .init(.levelLeft, .cc, 16), .init(.levelCenter, .cc, 17), .init(.levelRight, .cc, 18), .init(.master, .cc, 19),
            .init(.accentLevel, .cc, 11), .init(.energy, .cc, 15),
            .init(.scene1, .note, 36), .init(.scene2, .note, 37), .init(.scene3, .note, 38), .init(.stop, .note, 39),
            .init(.scene4, .note, 32), .init(.scene5, .note, 33), .init(.scene6, .note, 34), .init(.buildDrop, .note, 35),
            .init(.rateQuarter, .note, 28), .init(.rateHalf, .note, 29), .init(.rateNormal, .note, 30), .init(.rateDouble, .note, 31),
            .init(.accent, .note, 24), .init(.blackout, .note, 27),
        ],
        notes:
            "Factory layout, Latching Layers OFF. Faders = left / centre / right / master; column-4 pots = Flash level and energy; pads A–C, E–G = scenes, D = Stop, H = Build → Drop, I–L = rates, M = Flash (hold), P = Blackout."
    )

    /// Mirrored by `Controllers/xone-k2-live-v2.json` (verified by tests).
    public static let liveV2Profile = k2Profile(
        id: "allen-heath.xone-k2.live-v2", name: "Xone:K2 — Live v2", encoderResolution: 127,
        bindings: [
            .init(.levelLeft, .cc, 16), .init(.levelCenter, .cc, 17), .init(.levelRight, .cc, 18), .init(.master, .cc, 19),
            .init(.energy, .cc, 20), .init(.accentLevel, .cc, 21),
            .init(.scene1, .note, 36), .init(.scene2, .note, 37), .init(.scene3, .note, 38), .init(.bankHouse, .note, 39),
            .init(.scene4, .note, 32), .init(.scene5, .note, 33), .init(.scene6, .note, 34), .init(.bankClub, .note, 35),
            .init(.rateQuarter, .note, 28), .init(.rateHalf, .note, 29), .init(.rateNormal, .note, 30), .init(.rateDouble, .note, 31),
            .init(.accent, .note, 24), .init(.sceneFirstBeat, .note, 25), .init(.cancelPending, .note, 26), .init(.stop, .note, 27),
            .init(.buildDrop, .note, 12), .init(.blackout, .note, 15),
        ],
        notes:
            "Factory layout, Latching Layers OFF. The two bottom encoders = energy and Flash level (relative, 127 detents per sweep); pads D/H = House/Club bank, N = first beat, O = cancel queue, P = Stop; bottom Layer = Build → Drop, Exit = Blackout."
    )

    private static func k2Profile(
        id: String, name: String, encoderResolution: Int?,
        bindings: [ControllerProfile.Binding], notes: String
    ) -> ControllerProfile {
        ControllerProfile(
            id: id, name: name, manufacturer: "Allen & Heath", portNamePattern: "(^|[^a-z0-9])k2($|[^a-z0-9])",
            midiChannel: Int(factoryChannel) + 1, bindings: bindings, relativeEncoders: [0, 1, 2, 3, 20, 21],
            encoderResolution: encoderResolution,
            leds: .init(
                notes: .init(from: 24, to: 55), colors: .init(red: 0, amber: 36, green: 72),
                special: [.init(base: 12, addresses: [12, 16, 20]), .init(base: 15, addresses: [15, 19, 23])]),
            notes: notes)
    }

    public static func profile(for layout: Layout) -> ControllerProfile {
        layout == .classic ? classicProfile : liveV2Profile
    }

    public static func presetAction(kind: MIDIControl.Kind, number: UInt8, layout: Layout = .classic) -> ControlAction? {
        profile(for: layout).bindings.first { $0.type == kind && $0.number == number }?.action
    }

    public static func presetControl(for action: ControlAction, channel: UInt8, layout: Layout = .classic) -> MIDIControl? {
        profile(for: layout).bindings.first { $0.action == action }.map { MIDIControl($0.type, channel: channel, number: $0.number) }
    }

    /// Colour of a K2-style tri-colour LED.
    public enum LED: Equatable, Sendable {
        case off, red, amber, green
        /// Note to switch on for this colour, nil for off.
        public func note(base: UInt8) -> UInt8? {
            let notes = XoneK2.ledAddresses(base: base)
            guard notes.count == 3 else { return nil }
            switch self {
            case .off: return nil
            case .red: return notes[0]
            case .amber: return notes[1]
            case .green: return notes[2]
            }
        }
    }
}

/// Persistent mapping: learned bindings plus the automatic K2 preset settings.
public struct MIDIMap: Codable, Equatable, Sendable {
    /// A learned binding from a control to an action.
    public struct Binding: Codable, Equatable, Sendable {
        public var action: ControlAction
        public var control: MIDIControl
        /// Learned from a relative encoder (two's complement). nil = absolute.
        public var relative: Bool?

        public init(action: ControlAction, control: MIDIControl, relative: Bool? = nil) {
            self.action = action; self.control = control; self.relative = relative
        }
    }

    public var bindings: [Binding] = []
    /// The K2 factory preset applies to K2 ports; learned bindings always win.
    public var k2Preset = true
    /// Fixed 0-based K2 channel, or nil = automatic (first preset message seen; factory 15).
    public var k2Channel: UInt8?
    /// Additive setting: old MIDI files always retain the classic layout.
    public var k2Layout: XoneK2.Layout = .classic
    /// Also connect MIDI inputs that match no controller layout, so their controls can be learned.
    /// Off by default: only the K2 and ports matching a `ControllerProfile` are listened to.
    public var learnFromAllInputs = false

    public init() {}

    enum CodingKeys: String, CodingKey { case bindings, k2Preset, k2Channel, k2Layout, learnFromAllInputs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown actions from other versions are dropped rather than failing the whole file.
        struct Lossy: Decodable {
            let binding: Binding?
            init(from decoder: Decoder) throws { binding = try? Binding(from: decoder) }
        }
        bindings = ((try? c.decodeIfPresent([Lossy].self, forKey: .bindings)) ?? []).compactMap(\.binding)
        k2Preset = (try? c.decodeIfPresent(Bool.self, forKey: .k2Preset)) ?? true
        k2Channel = (try? c.decodeIfPresent(UInt8.self, forKey: .k2Channel)).flatMap { $0 }.map { $0 & 0x0F }
        k2Layout = (try? c.decodeIfPresent(XoneK2.Layout.self, forKey: .k2Layout)) ?? .classic
        learnFromAllInputs = (try? c.decodeIfPresent(Bool.self, forKey: .learnFromAllInputs)) ?? false
    }

    public func control(for action: ControlAction) -> MIDIControl? { bindings.first { $0.action == action }?.control }
    public func binding(for control: MIDIControl) -> Binding? { bindings.first { $0.control == control } }
    public func action(for control: MIDIControl) -> ControlAction? { binding(for: control)?.action }

    /// One control drives one action; re-learning moves it.
    public mutating func bind(_ action: ControlAction, to control: MIDIControl, relative: Bool = false) {
        bindings.removeAll { $0.action == action || $0.control == control }
        bindings.append(Binding(action: action, control: control, relative: relative ? true : nil))
    }

    public mutating func unbind(_ action: ControlAction) { bindings.removeAll { $0.action == action } }

    /// Effective K2 control for an action (learned first, else preset) — used for LEDs and the diagram.
    public func k2Control(for action: ControlAction, channel: UInt8) -> MIDIControl? {
        if let learned = control(for: action) { return learned }
        guard k2Preset, let preset = XoneK2.presetControl(for: action, channel: channel, layout: k2Layout),
            binding(for: preset) == nil
        else { return nil }
        return preset
    }

    /// Effective control for an action on a port routed by `profile` (learned on that port's
    /// channel first, else the layout's binding unless that control or action was re-learned).
    public func control(for action: ControlAction, in profile: ControllerProfile) -> MIDIControl? {
        if let learned = control(for: action) { return profile.channels.contains(learned.channel) ? learned : nil }
        guard let b = profile.bindings.first(where: { $0.action == action }) else { return nil }
        let c = profile.control(of: b)
        return binding(for: c) == nil ? c : nil
    }
}

/// Learn + dispatch state machine. Pure, so it is testable without hardware.
public struct MIDIRouter: Sendable {
    /// Outcome of one MIDI message.
    public enum Result: Equatable, Sendable {
        case none
        case learned(ControlAction, MIDIControl)
        case command(MIDICommand)
        /// Absolute control not yet picked up: hardware position for the UI ghost.
        case waiting(ControlAction, Double)
    }

    /// One detent of a relative encoder.
    public static let relativeStep = 1.0 / 100
    /// Soft takeover window (±2/127).
    public static let pickupWindow = 2.0 / 127
    /// One detent of an encoder bound by the Live v2 preset (full sweep in 127 detents).
    public static let livePresetEncoderStep = 1.0 / 127

    struct Takeover: Sendable { var pickedUp = false; var lastHardware: Double? }

    public var map: MIDIMap
    public var learning: ControlAction?
    /// Channel seen on the first K2 preset message when `map.k2Channel` is automatic.
    public private(set) var detectedK2Channel: UInt8?
    /// CCs currently held at or above 64, so CC buttons fire once per press.
    private var ccHigh: Set<MIDIControl> = []
    private var noteHigh: Set<MIDIControl> = []
    private var takeover: [ControlAction: Takeover] = [:]

    public init(map: MIDIMap = MIDIMap()) { self.map = map }

    /// Channel used for the preset and for LED feedback.
    public var k2Channel: UInt8 { map.k2Channel ?? detectedK2Channel ?? XoneK2.factoryChannel }

    /// Absolute controls must be moved through the software value again before they act
    /// (after launch, preset/mapping changes, or a mouse/keyboard edit of that value).
    public mutating func resetTakeover(_ action: ControlAction? = nil) {
        if let action { takeover[action] = nil } else { takeover.removeAll() }
    }

    public mutating func resetInputState() {
        ccHigh.removeAll(); noteHigh.removeAll(); resetTakeover()
    }

    public mutating func resetDetectedChannel() { detectedK2Channel = nil }

    /// - Parameters:
    ///   - fromK2: the message came from a port named like an Xone K2 (enables the preset and
    ///     the relative-encoder rules).
    ///   - profile: the controller layout of a non-K2 port (ignored when `fromK2`); nil = learned
    ///     bindings only.
    ///   - current: the software value of a continuous action, for soft takeover and encoders.
    public mutating func handle(
        _ event: MIDIEvent, fromK2: Bool = false, profile: ControllerProfile? = nil,
        current: (ControlAction) -> Double = { _ in 0 }
    ) -> Result {
        let profile = fromK2 ? nil : profile
        let control = event.control
        let pressed = control.kind == .note ? event.isNoteOn : event.value >= 64
        var risingEdge = pressed, fallingEdge = !pressed
        if control.kind == .cc {
            let wasHigh = ccHigh.contains(control)
            risingEdge = pressed && !wasHigh
            fallingEdge = !pressed && wasHigh
            if pressed { ccHigh.insert(control) } else { ccHigh.remove(control) }
        }
        if control.kind == .note {
            let wasHigh = noteHigh.contains(control)
            risingEdge = pressed && !wasHigh
            fallingEdge = !pressed && wasHigh
            if pressed { noteHigh.insert(control) } else { noteHigh.remove(control) }
        }
        let isK2Encoder = fromK2 && control.kind == .cc && XoneK2.relativeEncoderCCs.contains(control.number)
        let isProfileEncoder = profile?.isRelativeEncoder(control) ?? false
        let isEncoder = isK2Encoder || isProfileEncoder

        if let action = learning {
            if action.isContinuous {
                guard control.kind == .cc else { return .none }
            } else {
                // Buttons learn on a press, never on release, and never from an endless encoder.
                guard risingEdge, !isEncoder else { return .none }
            }
            map.bind(action, to: control, relative: action.isContinuous && isEncoder)
            learning = nil
            takeover[action] = nil
            return .learned(action, control)
        }

        guard let (action, relative) = resolve(control, fromK2: fromK2, profile: profile) else { return .none }

        if action.isContinuous {
            guard control.kind == .cc else { return .none }
            if relative || isK2Encoder {
                let raw = Int(event.value)
                guard raw != 0, raw != 64 else { return .none }
                let delta = raw < 64 ? raw : raw - 128
                let isPreset = map.binding(for: control) == nil
                let isLivePresetEncoder = fromK2 && map.k2Layout == .liveV2 && isPreset
                var step = isLivePresetEncoder ? Self.livePresetEncoderStep : Self.relativeStep
                if isPreset, isProfileEncoder, let r = profile?.encoderResolution, r > 0 { step = 1.0 / Double(r) }
                let v = clamp01(current(action) + Double(delta) * step)
                return MIDICommand.continuous(action, v).map(Result.command) ?? .none
            }
            let v = Double(event.value) / 127
            let software = clamp01(current(action))
            var state = takeover[action] ?? Takeover()
            if !state.pickedUp {
                let near = abs(v - software) <= Self.pickupWindow + 1e-9
                let crossed = state.lastHardware.map { ($0 - software) * (v - software) <= 0 } ?? false
                guard near || crossed else {
                    state.lastHardware = v
                    takeover[action] = state
                    return .waiting(action, v)
                }
                state.pickedUp = true
            }
            state.lastHardware = v
            takeover[action] = state
            return MIDICommand.continuous(action, v).map(Result.command) ?? .none
        }

        if action.isMomentary {
            if risingEdge { return .command(action == .buildDrop ? .buildHold(true) : .accent(true)) }
            if fallingEdge { return .command(action == .buildDrop ? .buildHold(false) : .accent(false)) }
            return .none
        }
        guard risingEdge, !isEncoder else { return .none }
        if let i = action.sceneIndex { return .command(.scene(SceneID.allCases[i])) }
        if let r = action.rate { return .command(.rate(r)) }
        switch action {
        case .blackout: return .command(.toggleBlackout)
        case .output: return .command(.toggleOutput)
        case .stop: return .command(.stop)
        case .bankHouse: return .command(.bank(.house))
        case .bankClub: return .command(.bank(.club))
        case .sceneFirstBeat: return .command(.sceneFirstBeat)
        case .cancelPending: return .command(.cancelPending)
        default: return .none
        }
    }

    /// Learned bindings first; then the K2 preset for K2 ports on the K2 channel, unless that
    /// action has been re-learned elsewhere.
    private mutating func resolve(_ control: MIDIControl, fromK2: Bool, profile: ControllerProfile?) -> (ControlAction, Bool)? {
        if let b = map.binding(for: control) { return (b.action, b.relative == true) }
        if !fromK2, let profile {
            guard let action = profile.action(for: control), map.control(for: action) == nil else { return nil }
            let encoder = profile.isRelativeEncoder(control)
            return (action, encoder)
        }
        guard fromK2, map.k2Preset,
            let action = XoneK2.presetAction(kind: control.kind, number: control.number, layout: map.k2Layout)
        else { return nil }
        if let fixed = map.k2Channel {
            guard control.channel == fixed else { return nil }
        } else {
            if detectedK2Channel == nil { detectedK2Channel = control.channel }
            guard control.channel == detectedK2Channel else { return nil }
        }
        guard map.control(for: action) == nil else { return nil }
        return (action, false)
    }

    /// Xone K2 (and the K2 inside "XONE:K2") is matched by name.
    public static func isK2(_ name: String) -> Bool {
        name.range(of: "(^|[^a-z0-9])k2($|[^a-z0-9])", options: [.caseInsensitive, .regularExpression]) != nil
    }
}

/// State the K2 pad LEDs reflect. Only mapped notes on the K2 ever light.
public struct K2FeedbackState: Equatable, Sendable {
    public var scene: SceneID
    public var pendingScene: SceneID?
    /// Browsing another bank must not light a pad as if its scene were playing.
    public var sceneInBank = true
    /// nil preserves the classic same-bank rule for callers without bank metadata.
    public var pendingSceneInBank: Bool?
    public var selectedBank: SceneBank = .house
    public var playingBank: SceneBank?
    public var stopped = false
    public var stopFading = false
    /// DMX really leaving the app (armed, sending, real fixtures).
    public var live = false
    public var armed = false
    public var subdivision: Subdivision = .one
    public var accent = false
    public var blackout = false
    /// Blink phase for pending scenes (on for the first half of each beat).
    public var blinkOn = false

    public init(scene: SceneID) { self.scene = scene }
}

/// LED colours that mirror the console state on the K2 and on other layouts with LEDs.
public enum K2Feedback {
    /// Desired colour for each LED-capable base note mapped to an action.
    public static func leds(map: MIDIMap, channel: UInt8, state s: K2FeedbackState) -> [UInt8: XoneK2.LED] {
        var out: [UInt8: XoneK2.LED] = [:]
        for action in ControlAction.allCases {
            guard let c = map.k2Control(for: action, channel: channel), c.channel == channel, c.kind == .note,
                !XoneK2.ledAddresses(base: c.number).isEmpty
            else { continue }
            out[c.number] = color(action, s)
        }
        return out
    }

    /// LED colours for a port routed by `profile` (same colour rules as the K2), keyed by the
    /// note control (its channel included). Empty when the layout has no LEDs.
    public static func leds(map: MIDIMap, profile: ControllerProfile, state s: K2FeedbackState) -> [MIDIControl: XoneK2.LED] {
        guard let leds = profile.leds else { return [:] }
        var out: [MIDIControl: XoneK2.LED] = [:]
        for action in ControlAction.allCases {
            guard let c = map.control(for: action, in: profile), c.kind == .note, leds.hasLED(base: c.number) else { continue }
            out[c] = color(action, s)
        }
        return out
    }

    static func color(_ action: ControlAction, _ s: K2FeedbackState) -> XoneK2.LED {
        let active: XoneK2.LED = s.live ? .green : .amber
        if let i = action.sceneIndex {
            let scene = SceneID.allCases[i]
            if s.pendingScene == scene, s.pendingSceneInBank ?? s.sceneInBank { return s.blinkOn ? .amber : .off }
            guard s.sceneInBank else { return .off }
            return !s.stopped && s.scene == scene ? active : .off
        }
        if let r = action.rate { return s.subdivision == r ? active : .off }
        switch action {
        case .accent: return s.accent && !s.blackout ? active : .off
        case .buildDrop: return !s.stopped && s.scene == .aurora ? .amber : (s.scene == .respiro && !s.stopped && s.live ? .green : .off)
        case .blackout: return s.blackout ? .red : .off
        case .stop: return s.stopFading && !s.blackout ? .amber : .off
        case .output: return s.armed ? .green : .off
        case .bankHouse, .bankClub:
            let bank: SceneBank = action == .bankHouse ? .house : .club
            if !s.stopped, s.playingBank == bank, s.live { return .green }
            return s.selectedBank == bank ? .amber : .off
        case .cancelPending: return s.pendingScene != nil ? .amber : .off
        default: return .off
        }
    }
}
