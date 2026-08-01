// VideoPacketizer: one encoded Annex-B frame in, ready-to-send
// (envelope, payload) pairs out — the send half of the W2 video interior,
// sans-IO. Composes W1's pieces: the geometry table picks k/m for the
// frame's byte count and regime, FecEncoder produces the balanced shards
// (trailing data shard unpadded), and every envelope carries the full
// group geometry in its fec field so a single arrival sizes the
// assembler's buffers.
//
// Sequence allocation, pinned here: the packetizer owns a per-channel
// serial counter seeded by the caller at init (`firstSeq`) — the cleanest
// sans-IO shape, since a seq is channel state exactly like the counter a
// send loop would keep, and a value-type packetizer per channel is the
// natural owner. Allocation is **contiguous ascending in shard-index
// order** across each frame's k+m shards. That contiguity is wire
// contract, not convenience: the assembler infers a frame's full seq
// range from any one shard (seq − shardIndex … + totalShards), which is
// what makes its NACK-candidate lists (§4.7) and fec-impossible
// presumption immediate.

public struct VideoShard: Hashable, Sendable {
    public let envelope: Envelope
    /// The plaintext shard bytes (≤ 1112 B by construction).
    public let payload: [UInt8]

    public init(envelope: Envelope, payload: [UInt8]) {
        self.envelope = envelope
        self.payload = payload
    }

    /// The full datagram, header + bare shard (`--insecure` framing; W5
    /// seals the payload without changing the geometry).
    public func encodeDatagram() throws -> [UInt8] {
        try envelope.encode(plaintextShard: payload)
    }
}

public struct VideoPacketizer: Sendable {
    public let channel: ChannelId
    /// The next seq this packetizer will allocate — exposed so a caller
    /// resuming a channel (or a test crossing the u16 wrap) can verify
    /// the serial counter's position.
    public private(set) var nextSeq: ChannelSeq

    public init(
        channel: ChannelId = .videoActive,
        firstSeq: ChannelSeq = ChannelSeq(rawValue: 0)
    ) {
        self.channel = channel
        self.nextSeq = firstSeq
    }

    /// Packetizes one encoded frame into its k + m wire shards. Throws
    /// when the bytes are not frame-shaped Annex-B, when the caller's
    /// isIDR claim disagrees with the bitstream, or when the geometry
    /// table cannot protect a frame this large (`frameByteCeiling` is the
    /// sender's upstream guard; this keeps the failure loud, never a
    /// silently under-protected frame). On success the serial counter has
    /// advanced by exactly `shards.count`.
    public mutating func packetize(
        frame annexB: ArraySlice<UInt8>,
        frameNumber: FrameNumber,
        captureTimestamp: HostTimestamp,
        isIDR: Bool,
        regime: FecRegime
    ) throws -> [VideoShard] {
        let classification = AnnexBCheck.classifyFrame(annexB)
        guard classification.isFrameShaped else {
            throw VideoError.frameNotFrameShaped
        }
        let derivedIdr = classification.containsIrap
        guard isIDR == derivedIdr else {
            throw VideoError.idrFlagMismatch(claimed: isIDR, derived: derivedIdr)
        }

        let geometry = try FecGeometryTable.geometry(
            forGroupByteCount: annexB.count, regime: regime
        )
        let payloads = try FecEncoder.encode(group: annexB, geometry: geometry)

        var shards: [VideoShard] = []
        shards.reserveCapacity(payloads.count)
        for (index, payload) in payloads.enumerated() {
            let field = try FecField.reedSolomonShard(index, of: geometry)
            let envelope = Envelope(
                channel: channel,
                seq: nextSeq,
                frame: frameNumber,
                timestamp: captureTimestamp.microseconds,
                fec: field.encoded
            )
            shards.append(VideoShard(envelope: envelope, payload: payload))
            nextSeq = nextSeq.next
        }
        return shards
    }

    public mutating func packetize(
        frame annexB: [UInt8],
        frameNumber: FrameNumber,
        captureTimestamp: HostTimestamp,
        isIDR: Bool,
        regime: FecRegime
    ) throws -> [VideoShard] {
        try packetize(
            frame: annexB[...],
            frameNumber: frameNumber,
            captureTimestamp: captureTimestamp,
            isIDR: isIDR,
            regime: regime
        )
    }
}
