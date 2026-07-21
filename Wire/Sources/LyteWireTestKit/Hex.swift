// Hex helpers for vector files and test assertions. Lowercase, no
// separators — the canonical form every vector file uses.

public enum Hex {
    public static func string(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { byteToHex($0) }.joined()
    }

    /// Parses hex, tolerating whitespace and an optional 0x prefix.
    /// Returns nil on odd length or a non-hex character.
    public static func bytes(_ hex: String) -> [UInt8]? {
        var digits = [UInt8]()
        var trimmed = hex.filter { !$0.isWhitespace }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            trimmed = String(trimmed.dropFirst(2))
        }
        for character in trimmed {
            guard let digit = character.hexDigitValue, digit < 16 else {
                return nil
            }
            digits.append(UInt8(digit))
        }
        guard digits.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            out.append(digits[i] << 4 | digits[i + 1])
        }
        return out
    }

    /// Parses a hex-encoded u64 ("0x..." or bare), for timestamp/fec fields
    /// that would lose precision as JSON numbers.
    public static func uint64(_ hex: String) -> UInt64? {
        var trimmed = hex.filter { !$0.isWhitespace }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            trimmed = String(trimmed.dropFirst(2))
        }
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return nil }
        return UInt64(trimmed, radix: 16)
    }

    public static func uint64String(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: false)
    }

    private static func byteToHex(_ byte: UInt8) -> String {
        let table = "0123456789abcdef"
        let hi = table[table.index(table.startIndex, offsetBy: Int(byte >> 4))]
        let lo = table[table.index(table.startIndex, offsetBy: Int(byte & 0xF))]
        return String([hi, lo])
    }
}
