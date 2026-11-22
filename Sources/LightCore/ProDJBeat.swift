import Foundation

/// Passive interpretation of the 96-byte beat announcements emitted by
/// Pro DJ Link players. Based on Deep Symmetry's published packet analysis:
/// https://djl-analysis.deepsymmetry.org/djl-analysis/beats.html
/// This never announces a virtual deck or sends commands to a console.
public struct ProDJBeat: Equatable, Sendable {
    public let deviceName: String
    public let deck: Int
    public let bpm: Double
    public let beatWithinBar: Int

    public static func parse(_ bytes: [UInt8]) -> ProDJBeat? {
        let magic: [UInt8] = [0x51, 0x73, 0x70, 0x74, 0x31, 0x57, 0x6d, 0x4a, 0x4f, 0x4c]
        guard bytes.count >= 0x60,
              Array(bytes.prefix(10)) == magic,
              bytes[0x0a] == 0x28,
              bytes[0x1f] == 1, bytes[0x20] == 0,
              (1...4).contains(Int(bytes[0x21])) else { return nil }
        let length = Int(bytes[0x22]) * 256 + Int(bytes[0x23])
        guard length >= 0x3c, length <= bytes.count - 0x24 else { return nil }
        let rawBPM = Int(bytes[0x5a]) * 256 + Int(bytes[0x5b])
        let pitch = Int(bytes[0x55]) * 65_536 + Int(bytes[0x56]) * 256 + Int(bytes[0x57])
        let bpm = Double(rawBPM) / 100 * Double(pitch) / 1_048_576
        let bar = Int(bytes[0x5c])
        guard rawBPM != 0xffff, pitch > 0, pitch <= 2_097_152,
              bpm.isFinite, (20...400).contains(bpm), (1...4).contains(bar) else { return nil }
        let nameBytes = bytes[0x0b..<0x1f].prefix { $0 != 0 }
        let name = String(bytes: nameBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Pro DJ Link"
        return ProDJBeat(deviceName: name.isEmpty ? "Pro DJ Link" : name,
                         deck: Int(bytes[0x21]), bpm: bpm, beatWithinBar: bar)
    }
}
