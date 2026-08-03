// One fully reassembled video frame, ready for the decoder — what
// VideoAssembler emits and client CL-2 feeds to the existing
// VideoSampleFactory/render path (build plan §4.3). The GameStream-era
// DecodeUnit's buffer-type chain, RTP timestamp, and Sunshine latency
// fields are deliberately gone: LyteWire reproduces the packetized
// Annex-B access unit byte-exact and lets VideoToolbox do its own NAL
// bookkeeping.

public struct DecodeUnit: Hashable, Sendable {
    /// The envelope `frame` field this unit was assembled from.
    public let frameNumber: FrameNumber
    /// Host capture timestamp (PipeWire monotonic µs), carried verbatim
    /// from the frame's envelopes.
    public let timestamp: HostTimestamp
    /// Derived from the recovered bytes (IRAP NAL presence), never from
    /// transport metadata — the bytes are the authority.
    public let isIDR: Bool
    /// The frame's Annex-B bytes, byte-identical to what the packetizer
    /// was handed.
    public let annexB: [UInt8]

    public init(
        frameNumber: FrameNumber,
        timestamp: HostTimestamp,
        isIDR: Bool,
        annexB: [UInt8]
    ) {
        self.frameNumber = frameNumber
        self.timestamp = timestamp
        self.isIDR = isIDR
        self.annexB = annexB
    }
}
