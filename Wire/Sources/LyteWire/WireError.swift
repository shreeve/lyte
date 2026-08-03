// Everything a codec can refuse. Decoding malformed or hostile bytes must
// throw one of these — never trap — so a datagram off the network can be fed
// to `Envelope.decode` unvalidated.

public enum WireError: Error, Equatable, Sendable {
    /// Fewer than the fixed 24 envelope bytes.
    case truncatedEnvelope
    /// The flags byte promised a TLV block the datagram does not contain.
    case truncatedExtensions
    /// More than 255 TLVs; the count prefix is one byte.
    case tooManyExtensions
    /// A TLV value longer than 255 bytes; the length prefix is one byte.
    case extensionValueTooLong
    /// Plaintext shard exceeds `WireBudget.maxPlaintextShardByteCount`.
    case shardOverBudget(Int)
    /// Wire payload exceeds `WireBudget.maxWirePayloadByteCount`.
    case payloadOverBudget(Int)
    /// The assembled datagram exceeds `WireBudget.maxDatagramByteCount`.
    case datagramOverBudget(Int)
}
