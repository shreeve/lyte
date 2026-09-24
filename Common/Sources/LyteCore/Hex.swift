// One hex vocabulary for bytes and formatted unsigned integers. Byte
// strings are lowercase unless a diagnostic asks for uppercase.

public enum Hex {
    private static let lowerDigits = Array("0123456789abcdef".utf8)
    private static let upperDigits = Array("0123456789ABCDEF".utf8)

    /// Encodes bytes with two digits each and no separators or prefix.
    public static func string<Bytes: Sequence>(
        _ bytes: Bytes
    ) -> String where Bytes.Element == UInt8 {
        string(bytes, uppercase: false)
    }

    /// Encodes bytes with an explicit alphabet case.
    public static func string<Bytes: Sequence>(
        _ bytes: Bytes, uppercase: Bool
    ) -> String where Bytes.Element == UInt8 {
        let alphabet = uppercase ? upperDigits : lowerDigits
        var output: [UInt8] = []
        output.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Formats an unsigned integer with an explicit minimum digit width.
    /// Width never truncates; `prefix` adds the conventional lowercase `0x`.
    public static func string<Value: FixedWidthInteger & UnsignedInteger>(
        _ value: Value,
        width: Int = 0,
        uppercase: Bool = false,
        prefix: Bool = false
    ) -> String {
        let digits = String(value, radix: 16, uppercase: uppercase)
        let padding = String(repeating: "0", count: max(0, width - digits.count))
        return (prefix ? "0x" : "") + padding + digits
    }

    /// Parses hex, tolerating whitespace and an optional 0x prefix.
    /// Returns nil on odd length or a non-hex character.
    public static func bytes(_ hex: String) -> [UInt8]? {
        guard let digits = digits(of: hex), digits.count.isMultiple(of: 2)
        else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            output.append(digits[index] << 4 | digits[index + 1])
        }
        return output
    }

    /// Parses a hex u64 (0x-prefixed or bare) without JSON precision loss.
    public static func uint64(_ hex: String) -> UInt64? {
        guard let digits = digits(of: hex), (1...16).contains(digits.count)
        else { return nil }
        return digits.reduce(0) { $0 << 4 | UInt64($1) }
    }

    /// The one hex grammar both parsers share: whitespace ignored, an
    /// optional 0x prefix, then ASCII 0-9, a-f, A-F only — no sign, no
    /// fullwidth or other Unicode digits.
    private static func digits(of hex: String) -> [UInt8]? {
        var trimmed = hex.filter { !$0.isWhitespace }[...]
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            trimmed = trimmed.dropFirst(2)
        }
        var digits: [UInt8] = []
        digits.reserveCapacity(trimmed.count)
        for character in trimmed {
            switch character.asciiValue {
            case let ascii? where (0x30...0x39).contains(ascii):
                digits.append(ascii - 0x30)
            case let ascii? where (0x61...0x66).contains(ascii):
                digits.append(ascii - 0x61 + 10)
            case let ascii? where (0x41...0x46).contains(ascii):
                digits.append(ascii - 0x41 + 10)
            default:
                return nil
            }
        }
        return digits
    }

    public static func uint64String(_ value: UInt64) -> String {
        string(value, prefix: true)
    }
}
