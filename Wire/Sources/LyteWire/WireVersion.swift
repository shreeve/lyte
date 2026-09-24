// There is no ALPN to carry `lyte/1`, so the wire major version rides in
// the first handshake datagram.

public enum WireVersion {
    /// The wire major version this module encodes and decodes. A true
    /// incompatible break bumps this and is negotiated at handshake time,
    /// never mid-session.
    public static let major: UInt8 = 1
}
