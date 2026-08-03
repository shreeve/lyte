// Wire versioning. There is no ALPN to carry `lyte/1` (Lyte-UDP decision
// §8.3), so the wire major version rides in the first handshake datagram —
// built at W5, but the number and its TLV slot are reserved here so every
// slice agrees on them from day one.

public enum WireVersion {
    /// The wire major version this module encodes and decodes. A true
    /// incompatible break bumps this and is negotiated at handshake time,
    /// never mid-session.
    public static let major: UInt8 = 1
}
