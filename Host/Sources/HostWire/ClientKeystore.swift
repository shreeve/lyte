// ClientKeystore: the paired-clients trust store as a value (format,
// parsing, membership), sans-IO. The file lives at
// ~/.config/lyte/paired_clients (0600). Pairing pins CLIENT keys; it
// never touches the host's own noise_static.key.
//
// Format:
//   • UTF-8 text, one record per line.
//   • A record is 64 lowercase ASCII hex bytes (the client's X25519
//     static public key), optionally followed by whitespace and a
//     free-form note (lyte-host writes the pairing instant). The key is
//     judged byte by byte: a digit carrying a combining mark is one
//     Character that compares inside "0"..."9", yet it is no hex digit.
//   • Blank lines and lines starting with `#` are ignored.
//   • Anything else is a loud parse error, never skipped: a malformed
//     store is someone else's write, and pretending a paired client
//     away (or in) is a trust decision no parser gets to make.

import LyteCore

public struct ClientKeystore: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// 32 raw bytes.
        public var publicKey: [UInt8]
        /// The rest of the line, note only (no leading whitespace).
        public var note: String

        public init(publicKey: [UInt8], note: String = "") {
            self.publicKey = publicKey
            self.note = note
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        /// (1-based line, its text), verbatim for the operator.
        case malformedLine(Int, String)
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var publicKeys: [[UInt8]] { entries.map(\.publicKey) }

    public func contains(_ publicKey: [UInt8]) -> Bool {
        entries.contains { $0.publicKey == publicKey }
    }

    /// Appends, unless the key is already pinned (re-pairing the same
    /// client is a no-op, not a duplicate line). Returns whether the
    /// store changed.
    @discardableResult
    public mutating func pin(_ publicKey: [UInt8], note: String = "") -> Bool {
        guard !contains(publicKey) else { return false }
        entries.append(Entry(publicKey: publicKey, note: note))
        return true
    }

    // MARK: The wire between memory and the file

    public static func parse(_ text: String) throws -> ClientKeystore {
        var store = ClientKeystore()
        for (index, rawLine) in text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            let line = rawLine.trimmed
            if line.isEmpty || line.hasPrefix("#") { continue }
            let utf8 = line.utf8
            let hex = utf8.prefix(64)
            let rest = utf8.dropFirst(64)
            guard hex.count == 64,
                  let key = bytes(fromLowercaseHex: hex),
                  rest.isEmpty || rest.first == 0x20 || rest.first == 0x09
            else {
                throw ParseError.malformedLine(index + 1, String(rawLine))
            }
            store.pin(key, note: String(
                String(decoding: rest, as: UTF8.self).trimmed))
        }
        return store
    }

    /// The full file contents, header comment included. Rewriting the
    /// whole file (rather than appending) keeps serialize(parse(x))
    /// canonical and makes a torn write detectable as a parse error.
    public func serialized() -> String {
        var lines = [
            "# lyte-host paired clients — one static public key per line",
            "# (64 hex chars, optional note). Managed by `lyte-host --pair`.",
        ]
        for entry in entries {
            let hex = Hex.string(entry.publicKey)
            lines.append(
                entry.note.isEmpty ? hex : hex + " \(entry.note)"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func bytes(
        fromLowercaseHex hex: Substring.UTF8View.SubSequence
    ) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var iterator = hex.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(),
                  let h = lowercaseHexValue(high),
                  let l = lowercaseHexValue(low)
            else { return nil }
            out.append(h << 4 | l)
        }
        return out
    }

    /// Strict lowercase ASCII hex: an uppercase key is a parse error.
    private static func lowercaseHexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x61...0x66: return byte - 0x57
        default: return nil
        }
    }
}

private extension StringProtocol {
    /// Foundation-free whitespace trim (HostWire is sans-Foundation).
    var trimmed: Substring {
        var slice = Substring(self)
        while let first = slice.first, first == " " || first == "\t"
                || first == "\r" {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == " " || last == "\t"
                || last == "\r" {
            slice = slice.dropLast()
        }
        return slice
    }
}
