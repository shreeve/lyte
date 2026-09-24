// There is no ALPN to carry `lyte/1`, so the wire major version rides as
// the first byte of the first Noise handshake payload, and the responder
// echoes it in message 2.

public enum WireVersion {
    /// The wire major version this module encodes and decodes. The two
    /// ends' majors must match exactly — a mismatch aborts the handshake;
    /// nothing is negotiated. A true incompatible break bumps this.
    public static let major: UInt8 = 1
}
