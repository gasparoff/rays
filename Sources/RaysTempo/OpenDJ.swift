import Foundation

/// What openDJ sends to apps that subscribe to its OSC events for visuals and lights.
public enum OpenDJEvent: Equatable, Sendable {
    /// A beat of the master deck as it plays: its place in the bar (1...4), the bar in the phrase
    /// (from 1; 0 before the track's first bar) and the tempo the deck is playing at.
    case beat(beatInBar: Int, barInPhrase: Int, bpm: Double)
    /// The master deck starts a phrase: Intro, Build, Drop, Breakdown, Chorus, Verse or Outro, or
    /// "Phrase" for a track without phrase analysis. `bars` is 0 when no phrase follows.
    case phrase(name: String, bars: Int)

    /// The UDP port openDJ listens on unless the DJ picks another.
    public static let defaultPort: UInt16 = 9000

    /// Follows the events and asks for a control's value, which openDJ answers unless it is set to
    /// send only. openDJ adds a pattern each time it is subscribed, so the renewal drops the old one first.
    public static let subscription: Data = {
        let patterns = ["/beat", "/phrase"].map(OSCMessage.Argument.string)
        return OSCMessage.bundle([
            OSCMessage("/unsubscribe", patterns), OSCMessage("/subscribe", patterns), OSCMessage("/master/crossfader"),
        ])
    }()

    public init?(_ message: OSCMessage) {
        switch (message.address, message.arguments) {
        case let ("/beat", args):
            guard args.count == 3, case let .int(beat) = args[0], case let .int(bar) = args[1], case let .float(bpm) = args[2],
                (1...4).contains(beat), bar >= 0, bpm.isFinite, bpm > 0
            else { return nil }
            self = .beat(beatInBar: Int(beat), barInPhrase: Int(bar), bpm: Double(bpm))
        case let ("/phrase", args):
            guard args.count == 2, case let .string(name) = args[0], case let .int(bars) = args[1], bars >= 0 else { return nil }
            self = .phrase(name: name, bars: Int(bars))
        default: return nil
        }
    }
}

/// Where openDJ's master deck is, from the events received so far.
public struct OpenDJTimeline: Equatable, Sendable {
    public private(set) var bpm: Double?
    public private(set) var beatInBar: Int?
    public private(set) var barInPhrase: Int?
    /// The phrase playing, once openDJ has named it. openDJ names a phrase only as it starts, so
    /// after a jump or a change of master deck it stays unknown until the next one.
    public private(set) var phrase: String?

    public init() {}

    public mutating func apply(_ event: OpenDJEvent) {
        switch event {
        case let .beat(beat, bar, bpm):
            // openDJ sends the next beat, or the one after when its check ran late.
            let step = barInPhrase.flatMap { lastBar in beatInBar.map { (bar - lastBar) * 4 + beat - $0 } }
            if step != 1 && step != 2 { phrase = nil }
            beatInBar = beat
            barInPhrase = bar
            self.bpm = bpm
        case let .phrase(name, _):
            phrase = name
        }
    }
}
