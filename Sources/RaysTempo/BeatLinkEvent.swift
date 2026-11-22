import Foundation

/// Versioned line protocol from the bundled, headless Beat Link adapter.
/// Decoding is deliberately strict at the point where an event can change Link tempo.
public struct BeatLinkEvent: Decodable, Equatable, Sendable {
    public let type: String
    public let timestamp: Double
    public let deck: Int?
    public let name: String?
    public let bpm: Double?
    public let beat: Int?
    public let master: Bool?
    public let playing: Bool?
    public let present: Bool?
    public let state: String?
    public let message: String?

    public static func parse(_ line: String) -> BeatLinkEvent? {
        guard line.hasPrefix("LSBLT "), line.utf8.count <= 16_384,
              let data = line.dropFirst(6).data(using: .utf8),
              let event = try? JSONDecoder().decode(Self.self, from: data),
              event.timestamp.isFinite else { return nil }
        return event
    }

    /// Auto follows only a playing, freshly confirmed master. A deliberate deck
    /// override still requires fresh playing status; no guessed deck on lost master.
    public func acceptedBeat(deck selectedDeck: Int = 0, now: TimeInterval = Date().timeIntervalSince1970) -> ProDJBeat? {
        guard type == "beat", playing == true,
              let deck, (1...4).contains(deck),
              selectedDeck == 0 ? master == true : selectedDeck == deck,
              let bpm, bpm.isFinite, (20...400).contains(bpm),
              let beat, (1...4).contains(beat),
              now.isFinite, now - timestamp >= -0.25, now - timestamp < 0.5 else { return nil }
        return ProDJBeat(deviceName: name?.isEmpty == false ? name! : "Pro DJ Link",
                         deck: deck, bpm: bpm, beatWithinBar: beat)
    }
}
