// ConnectionId: the session identity that survives 4-tuple changes
// (resiliency §6, Lyte-UDP decision §8.4). The fixed 24-byte envelope has
// no room for it, so it rides as the reserved TLV type 0x01 that W0 pinned
// (`WireExtension.ReservedType.connectionId`, value 8 bytes per the
// `tlv-reserved-types` vector). W0 reserved the number only; HS-12 landed
// this VALUE codec host-side, and the codec-unification slice promotes it
// here verbatim — the client tags its datagrams with the same TLV and must
// recognize the host's, or migration cannot be attributed in either
// direction.
//
// TLV value layout: exactly 8 opaque random bytes. Not a u64 — no
// endianness, no arithmetic, no structure; equality is the only operation
// the protocol performs on it. 64 random bits make collision between two
// concurrently-paired sessions a non-event (the host has single-digit
// sessions, not 2^32).

public enum ConnectionIdError: Error, Equatable {
    /// The reserved TLV carried a value that is not exactly 8 bytes.
    case invalidValueLength(Int)
    /// Two connection-ID TLVs in one envelope: an ambiguous identity is
    /// hostile input, never a tie to break silently.
    case duplicateTlv
}

public struct ConnectionId: Hashable, Sendable {
    /// The W0-pinned value width (see `tlv-reserved-types` in the vectors).
    public static let byteCount = 8

    /// Exactly `byteCount` opaque bytes.
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw ConnectionIdError.invalidValueLength(bytes.count)
        }
        self.bytes = bytes
    }

    /// A fresh random identity. The generator is injected so tests are
    /// deterministic and production uses the system RNG.
    public static func random(
        using rng: inout some RandomNumberGenerator
    ) -> ConnectionId {
        var word = rng.next() as UInt64
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            bytes.append(UInt8(truncatingIfNeeded: word))
            word >>= 8
        }
        // The length invariant holds by construction; the throwing init
        // exists for wire-derived bytes, not for this path.
        return try! ConnectionId(bytes: bytes)
    }

    // MARK: TLV value codec

    /// The envelope extension carrying this identity. Cannot fail: an
    /// 8-byte value always fits the one-byte TLV length prefix.
    public var wireExtension: WireExtension {
        try! WireExtension(
            type: WireExtension.ReservedType.connectionId, value: bytes
        )
    }

    /// Extracts the connection ID from a decoded envelope's extensions.
    /// Nil when the TLV is absent (a legal envelope — pre-migration
    /// datagrams and W0-era peers carry none); throws when it is present
    /// but malformed, per the loud-decode rule.
    public static func decode(
        extensions: [WireExtension]
    ) throws -> ConnectionId? {
        let matches = extensions.filter {
            $0.type == WireExtension.ReservedType.connectionId
        }
        guard let match = matches.first else { return nil }
        guard matches.count == 1 else {
            throw ConnectionIdError.duplicateTlv
        }
        return try ConnectionId(bytes: match.value)
    }
}
