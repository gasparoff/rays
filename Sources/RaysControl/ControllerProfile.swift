import Foundation

/// A MIDI controller layout described as data (`Controllers/*.json`).
///
/// The Xone:K2 layouts ship as JSON files that mirror `XoneK2` exactly (verified by tests);
/// the K2 itself is still driven by the `XoneK2` code path. Learned bindings always win.
public struct ControllerProfile: Codable, Equatable, Identifiable, Sendable {
    /// One control of the layout and the action it drives.
    public struct Binding: Codable, Equatable, Hashable, Sendable {
        public var action: ControlAction
        /// "note" or "cc".
        public var type: MIDIControl.Kind
        public var number: UInt8
        /// 1-based MIDI channel when this control does not use the layout's `midiChannel`
        /// (e.g. per-track faders that send on channels 1…8). Omitted = the layout's channel.
        public var channel: Int?

        public init(_ action: ControlAction, _ type: MIDIControl.Kind, _ number: UInt8, channel: Int? = nil) {
            self.action = action; self.type = type; self.number = number; self.channel = channel
        }
    }

    /// Pad LEDs. Two styles:
    /// - `offset` (default, Xone:K2): a note in `notes` lights colour `c` by sending note
    ///   `note + colors[c]`; `special` lists bases with their own [red, amber, green] addresses.
    /// - `velocity` (Akai APC, Novation): a note in `notes` or `extraNotes` lights colour `c` by
    ///   sending that same note with velocity `colors[c]`; off is a note-off.
    public struct LEDFeedback: Codable, Equatable, Sendable {
        /// How a colour is selected: by note offset (Xone:K2) or by note velocity (APC, Launchpad).
        public enum Style: String, Codable, Sendable { case offset, velocity }
        /// Inclusive range of LED notes.
        public struct Range: Codable, Equatable, Sendable {
            public var from: UInt8
            public var to: UInt8
        }
        /// Note offsets (offset style) or velocities (velocity style) for the three feedback colours.
        public struct Colors: Codable, Equatable, Sendable {
            public var red: UInt8
            public var amber: UInt8
            public var green: UInt8
        }
        /// A button whose LED uses its own three addresses.
        public struct Special: Codable, Equatable, Sendable {
            public var base: UInt8
            /// [red, amber, green]
            public var addresses: [UInt8]
        }
        public var style: Style?
        public var notes: Range
        /// More LED notes outside `notes` (velocity style).
        public var extraNotes: [UInt8]?
        public var colors: Colors
        public var special: [Special]?

        public init(style: Style? = nil, notes: Range, extraNotes: [UInt8]? = nil, colors: Colors, special: [Special]? = nil) {
            self.style = style; self.notes = notes; self.extraNotes = extraNotes; self.colors = colors; self.special = special
        }

        private var isVelocity: Bool { style == .velocity }

        /// True when `base` has an LED RAYS can drive.
        public func hasLED(base: UInt8) -> Bool {
            if isVelocity { return inRange(base) || (extraNotes ?? []).contains(base) }
            return addresses(base: base).count == 3
        }

        /// Note and velocity that light `base` in `color` (red/amber/green), nil for no LED.
        public func onMessage(base: UInt8, color: XoneK2.LED) -> (note: UInt8, velocity: UInt8)? {
            guard hasLED(base: base) else { return nil }
            let index: Int
            switch color {
            case .off: return nil
            case .red: index = 0
            case .amber: index = 1
            case .green: index = 2
            }
            if isVelocity { return (base, [colors.red, colors.amber, colors.green][index]) }
            return (addresses(base: base)[index], 127)
        }

        /// Notes to switch off (note-off) to clear `base`.
        public func offNotes(base: UInt8) -> [UInt8] {
            guard hasLED(base: base) else { return [] }
            return isVelocity ? [base] : addresses(base: base)
        }

        private func inRange(_ base: UInt8) -> Bool { (notes.from...max(notes.from, notes.to)).contains(base) }

        /// Offset style: LED addresses [red, amber, green] for a mapped note, or [] when it has no LED.
        public func addresses(base: UInt8) -> [UInt8] {
            guard !isVelocity else { return [] }
            if let s = special?.first(where: { $0.base == base }) { return s.addresses }
            guard (notes.from...max(notes.from, notes.to)).contains(base) else { return [] }
            return [colors.red, colors.amber, colors.green].map { UInt8(clamping: Int(base) + Int($0)) }
        }
    }

    public var id: String
    public var name: String
    public var manufacturer: String
    /// Case-insensitive regular expression matched against the CoreMIDI port name.
    public var portNamePattern: String
    /// 1-based MIDI channel (1...16), as printed in manuals.
    public var midiChannel: Int
    public var bindings: [Binding]
    /// CC numbers of endless encoders sending two's-complement relative values (1 = +1, 127 = −1).
    public var relativeEncoders: [UInt8]?
    /// Encoder detents for a full 0...1 sweep when a preset binding uses an encoder (default 100).
    public var encoderResolution: Int?
    public var leds: LEDFeedback?
    public var notes: String?

    /// 0-based channel used on the wire.
    public var channel: UInt8 { UInt8(clamping: max(0, midiChannel - 1)) & 0x0F }

    /// 0-based wire channel of one binding.
    public func channel(of binding: Binding) -> UInt8 {
        binding.channel.map { UInt8(clamping: max(0, $0 - 1)) & 0x0F } ?? channel
    }

    /// The control a binding listens to.
    public func control(of binding: Binding) -> MIDIControl {
        MIDIControl(binding.type, channel: channel(of: binding), number: binding.number)
    }

    /// Channels this layout uses (the layout channel plus any per-binding channels).
    public var channels: Set<UInt8> { Set(bindings.map(channel(of:))).union([channel]) }

    /// A relative (endless) encoder of this layout.
    public func isRelativeEncoder(_ control: MIDIControl) -> Bool {
        control.kind == .cc && channels.contains(control.channel) && (relativeEncoders ?? []).contains(control.number)
    }

    public func matches(portName: String) -> Bool {
        portName.range(of: portNamePattern, options: [.caseInsensitive, .regularExpression]) != nil
    }

    public func action(for control: MIDIControl) -> ControlAction? {
        bindings.first { self.control(of: $0) == control }?.action
    }

    /// Human-readable problems; empty means the profile is valid.
    public var problems: [String] {
        var out: [String] = []
        if id.trimmingCharacters(in: .whitespaces).isEmpty { out.append("id is empty") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("name is empty") }
        if manufacturer.trimmingCharacters(in: .whitespaces).isEmpty { out.append("manufacturer is empty") }
        if !(1...16).contains(midiChannel) { out.append("midiChannel \(midiChannel) is not 1...16") }
        if (try? NSRegularExpression(pattern: portNamePattern)) == nil || portNamePattern.isEmpty {
            out.append("portNamePattern is not a valid regular expression")
        }
        if bindings.isEmpty { out.append("no bindings") }
        let encoders = Set(relativeEncoders ?? [])
        var controls = Set<String>(), actions = Set<ControlAction>()
        for b in bindings {
            if b.number > 127 { out.append("\(b.action.rawValue): number \(b.number) is not 0...127") }
            if let c = b.channel, !(1...16).contains(c) { out.append("\(b.action.rawValue): channel \(c) is not 1...16") }
            let where_ = b.channel.map { " on channel \($0)" } ?? ""
            if !controls.insert("\(b.type.rawValue) \(b.number) ch\(channel(of: b))").inserted {
                out.append("\(b.type.rawValue) \(b.number)\(where_) is bound twice")
            }
            if !actions.insert(b.action).inserted { out.append("\(b.action.rawValue) is bound twice") }
            if b.action.isContinuous, b.type != .cc { out.append("\(b.action.rawValue) is continuous and needs a cc") }
            if b.type == .cc, encoders.contains(b.number), !b.action.isContinuous {
                out.append("\(b.action.rawValue) is a button on encoder cc \(b.number)")
            }
        }
        if encoders.contains(where: { $0 > 127 }) { out.append("relativeEncoders must be 0...127") }
        if let r = encoderResolution, r < 1 { out.append("encoderResolution must be at least 1") }
        if let leds {
            if leds.notes.from > leds.notes.to { out.append("leds.notes.from is after leds.notes.to") }
            let colorTop = Int(max(leds.colors.red, leds.colors.amber, leds.colors.green))
            let top = leds.style == .velocity ? max(Int(leds.notes.to), colorTop) : Int(leds.notes.to) + colorTop
            if top > 127 || (leds.extraNotes ?? []).contains(where: { $0 > 127 }) { out.append("LED addresses exceed 127") }
            for s in leds.special ?? [] where s.addresses.count != 3 || s.addresses.contains(where: { $0 > 127 }) {
                out.append("leds.special \(s.base) needs three addresses 0...127")
            }
        }
        return out
    }
}

/// Controller layouts loaded from the app bundle (`Resources/Controllers`) and from
/// `Application Support/RAYS/Controllers`.
public enum ControllerLibrary {
    /// Loads every `*.json` ControllerProfile (one object or an array per file) in `directory`;
    /// invalid files are reported, not fatal. Files are read in name order.
    public static func loadProfiles(in directory: URL) -> (profiles: [ControllerProfile], errors: [String]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var result: [ControllerProfile] = []
        var errors: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: file)
                let decoded: [ControllerProfile]
                if let list = try? JSONDecoder().decode([ControllerProfile].self, from: data) {
                    decoded = list
                } else {
                    decoded = [try JSONDecoder().decode(ControllerProfile.self, from: data)]
                }
                for profile in decoded {
                    let problems = profile.problems
                    if problems.isEmpty {
                        result.append(profile)
                    } else {
                        errors.append("\(file.lastPathComponent) (\(profile.id)): \(problems.joined(separator: "; "))")
                    }
                }
            } catch {
                errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (result, errors)
    }

    /// Later directories override earlier ones by id (user files override bundled ones).
    public static func merge(_ lists: [ControllerProfile]...) -> [ControllerProfile] {
        var order: [String] = []
        var byID: [String: ControllerProfile] = [:]
        for profile in lists.joined() {
            if byID[profile.id] == nil { order.append(profile.id) }
            byID[profile.id] = profile
        }
        return order.compactMap { byID[$0] }
    }
}
