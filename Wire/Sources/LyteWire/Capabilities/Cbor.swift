// The minimal deterministic CBOR codec (W7) beneath the capability
// layer. This is NOT a general CBOR library: it implements exactly the
// Lyte capability profile — a subset of RFC 8949 under the §4.2.1 core
// deterministic encoding requirements — and rejects everything outside
// it. Determinism is load-bearing: the capability declaration is a
// frozen wire artifact both ends must produce byte-identically, and a
// canonical form is what lets the vectors pin it.
//
// Profile (accepted major types):
//   0  unsigned integer
//   1  negative integer (stored as the encoded argument n; value −1−n)
//   2  byte string
//   3  text string (valid UTF-8, enforced by byte-exact re-encode)
//   4  array
//   5  map (keys strictly ascending in bytewise order of their
//      encodings — sortedness and no-duplicates in one check)
//   7  only false / true / null (0xF4 / 0xF5 / 0xF6)
//
// Excluded and rejected: indefinite lengths, tags (major 6), floats
// and every other simple value. Future wire minors extend the
// capability MAP with new keys, not the profile — an unknown key's
// value must still be a profile item, which is what keeps "skip
// unknown keys" implementable forever (transport pillar §3's
// forward-compatibility contract).
//
// Deterministic-encoding rules enforced on decode (and produced on
// encode): shortest-form arguments, definite lengths only, map keys
// strictly ascending bytewise. A non-canonical encoding REJECTS even
// when it is well-formed CBOR — two ends that disagree about bytes are
// a wire bug this layer refuses to paper over.

/// One CBOR data item within the Lyte capability profile.
public indirect enum CborValue: Hashable, Sendable {
    case unsigned(UInt64)
    /// The encoded argument n; the represented value is −1 − n.
    case negative(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CborValue])
    /// Entries in canonical order (strictly ascending encoded keys) —
    /// `Cbor.encode` sorts and rejects duplicates, `Cbor.decode` only
    /// ever produces canonical order.
    case map([CborMapEntry])
    case bool(Bool)
    case null
}

/// One map entry — a struct rather than a tuple so maps are Hashable.
public struct CborMapEntry: Hashable, Sendable {
    public var key: CborValue
    public var value: CborValue

    public init(key: CborValue, value: CborValue) {
        self.key = key
        self.value = value
    }
}

/// Everything the codec can refuse. Hostile bytes throw, never trap.
public enum CborError: Error, Hashable, Sendable {
    case truncatedItem
    case trailingBytes
    /// Major type 6, a float, an unassigned simple value, or an
    /// indefinite-length marker — outside the capability profile.
    case unsupportedItem(UInt8)
    /// A well-formed argument that is not the shortest form.
    case nonCanonicalArgument
    /// Map keys out of bytewise order or repeated.
    case misorderedMapKeys
    case duplicateMapKey
    /// Text bytes that are not valid UTF-8 (detected by byte-exact
    /// re-encode of the decoded string).
    case invalidUtf8
    case nestingTooDeep
}

public enum Cbor {
    /// Nesting bound for decode — capability data is a map of scalars
    /// and flat arrays; anything deeper is hostile or a bug.
    public static let maxNestingDepth = 8

    // MARK: - Encode

    /// Deterministic encode. Throws only on a map with duplicate keys —
    /// every other value encodes.
    public static func encode(_ value: CborValue) throws -> [UInt8] {
        var out: [UInt8] = []
        try encode(value, into: &out)
        return out
    }

    private static func encode(
        _ value: CborValue, into out: inout [UInt8]
    ) throws {
        switch value {
        case .unsigned(let v):
            appendHead(major: 0, argument: v, to: &out)
        case .negative(let n):
            appendHead(major: 1, argument: n, to: &out)
        case .bytes(let b):
            appendHead(major: 2, argument: UInt64(b.count), to: &out)
            out.append(contentsOf: b)
        case .text(let s):
            let utf8 = Array(s.utf8)
            appendHead(major: 3, argument: UInt64(utf8.count), to: &out)
            out.append(contentsOf: utf8)
        case .array(let items):
            appendHead(major: 4, argument: UInt64(items.count), to: &out)
            for item in items { try encode(item, into: &out) }
        case .map(let entries):
            // Canonical order regardless of construction order; equal
            // encoded keys are duplicates and refuse to encode.
            let encodedKeys = try entries.map { try encode($0.key) }
            let order = Array(entries.indices).sorted {
                bytewiseAscending(encodedKeys[$0], encodedKeys[$1])
            }
            for (a, b) in zip(order, order.dropFirst())
            where encodedKeys[a] == encodedKeys[b] {
                throw CborError.duplicateMapKey
            }
            appendHead(major: 5, argument: UInt64(entries.count), to: &out)
            for index in order {
                out.append(contentsOf: encodedKeys[index])
                try encode(entries[index].value, into: &out)
            }
        case .bool(let b):
            out.append(b ? 0xF5 : 0xF4)
        case .null:
            out.append(0xF6)
        }
    }

    /// Shortest-form head: major type in the top 3 bits, argument in
    /// the fewest additional-info bytes that hold it (RFC 8949 §4.2.1).
    private static func appendHead(
        major: UInt8, argument: UInt64, to out: inout [UInt8]
    ) {
        let base = major << 5
        switch argument {
        case 0..<24:
            out.append(base | UInt8(argument))
        case 24...0xFF:
            out.append(base | 24)
            out.append(UInt8(argument))
        case 0x100...0xFFFF:
            out.append(base | 25)
            out.append(UInt8(argument >> 8))
            out.append(UInt8(truncatingIfNeeded: argument))
        case 0x1_0000...0xFFFF_FFFF:
            out.append(base | 26)
            for shift in stride(from: 24, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: argument >> shift))
            }
        default:
            out.append(base | 27)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: argument >> shift))
            }
        }
    }

    // MARK: - Decode

    /// Whole-buffer decode: exactly one item, trailing bytes reject.
    public static func decode(_ bytes: ArraySlice<UInt8>) throws -> CborValue {
        var cursor = bytes.startIndex
        let value = try decodeItem(bytes, cursor: &cursor, depth: 0)
        guard cursor == bytes.endIndex else {
            throw CborError.trailingBytes
        }
        return value
    }

    public static func decode(_ bytes: [UInt8]) throws -> CborValue {
        try decode(bytes[...])
    }

    private static func decodeItem(
        _ bytes: ArraySlice<UInt8>, cursor: inout Int, depth: Int
    ) throws -> CborValue {
        guard depth < maxNestingDepth else {
            throw CborError.nestingTooDeep
        }
        guard cursor < bytes.endIndex else {
            throw CborError.truncatedItem
        }
        let head = bytes[cursor]
        let major = head >> 5
        let info = head & 0x1F
        cursor += 1

        if major == 7 {
            switch head {
            case 0xF4: return .bool(false)
            case 0xF5: return .bool(true)
            case 0xF6: return .null
            default: throw CborError.unsupportedItem(head)
            }
        }
        guard major <= 5 else {
            throw CborError.unsupportedItem(head)
        }

        let argument = try decodeArgument(
            bytes, cursor: &cursor, info: info, head: head
        )
        switch major {
        case 0:
            return .unsigned(argument)
        case 1:
            return .negative(argument)
        case 2:
            return .bytes(try take(bytes, cursor: &cursor, count: argument))
        case 3:
            let raw = try take(bytes, cursor: &cursor, count: argument)
            let text = String(decoding: raw, as: UTF8.self)
            // Invalid UTF-8 mangles into U+FFFD; byte-exact re-encode
            // is the Foundation-free validity check AND the canonical
            // round-trip guarantee in one.
            guard Array(text.utf8) == raw else {
                throw CborError.invalidUtf8
            }
            return .text(text)
        case 4:
            // Every element costs ≥1 byte, so a count beyond the
            // remaining bytes can never complete — refuse before
            // reserving hostile capacity.
            guard argument <= UInt64(bytes.endIndex - cursor) else {
                throw CborError.truncatedItem
            }
            var items: [CborValue] = []
            items.reserveCapacity(Int(argument))
            for _ in 0..<argument {
                items.append(
                    try decodeItem(bytes, cursor: &cursor, depth: depth + 1)
                )
            }
            return .array(items)
        default:
            guard argument <= UInt64(bytes.endIndex - cursor) / 2 else {
                throw CborError.truncatedItem
            }
            var entries: [CborMapEntry] = []
            entries.reserveCapacity(Int(argument))
            var previousKey: [UInt8]? = nil
            for _ in 0..<argument {
                let keyStart = cursor
                let key = try decodeItem(
                    bytes, cursor: &cursor, depth: depth + 1
                )
                let encodedKey = Array(bytes[keyStart..<cursor])
                if let previous = previousKey {
                    if previous == encodedKey {
                        throw CborError.duplicateMapKey
                    }
                    guard bytewiseAscending(previous, encodedKey) else {
                        throw CborError.misorderedMapKeys
                    }
                }
                previousKey = encodedKey
                let value = try decodeItem(
                    bytes, cursor: &cursor, depth: depth + 1
                )
                entries.append(CborMapEntry(key: key, value: value))
            }
            return .map(entries)
        }
    }

    /// Decodes an argument and enforces the shortest form. `info`
    /// 28–30 are reserved encodings, 31 the indefinite marker — all
    /// outside the profile.
    private static func decodeArgument(
        _ bytes: ArraySlice<UInt8>, cursor: inout Int,
        info: UInt8, head: UInt8
    ) throws -> UInt64 {
        switch info {
        case 0..<24:
            return UInt64(info)
        case 24, 25, 26, 27:
            let width = 1 << Int(info - 24)
            guard cursor + width <= bytes.endIndex else {
                throw CborError.truncatedItem
            }
            var value: UInt64 = 0
            for _ in 0..<width {
                value = value << 8 | UInt64(bytes[cursor])
                cursor += 1
            }
            let floor: UInt64 = switch info {
            case 24: 24
            case 25: 0x100
            case 26: 0x1_0000
            default: 0x1_0000_0000
            }
            guard value >= floor else {
                throw CborError.nonCanonicalArgument
            }
            return value
        default:
            throw CborError.unsupportedItem(head)
        }
    }

    private static func take(
        _ bytes: ArraySlice<UInt8>, cursor: inout Int, count: UInt64
    ) throws -> [UInt8] {
        guard count <= UInt64(bytes.endIndex - cursor) else {
            throw CborError.truncatedItem
        }
        let end = cursor + Int(count)
        defer { cursor = end }
        return Array(bytes[cursor..<end])
    }

    /// RFC 8949 §4.2.1 map-key order: bytewise lexicographic over the
    /// complete encodings (a strict prefix sorts first).
    static func bytewiseAscending(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            return x < y
        }
        return a.count < b.count
    }
}
