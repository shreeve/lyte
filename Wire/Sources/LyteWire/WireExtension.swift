// The TLV extension scheme (transport §3): flags bit0 appends
// `count:u8 (type:u8 len:u8 value)*` after the fixed envelope. Unknown types
// MUST be skipped, which is what lets a v1 peer carry v1.x fields it does
// not understand; new per-packet fields land as TLVs first and fold into a
// fixed v2 envelope only at a wire-major bump.

/// One type-length-value extension. The codec preserves unknown types
/// verbatim — "skip" is the consumer's rule, not the parser's — so a relay
/// or re-encoder never strips fields it does not understand.
public struct WireExtension: Hashable, Sendable {
    public let type: UInt8
    public let value: [UInt8]

    /// Throws when the value cannot be length-prefixed in one byte.
    public init(type: UInt8, value: [UInt8]) throws {
        guard value.count <= 0xFF else {
            throw WireError.extensionValueTooLong
        }
        self.type = type
        self.value = value
    }

    /// TLV type numbers reserved by the spec. W0 pins the numbers; the
    /// codecs that fill them arrive with their owning slices.
    public enum ReservedType {
        /// Never assigned — a zero type byte is always some other layer's
        /// zero-fill bug, and reserving it keeps that bug loud.
        public static let invalid: UInt8 = 0x00
        /// Connection ID for path migration (Lyte-UDP decision §8.4):
        /// identifies the session independent of the 4-tuple. Codec at W5.
        public static let connectionId: UInt8 = 0x01
        /// Wire major version, carried in the first handshake datagram
        /// (Lyte-UDP decision §8.3, replacing ALPN). Codec at W5.
        public static let wireVersion: UInt8 = 0x02
    }

    /// Encoded size on the wire: type + length + value bytes.
    public var encodedByteCount: Int {
        2 + value.count
    }
}
