// Everything the video interior can refuse at packetize time. The
// assembler never throws — it reports through its Event stream instead.

public enum VideoError: Error, Equatable, Sendable {
    /// The frame bytes are not a well-formed Annex-B access unit (must
    /// open on a start code and contain at least one VCL NAL unit).
    case frameNotFrameShaped
    /// The caller's isIDR claim disagrees with the bitstream (IRAP NAL
    /// presence); a wrong flag would poison the assembler's recovery.
    case idrFlagMismatch(claimed: Bool, derived: Bool)
}
