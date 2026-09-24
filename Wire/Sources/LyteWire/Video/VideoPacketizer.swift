// VideoPacketizer: one encoded Annex-B frame in, ready-to-send
// (envelope, payload) pairs out, sans-IO. The geometry table picks k/m,
// FecEncoder produces the balanced shards, and every envelope carries the
// full group geometry in its fec field.
//
// The packetizer owns a per-channel serial counter seeded at init
// (`firstSeq`). Seqs are allocated contiguous ascending in shard-index
// order across each frame's k+m shards — wire contract: the assembler
// infers a frame's full seq range from any one shard
// (seq − shardIndex … + totalShards).

import LyteCore

public struct VideoShard: Hashable, Sendable {
    public let envelope: Envelope
    /// The plaintext shard bytes (≤ 1112 B by construction).
    public let payload: [UInt8]

    public init(envelope: Envelope, payload: [UInt8]) {
        self.envelope = envelope
        self.payload = payload
    }

    /// The test/vector datagram, header + bare shard. Live sessions seal
    /// the payload without changing this geometry.
    public func encodeDatagram() throws -> [UInt8] {
        try envelope.encode(plaintextShard: payload)
    }
}

/// One shard of a packetized frame before seq allocation: the envelope
/// fec field (full group geometry + shard index) and the plaintext bytes.
public struct VideoShardPayload: Hashable, Sendable {
    public let fec: UInt64
    public let payload: [UInt8]

    public init(fec: UInt64, payload: [UInt8]) {
        self.fec = fec
        self.payload = payload
    }
}

public struct VideoPacketizer: Sendable {
    public let channel: ChannelId
    /// The per-shard plaintext ceiling geometry fills to: 1112 B, less
    /// whatever TLV headroom the carrier's envelopes reserve.
    public let shardBudgetByteCount: Int
    /// The next seq this packetizer will allocate — exposed so a caller
    /// resuming a channel (or a test crossing the u16 wrap) can verify
    /// the serial counter's position.
    public private(set) var nextSeq: ChannelSeq

    public init(
        channel: ChannelId = .videoActive,
        firstSeq: ChannelSeq = ChannelSeq(rawValue: 0),
        shardBudgetByteCount: Int = WireBudget.maxPlaintextShardByteCount
    ) {
        self.channel = channel
        self.nextSeq = firstSeq
        self.shardBudgetByteCount = shardBudgetByteCount
    }

    /// The pure half of packetization, with no seq state: validates the
    /// Annex-B shape and the caller's IDR claim, picks the ladder's k/m
    /// at `shardBudgetByteCount`, and returns the k + m shards in
    /// shard-index order. Callers that allocate seqs elsewhere (under
    /// their own lock, with per-frame TLVs) use this directly.
    public static func shardPayloads(
        frame annexB: ArraySlice<UInt8>,
        isIDR: Bool,
        regime: FecRegime,
        shardBudgetByteCount: Int = WireBudget.maxPlaintextShardByteCount
    ) throws -> [VideoShardPayload] {
        let classification = classify(annexB)
        guard classification.isFrameShaped else {
            throw VideoError.frameNotFrameShaped
        }
        let derivedIdr = classification.containsIrap
        guard isIDR == derivedIdr else {
            throw VideoError.idrFlagMismatch(claimed: isIDR, derived: derivedIdr)
        }
        let geometry = try FecGeometryTable.geometry(
            forGroupByteCount: annexB.count, regime: regime,
            shardBudgetByteCount: shardBudgetByteCount
        )
        let payloads = try FecEncoder.encode(group: annexB, geometry: geometry)
        return try payloads.enumerated().map { index, payload in
            VideoShardPayload(
                fec: try FecField.reedSolomonShard(index, of: geometry).encoded,
                payload: payload
            )
        }
    }

    public static func shardPayloads(
        frame annexB: [UInt8],
        isIDR: Bool,
        regime: FecRegime,
        shardBudgetByteCount: Int = WireBudget.maxPlaintextShardByteCount
    ) throws -> [VideoShardPayload] {
        try shardPayloads(
            frame: annexB[...], isIDR: isIDR, regime: regime,
            shardBudgetByteCount: shardBudgetByteCount
        )
    }

    /// `AnnexBCheck.classifyFrame` through LyteCore's concrete
    /// ArraySlice entry point: its generic form runs unspecialized from
    /// another module, ~28× slower per byte on the frame hot path.
    private static func classify(
        _ annexB: ArraySlice<UInt8>
    ) -> AnnexBFrameClassification {
        let units = AnnexBCheck.nalUnits(in: annexB)
        return AnnexBFrameClassification(
            isFrameShaped: AnnexBCheck.leadingStartCodeLength(annexB) != nil
                && units.contains { HevcNalType.isVcl($0.type) },
            containsIrap: units.contains { HevcNalType.isIrap($0.type) }
        )
    }

    /// Packetizes one encoded frame into its k + m wire shards. Throws
    /// when the bytes are not frame-shaped Annex-B, when the caller's
    /// isIDR claim disagrees with the bitstream, or when the geometry
    /// table cannot protect a frame this large (`frameByteCeiling` is the
    /// sender's upstream guard). On success the serial counter has
    /// advanced by exactly `shards.count`.
    public mutating func packetize(
        frame annexB: ArraySlice<UInt8>,
        frameNumber: FrameNumber,
        captureTimestamp: HostTimestamp,
        isIDR: Bool,
        regime: FecRegime
    ) throws -> [VideoShard] {
        let payloads = try Self.shardPayloads(
            frame: annexB, isIDR: isIDR, regime: regime,
            shardBudgetByteCount: shardBudgetByteCount
        )
        return payloads.map { shard in
            defer { nextSeq = nextSeq.next }
            return VideoShard(
                envelope: Envelope(
                    channel: channel,
                    seq: nextSeq,
                    frame: frameNumber,
                    timestamp: captureTimestamp.microseconds,
                    fec: shard.fec
                ),
                payload: shard.payload
            )
        }
    }

    /// Packetizes a frame borrowed for this call's dynamic extent. The
    /// returned shards own all payload bytes and retain no view of `annexB`.
    public mutating func packetize(
        frame annexB: UnsafeBufferPointer<UInt8>,
        frameNumber: FrameNumber,
        captureTimestamp: HostTimestamp,
        isIDR: Bool,
        regime: FecRegime
    ) throws -> [VideoShard] {
        try packetize(
            frame: Array(annexB)[...],
            frameNumber: frameNumber,
            captureTimestamp: captureTimestamp,
            isIDR: isIDR,
            regime: regime
        )
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
