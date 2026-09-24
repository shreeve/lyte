// ConnectionId: the session identity that survives 4-tuple changes. It
// rides as reserved TLV type 0x01 (`WireExtension.ReservedType.connectionId`)
// in both directions.
//
// TLV value: exactly 8 opaque random bytes. Not a u64 — equality is the
// only operation the protocol performs on it.

public enum ConnectionIdError: Error, Equatable {
    /// The reserved TLV carried a value that is not exactly 8 bytes.
    case invalidValueLength(Int)
    /// Two connection-ID TLVs in one envelope: an ambiguous identity is
    /// hostile input, never a tie to break silently.
    case duplicateTlv
}

public struct ConnectionId: Hashable, Sendable {
    /// The value width (see `tlv-reserved-types` in the vectors).
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
    /// Nil when the TLV is absent (a legal envelope); throws when it is
    /// present but malformed.
    public static func decode(
        extensions: [WireExtension]
    ) throws -> ConnectionId? {
        try WireExtension.uniqueValue(
            ofType: WireExtension.ReservedType.connectionId, in: extensions,
            duplicate: ConnectionIdError.duplicateTlv
        ).map(ConnectionId.init(bytes:))
    }
}
