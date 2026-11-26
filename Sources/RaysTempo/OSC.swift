import Foundation

/// One Open Sound Control 1.0 message, with the argument types openDJ's events use
/// (32-bit integers, 32-bit floats and strings).
public struct OSCMessage: Equatable, Sendable {
    public enum Argument: Equatable, Sendable {
        case int(Int32)
        case float(Float)
        case string(String)
    }

    public var address: String
    public var arguments: [Argument]

    public init(_ address: String, _ arguments: [Argument] = []) {
        self.address = address
        self.arguments = arguments
    }

    /// The message as one UDP packet.
    public func encoded() -> Data {
        var out = Data()
        Self.append(address, to: &out)
        let tags = arguments.map { argument -> String in
            switch argument {
            case .int: return "i"
            case .float: return "f"
            case .string: return "s"
            }
        }
        Self.append("," + tags.joined(), to: &out)
        for argument in arguments {
            switch argument {
            case let .int(value): Self.append(UInt32(bitPattern: value), to: &out)
            case let .float(value): Self.append(value.bitPattern, to: &out)
            case let .string(value): Self.append(value, to: &out)
            }
        }
        return out
    }

    /// Several messages as one packet, for the receiver to apply in order as soon as it arrives.
    public static func bundle(_ messages: [OSCMessage]) -> Data {
        var out = Data(bundleHeader)
        out.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])  // time tag "immediately"
        for message in messages {
            let element = message.encoded()
            append(UInt32(element.count), to: &out)
            out.append(element)
        }
        return out
    }

    /// The messages in a UDP packet, bundles opened in order. A packet that isn't well-formed OSC,
    /// or that carries an argument type not listed in ``Argument``, gives nothing.
    public static func decode(_ packet: Data) -> [OSCMessage] {
        var out: [OSCMessage] = []
        return read([UInt8](packet)[...], depth: 0, into: &out) ? out : []
    }

    private static let bundleHeader: [UInt8] = Array("#bundle".utf8) + [0]
    private static let maxBundleDepth = 8

    private static func read(_ bytes: ArraySlice<UInt8>, depth: Int, into out: inout [OSCMessage]) -> Bool {
        var reader = Reader(bytes: bytes)
        if bytes.starts(with: bundleHeader) {
            guard depth < maxBundleDepth, reader.take(16) != nil else { return false }
            while !reader.isAtEnd {
                guard let size = reader.word(), size <= UInt32(Int32.max), let element = reader.take(Int(size)),
                    read(element, depth: depth + 1, into: &out)
                else { return false }
            }
            return true
        }
        guard let address = reader.string(), address.hasPrefix("/"), let tags = reader.string(), tags.hasPrefix(",")
        else { return false }
        var arguments: [Argument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let word = reader.word() else { return false }
                arguments.append(.int(Int32(bitPattern: word)))
            case "f":
                guard let word = reader.word() else { return false }
                arguments.append(.float(Float(bitPattern: word)))
            case "s":
                guard let string = reader.string() else { return false }
                arguments.append(.string(string))
            default: return false
            }
        }
        out.append(OSCMessage(address, arguments))
        return true
    }

    /// OSC strings end with a zero byte and are padded with more to a multiple of four bytes.
    private static func append(_ string: String, to out: inout Data) {
        let bytes = string.utf8.prefix { $0 != 0 }
        out.append(contentsOf: bytes)
        out.append(contentsOf: [UInt8](repeating: 0, count: 4 - bytes.count % 4))
    }

    private static func append(_ word: UInt32, to out: inout Data) {
        out.append(contentsOf: [UInt8(word >> 24), UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF)])
    }

    private struct Reader {
        var bytes: ArraySlice<UInt8>

        var isAtEnd: Bool { bytes.isEmpty }

        mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, count <= bytes.count else { return nil }
            defer { bytes = bytes.dropFirst(count) }
            return bytes.prefix(count)
        }

        mutating func word() -> UInt32? {
            take(4)?.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }

        mutating func string() -> String? {
            guard let end = bytes.firstIndex(of: 0), let text = String(bytes: bytes[..<end], encoding: .utf8),
                take((end - bytes.startIndex) / 4 * 4 + 4) != nil
            else { return nil }
            return text
        }
    }
}
