// The TLV extension scheme: flags bit0 appends
// `count:u8 (type:u8 len:u8 value)*` after the fixed envelope. Unknown types
// MUST be skipped, so a v1 peer tolerates v1.x fields it does not understand.

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

    /// TLV type numbers reserved by the spec.
    public enum ReservedType {
        /// Never assigned — a zero type byte is always some other layer's
        /// zero-fill bug, and reserving it keeps that bug loud.
        public static let invalid: UInt8 = 0x00
        /// Connection ID for path migration: identifies the session
        /// independent of the 4-tuple.
        public static let connectionId: UInt8 = 0x01
        /// Wire major version. Reserved and unused in v1: nothing sends
        /// it, because the major rides the first Noise handshake payload
        /// byte (`NoiseSession`).
        public static let wireVersion: UInt8 = 0x02
        /// u32 LE: the seq of the last input event injected before this
        /// frame's capture, stamped per shard; codec in `LastInputSeqTlv`.
        public static let lastInputSeq: UInt8 = 0x03
    }

    /// Encoded size on the wire: type + length + value bytes.
    public var encodedByteCount: Int {
        2 + value.count
    }
}
