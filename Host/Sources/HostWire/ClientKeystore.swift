// ClientKeystore (HS-9): the paired-clients trust store as a value —
// the text format, parsing, and membership logic, kept sans-IO so the
// format is pinned by cross-platform tests. The file itself lives at
// ~/.config/lyte-host/paired_clients (0600, beside the portal token and
// the host static — which this store NEVER replaces: pairing pins
// CLIENT keys; the host's own noise_static.key is untouchable).
//
// Format, frozen here:
//   • UTF-8 text, one record per line.
//   • A record is 64 lowercase hex characters (the client's X25519
//     static public key), optionally followed by whitespace and a
//     free-form note (lyte-host writes the pairing instant).
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
        /// (1-based line, its text) — surfaced verbatim so the operator
        /// can find the damage.
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
            let hex = line.prefix(64)
            let rest = line.dropFirst(64)
            guard hex.count == 64,
                  let key = bytes(fromLowercaseHex: hex),
                  rest.isEmpty || rest.first == " " || rest.first == "\t"
            else {
                throw ParseError.malformedLine(index + 1, String(rawLine))
            }
            store.pin(key, note: String(rest.trimmed))
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
                entry.note.isEmpty ? hex : hex + " " + entry.note
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func bytes(
        fromLowercaseHex hex: Substring
    ) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var iterator = hex.makeIterator()
        while let high = iterator.next() {
            guard let low = iterator.next(),
                  let h = high.lowercaseHexValue,
                  let l = low.lowercaseHexValue
            else { return nil }
            out.append(UInt8(h << 4 | l))
        }
        return out
    }
}

private extension Character {
    /// Strict lowercase hex — an uppercase key is not ours and parses
    /// loud, per the malformed-store rule.
    var lowercaseHexValue: Int? {
        switch self {
        case "0"..."9": return Int(unicodeScalars.first!.value - 48)
        case "a"..."f": return Int(unicodeScalars.first!.value - 87)
        default: return nil
        }
    }
}

private extension StringProtocol {
    /// Foundation-free whitespace trim (HostWire builds everywhere and
    /// keeps Wire's no-Foundation spirit).
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
