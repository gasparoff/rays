import Foundation

/// One physical control on a MIDI controller (e.g. an Xone K2 button or fader).
public struct MIDIControl: Codable, Hashable, Sendable {
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
            if byte >= 0xF8 { continue }                 // realtime may interleave anywhere
            if byte == 0xF0 { inSysEx = true; continue }
            if inSysEx {
                if byte & 0x80 == 0 { continue }
                inSysEx = false                          // F7 or any status byte ends SysEx
            }
            if byte & 0x80 != 0 {
                status = byte >= 0xF0 ? 0 : byte         // system common cancels running status
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

    public static func padName(_ note: UInt8) -> String? {
        for (row, notes) in matrix.enumerated() {
            if let col = notes.firstIndex(of: note) {
                return String(UnicodeScalar(UInt8(65 + row * 4 + col)))
            }
        }
        return nil
    }

    /// The default performance page: faders = L / C / R / master, column-4 pots = accent level
    /// and energy, pads = scenes (A–C, E–G), Stop (D), rates (I–L), accent hold (M), blackout (P).
    /// H, N, O, the other pots, the encoders and the bottom buttons stay free for Learn.
    public static let preset: [(action: ControlAction, kind: MIDIControl.Kind, number: UInt8)] = [
        (.levelLeft, .cc, 16), (.levelCenter, .cc, 17), (.levelRight, .cc, 18), (.master, .cc, 19),
        (.accentLevel, .cc, 11), (.energy, .cc, 15),
        (.scene1, .note, 36), (.scene2, .note, 37), (.scene3, .note, 38), (.stop, .note, 39),
        (.scene4, .note, 32), (.scene5, .note, 33), (.scene6, .note, 34), (.buildDrop, .note, 35),
        (.rateQuarter, .note, 28), (.rateHalf, .note, 29), (.rateNormal, .note, 30), (.rateDouble, .note, 31),
        (.accent, .note, 24), (.blackout, .note, 27)
    ]

    public static let livePreset: [(action: ControlAction, kind: MIDIControl.Kind, number: UInt8)] = [
        (.levelLeft, .cc, 16), (.levelCenter, .cc, 17), (.levelRight, .cc, 18), (.master, .cc, 19),
        (.energy, .cc, 20), (.accentLevel, .cc, 21),
        (.scene1, .note, 36), (.scene2, .note, 37), (.scene3, .note, 38), (.bankHouse, .note, 39),
        (.scene4, .note, 32), (.scene5, .note, 33), (.scene6, .note, 34), (.bankClub, .note, 35),
        (.rateQuarter, .note, 28), (.rateHalf, .note, 29), (.rateNormal, .note, 30), (.rateDouble, .note, 31),
        (.accent, .note, 24), (.sceneFirstBeat, .note, 25), (.cancelPending, .note, 26), (.stop, .note, 27),
        (.buildDrop, .note, 12), (.blackout, .note, 15)
    ]

    public static func preset(for layout: Layout) -> [(action: ControlAction, kind: MIDIControl.Kind, number: UInt8)] {
        layout == .classic ? preset : livePreset
    }

    public static func presetAction(kind: MIDIControl.Kind, number: UInt8, layout: Layout = .classic) -> ControlAction? {
        preset(for: layout).first { $0.kind == kind && $0.number == number }?.action
    }

    public static func presetControl(for action: ControlAction, channel: UInt8, layout: Layout = .classic) -> MIDIControl? {
        preset(for: layout).first { $0.action == action }.map { MIDIControl($0.kind, channel: channel, number: $0.number) }
    }

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

    public init() {}

    enum CodingKeys: String, CodingKey { case bindings, k2Preset, k2Channel, k2Layout }

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
              binding(for: preset) == nil else { return nil }
        return preset
    }
}

/// Learn + dispatch state machine. Pure, so it is testable without hardware.
public struct MIDIRouter: Sendable {
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
    ///   - current: the software value of a continuous action, for soft takeover and encoders.
    public mutating func handle(_ event: MIDIEvent, fromK2: Bool = false,
                                current: (ControlAction) -> Double = { _ in 0 }) -> Result {
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

        if let action = learning {
            if action.isContinuous {
                guard control.kind == .cc else { return .none }
            } else {
                // Buttons learn on a press, never on release, and never from an endless encoder.
                guard risingEdge, !isK2Encoder else { return .none }
            }
            map.bind(action, to: control, relative: action.isContinuous && isK2Encoder)
            learning = nil
            takeover[action] = nil
            return .learned(action, control)
        }

        guard let (action, relative) = resolve(control, fromK2: fromK2) else { return .none }

        if action.isContinuous {
            guard control.kind == .cc else { return .none }
            if relative || isK2Encoder {
                let raw = Int(event.value)
                guard raw != 0, raw != 64 else { return .none }
                let delta = raw < 64 ? raw : raw - 128
                let isLivePresetEncoder = fromK2 && map.k2Layout == .liveV2 && map.binding(for: control) == nil
                let step = isLivePresetEncoder ? 1.0 / 127 : Self.relativeStep
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
        guard risingEdge, !isK2Encoder else { return .none }
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
    private mutating func resolve(_ control: MIDIControl, fromK2: Bool) -> (ControlAction, Bool)? {
        if let b = map.binding(for: control) { return (b.action, b.relative == true) }
        guard fromK2, map.k2Preset,
              let action = XoneK2.presetAction(kind: control.kind, number: control.number, layout: map.k2Layout) else { return nil }
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

public enum K2Feedback {
    /// Desired colour for each LED-capable base note mapped to an action.
    public static func leds(map: MIDIMap, channel: UInt8, state s: K2FeedbackState) -> [UInt8: XoneK2.LED] {
        var out: [UInt8: XoneK2.LED] = [:]
        for action in ControlAction.allCases {
            guard let c = map.k2Control(for: action, channel: channel), c.channel == channel, c.kind == .note,
                  !XoneK2.ledAddresses(base: c.number).isEmpty else { continue }
            out[c.number] = color(action, s)
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
