// Everything the video interior can refuse at packetize time. Same
// doctrine as WireError/FecError: bad input throws, never traps. The
// assembler never throws — a receiver cannot refuse the network — it
// reports through its Event stream instead.

public enum VideoError: Error, Equatable, Sendable {
    /// The frame bytes are not a well-formed Annex-B access unit (must
    /// open on a start code and contain at least one VCL NAL unit).
    case frameNotFrameShaped
    /// The caller's isIDR claim disagrees with the bitstream (IRAP NAL
    /// presence). Kept loud: a wrong flag would poison the assembler's
    /// recovery discipline downstream.
    case idrFlagMismatch(claimed: Bool, derived: Bool)
}
