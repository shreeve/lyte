// The product's IP traffic-class vocabulary. These are complete IPv4 TOS
// bytes: the DSCP occupies the upper six bits and both ECN bits stay clear.
// Socket adapters apply the bytes; role-specific schedulers only map their
// own traffic classes onto these shared lanes.

public enum WireTos: Sendable {
    /// No differentiated-service marking (DSCP 0).
    public static let unmarked: UInt8 = 0x00

    /// Patient bulk/background traffic (CS1 / DSCP 8).
    public static let bulk: UInt8 = 0x20

    /// Fresh video and refinement traffic (CS5 / DSCP 40).
    public static let video: UInt8 = 0xA0

    /// Deadline traffic: control, input, audio, and repair (CS6 / DSCP 48).
    public static let protected: UInt8 = 0xC0

    /// Extract the six-bit DSCP codepoint from a complete TOS byte.
    public static func dscp(_ byte: UInt8) -> UInt8 {
        byte >> 2
    }
}
