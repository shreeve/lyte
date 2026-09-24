// VideoChannel: the session's one paced sender. One encoded Annex-B frame
// in, Lyte-UDP datagrams out in pacer order, each tagged with its
// PacerClass so the send loop can map classes to per-packet TOS. Sans-IO:
// `now` is injected monotonic nanoseconds; the caller owns scheduling and
// syscalls.
//
// Chan-2 seqs are assigned, and chan-2 datagrams sealed, when the pacer
// RELEASES them, never when they are queued. Release order is therefore
// chan-2 seq order: no repair is overtaken by fresher seqs (the client's
// 64-deep replay window would refuse it as stale), and a datagram dropped
// before release (a fall purge, an expired repair) consumes no seq, so it
// never reads as a gap in the client's seq ledger. A fresh frame's k+m
// shards still take contiguous seqs in shard-index order (wire contract:
// the assembler infers a frame's seq range from any one shard) because a
// started frame is released whole: strict priority holds repairs behind
// it, and an urgent keyframe jumps only frames that have not started.
// Committing a frame is FEC plus enqueue; its seal work is paid one pacer
// quantum at a time as it leaves.
//
// `seal` turns each plaintext shard into the wire payload with the exact
// header bytes (fixed envelope + TLV block) as AAD. Nil (test-only) keeps
// bare-plaintext framing.
//
// Shard budget: shard ≤ 1128 − AEAD tag − TLV block (1101 B with the
// conn-id TLV, 1112 B without), so every datagram fits 1152 B. The tag is
// reserved even for bare framing, so FEC geometry never depends on the
// crypto seam.
//
// Every shard of a fresh frame (data and parity) is `.freshVideo`;
// keyframe shards enqueue `urgent`, which jumps only their own class's
// FIFO. Control outranks video; repair retransmits ride `.videoTail`,
// below fresh video and audio, so a repair storm cannot bend the 5 ms
// audio cadence.
//
// Repair store: every shard (plaintext + fec field) is retained per frame
// for `repairRetentionNS`, byte-capped, oldest frames evicted first. A
// retransmit is a fresh datagram (its own seq, nonce and seal at release)
// carrying the original frame number, fec field, capture timestamp and
// TLV stamps.

import HostCore
import HostSession
import LyteCore
import LyteWire

/// One ready-to-send datagram plus the routing metadata the send loop
/// needs (the caller maps class → TOS).
public struct VideoChannelDatagram: Hashable, Sendable {
    /// The full wire image (24 B envelope [+ TLV block] + wire payload),
    /// ≤ 1152 B by construction — `Envelope.encode` enforced it.
    public let bytes: [UInt8]
    public let pacerClass: PacerClass
    public let frameNumber: FrameNumber
    public let seq: ChannelSeq
    /// True for shards of an IDR/parameter-set frame (enqueued urgent).
    public let isKeyframe: Bool
    /// Nil is the session's primary path; set only for path-validation
    /// challenges, which must travel on the exact unvalidated tuple.
    public let destination: FourTuple?
}

/// The crypto seam: exact header bytes as AAD, envelope for nonce
/// material, plaintext in, wire payload (ciphertext ‖ tag) out.
public typealias VideoChannelSealer = (
    _ plaintext: ArraySlice<UInt8>,
    _ aad: ArraySlice<UInt8>,
    _ envelope: Envelope
) throws -> [UInt8]

public struct VideoChannelConfig: Sendable {
    public var channel: ChannelId
    public var firstSeq: ChannelSeq
    /// The starting FEC regime; `setRegime` moves it per frame.
    public var regime: FecRegime
    public var rateBitsPerSecond: Int
    public var pacerQuantumNS: UInt64
    /// When set, EVERY datagram carries the connection-ID TLV (0x01) so
    /// the client can attribute it regardless of source 4-tuple —
    /// datagrams are independently lossy. Costs 11 B/datagram and shrinks
    /// the shard budget to 1101 B (24 + 11 + 1101 + 16 = 1152 B exactly).
    public var connectionId: ConnectionId?
    /// How long sent shards stay repairable.
    public var repairRetentionNS: UInt64
    /// The store's byte ceiling (plaintext shard bytes); oldest frames
    /// evict first.
    public var repairStoreByteCap: Int
    /// Repairs queued longer than this are no longer useful to the
    /// client's bounded assembler. They are dropped before transmit
    /// instead of consuming tail capacity after their recovery window.
    public var repairQueueUsefulnessNS: UInt64

    public init(
        channel: ChannelId = .videoActive,
        firstSeq: ChannelSeq = ChannelSeq(rawValue: 0),
        regime: FecRegime = .clean,
        rateBitsPerSecond: Int,
        pacerQuantumNS: UInt64 = 1_000_000,
        connectionId: ConnectionId? = nil,
        repairRetentionNS: UInt64 = 4_000_000_000,
        repairStoreByteCap: Int = 16 << 20,
        repairQueueUsefulnessNS: UInt64 = 100_000_000
    ) {
        self.channel = channel
        self.firstSeq = firstSeq
        self.regime = regime
        self.rateBitsPerSecond = rateBitsPerSecond
        self.pacerQuantumNS = pacerQuantumNS
        self.connectionId = connectionId
        self.repairRetentionNS = repairRetentionNS
        self.repairStoreByteCap = repairStoreByteCap
        self.repairQueueUsefulnessNS = repairQueueUsefulnessNS
    }

    /// The TLV block bytes every datagram of this config carries:
    /// count byte + type/length header + the 8-byte conn-id value.
    var tlvBlockByteCount: Int {
        tlvBlockByteCount(extraTlvByteCount: 0)
    }

    /// The TLV block plus `extraTlvByteCount` bytes of per-frame TLVs;
    /// the count byte is paid once.
    func tlvBlockByteCount(extraTlvByteCount: Int) -> Int {
        let connIdBytes =
            connectionId == nil ? 0 : 2 + ConnectionId.byteCount
        let bodyBytes = connIdBytes + extraTlvByteCount
        return bodyBytes == 0 ? 0 : 1 + bodyBytes
    }

    /// The plaintext shard budget under this config's real per-datagram
    /// overhead. The AEAD tag is reserved unconditionally so geometry is
    /// identical with and without crypto.
    public var shardBudgetByteCount: Int {
        shardBudgetByteCount(extraTlvByteCount: 0)
    }

    /// The budget with per-frame TLVs on top (geometry is per-frame
    /// anyway — the assembler reads it from the fec field, never assumes
    /// a shard size).
    public func shardBudgetByteCount(extraTlvByteCount: Int) -> Int {
        min(
            WireBudget.maxPlaintextShardByteCount,
            WireBudget.maxWirePayloadByteCount
                - WireBudget.aeadTagByteCount
                - tlvBlockByteCount(extraTlvByteCount: extraTlvByteCount)
        )
    }
}

/// Immutable inputs for the expensive, pure half of video packetization.
/// The executable snapshots this while it owns Session, then performs
/// Annex-B validation + RS-FEC after releasing the Session lock.
public struct VideoFramePreparationConfig: Sendable {
    fileprivate let regime: FecRegime
    fileprivate let shardBudgetByteCount: Int
}

/// RS-FEC output with no sequence numbers, Noise nonces, or pacer state.
/// Preparing it is safe off the Session lock; committing it remains ordered.
public struct PreparedVideoFrame: Sendable {
    fileprivate let shards: [VideoShardPayload]
    fileprivate let encodedByteCount: Int
    fileprivate let regime: FecRegime
    let isKeyframe: Bool

    public var shardCount: Int { shards.count }
}

/// Running totals for the wiring layer itself (the Pacer keeps its own
/// per-class telemetry; this counts what crossed the seam).
public struct VideoChannelCounters: Sendable {
    public var framesIngested = 0
    public var keyframesIngested = 0
    public var shardsEnqueued = 0
    public var datagramsSent = 0
    public var bytesSent = 0
    /// Repair requests refused because the shard already rode one.
    public var repairShardsAlreadySent = 0
    /// Repair datagrams dropped from videoTail after their usefulness
    /// deadline elapsed while fresher/higher-priority work was ahead.
    public var repairShardsExpiredQueued = 0
    /// Released chan-2 datagrams the seal refused (dropped unsent; no seq
    /// consumed). Unreachable while the transport is established.
    public var releaseSealFailures = 0
    /// Sealed datagrams assembled by growing the pre-sized AAD header
    /// buffer in place (one final wire buffer, rather than encoding a
    /// third header+payload array after sealing).
    public var sealedDatagramsAssembledInPlace = 0
    /// Frames admitted directly from a caller-owned synchronous buffer,
    /// without first materializing a full-frame Array.
    public var borrowedFramesIngested = 0
    public var borrowedFrameBytesIngested = 0

    public init() {}
}

/// One bounded, joinable frame-flight record. Capture and admission are
/// recorded once; first/last transmit are filled by the pacer release path.
/// The executable may join this with encoder QP/IDR-cause posture without
/// printing per frame.
public struct VideoFrameTransmitTelemetry: Equatable, Sendable {
    public var frameNumber: UInt32
    public var captureTimestampMicroseconds: UInt64
    public var admittedAtNS: UInt64
    public var firstTransmitAtNS: UInt64?
    public var lastTransmitAtNS: UInt64?
    public var encodedBytes: Int
    public var shardCount: Int
    public var isKeyframe: Bool
    public var averageQP: Int?
    public var idrCauses: [String]
    public var pacerRateBitsPerSecond: Int
    public var fecRegime: FecRegime
    public var queuedWireTimeBeforeAdmissionNS: UInt64
    public var purged: Bool
}

public final class VideoChannel {
    public let config: VideoChannelConfig
    public private(set) var counters = VideoChannelCounters()

    /// The session's one schedule: strict priority over every class the
    /// session emits.
    private let pacer: Pacer
    private let send: (VideoChannelDatagram) -> Void
    private let seal: VideoChannelSealer?
    /// Bytes the seal adds to a plaintext shard (the AEAD tag; 0 for bare
    /// framing), so a queued shard's pacer token prices its wire image.
    private let sealOverheadByteCount: Int

    /// The seq the next released chan-2 datagram takes. Fresh shards and
    /// repairs draw from it in release order (see the header).
    public private(set) var nextSeq: ChannelSeq

    /// The FEC regime in force; applies from the next `ingest`.
    public private(set) var regime: FecRegime

    /// The last keyframe packetized — the staleness gate's "newer than
    /// the last IDR" anchor.
    public private(set) var lastKeyframeNumber: FrameNumber?

    /// What one pacer tag stands for. Control, audio and bulk arrive
    /// sealed (their seq spaces are the session's); chan-2 video waits
    /// unsealed for its seq.
    private enum Pending {
        case sealed(VideoChannelDatagram)
        case video(PendingVideo)
    }

    /// Everything a chan-2 datagram needs at release except its seq.
    private struct PendingVideo {
        var pacerClass: PacerClass
        var frameNumber: FrameNumber
        var captureMicros: UInt64
        var fec: UInt64
        var payload: [UInt8]
        /// The frame's TLV block (conn-id, lastInputSeq), shared by every
        /// shard of the frame.
        var extensions: [WireExtension]
        var isKeyframe: Bool
    }

    /// Everything waiting in the pacer, keyed by its token tag.
    private var pending: [UInt64: Pending] = [:]
    private var nextTag: UInt64 = 0
    /// Video-class shards still queued, per frame number: NACKs against
    /// frames still draining measure our pacer, not the path.
    private var queuedShardsByFrame: [UInt32: Int] = [:]
    private var queuedFreshShardsByFrame: [UInt32: Int] = [:]
    private var activeFrameTelemetry: [UInt32: VideoFrameTransmitTelemetry] = [:]
    private var completedFrameTelemetry = Deque<VideoFrameTransmitTelemetry>()
    private static let frameTelemetryCapacity = 256

    // MARK: Repair store

    private struct StoredShard {
        /// The encoded fec field (shard index + geometry) — replayed
        /// verbatim on the repair envelope.
        var fec: UInt64
        var payload: [UInt8]
        /// One attempt per shard: set when a repair rode.
        var repaired = false
    }

    private struct StoredFrame {
        /// When the frame was packetized (retention's clock).
        var ingestedAtNS: UInt64
        /// The frame's last shard release so far — the freeze-budget
        /// anchor: the client's freeze starts when the flight completes,
        /// so pacer queue time is not charged against the repair budget.
        var lastSentAtNS: UInt64
        var captureMicros: UInt64
        var extensions: [WireExtension]
        var isKeyframe: Bool
        var shards: [StoredShard]
        var payloadBytes: Int
    }

    private var store: [UInt32: StoredFrame] = [:]
    /// Insertion order = frame order (the session numbers frames
    /// serially ascending), so evictions pop from the front.
    private var storeOrder = Deque<UInt32>()
    private var storeBytes = 0
    private var purgedFrames: Set<UInt32> = []
    private var purgedFrameOrder = BoundedRing<UInt32>(
        capacity: VideoChannel.purgedFrameCapacity
    )
    private static let purgedFrameCapacity = 1_024

    /// `sealTagByteCount` is what `seal` appends to a plaintext shard; the
    /// default is the AEAD tag. It is ignored for bare framing.
    public init(
        config: VideoChannelConfig,
        now: UInt64,
        seal: VideoChannelSealer? = nil,
        sealTagByteCount: Int = WireBudget.aeadTagByteCount,
        send: @escaping (VideoChannelDatagram) -> Void
    ) {
        self.config = config
        self.pacer = Pacer(
            rateBitsPerSecond: config.rateBitsPerSecond,
            quantumNS: config.pacerQuantumNS,
            now: now
        )
        self.nextSeq = config.firstSeq
        self.regime = config.regime
        self.seal = seal
        self.sealOverheadByteCount = seal == nil ? 0 : sealTagByteCount
        self.send = send
    }

    /// Sets the regime the NEXT frame's geometry draws from; frames
    /// already packetized keep theirs (each shard's fec field says).
    public func setRegime(_ regime: FecRegime) {
        self.regime = regime
    }

    // MARK: Protectable-frame ceiling

    /// The largest encoded frame the current regime and TLV posture can
    /// ship as ONE FEC group: at most `maxDataShards(regime)` data shards
    /// (GF(2⁸) caps a block at 255 shards), each at the real shard budget.
    /// The fec field carries no group index, so a larger frame is
    /// unshippable, not merely unprotected.
    public func maxProtectableFrameByteCount(hasLastInputSeq: Bool) -> Int {
        FecGeometryTable.maxDataShards(regime)
            * config.shardBudgetByteCount(
                extraTlvByteCount: hasLastInputSeq
                    ? LastInputSeqTlv.encodedByteCount : 0
            )
    }

    /// Snapshot the geometry inputs for one frame. No sequence or crypto
    /// state is reserved here; those advance only when the prepared frame
    /// is committed under the Session owner's lock.
    public func preparationConfig(
        hasLastInputSeq: Bool
    ) -> VideoFramePreparationConfig {
        VideoFramePreparationConfig(
            regime: regime,
            shardBudgetByteCount: config.shardBudgetByteCount(
                extraTlvByteCount: hasLastInputSeq
                    ? LastInputSeqTlv.encodedByteCount : 0
            )
        )
    }

    /// Expensive pure half: validate Annex-B shape and build all RS shards
    /// through Wire's packetizer at this channel's shard budget. This
    /// method neither reads nor mutates channel state. A borrowed buffer
    /// is copied once into an array; arrays and slices are not.
    public static func prepareFrame<C>(
        _ annexB: C,
        isKeyframe: Bool,
        config: VideoFramePreparationConfig
    ) throws -> PreparedVideoFrame
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        let frame: ArraySlice<UInt8> =
            (annexB as? ArraySlice<UInt8>)
            ?? (annexB as? [UInt8])?[...]
            ?? Array(annexB)[...]
        return PreparedVideoFrame(
            shards: try VideoPacketizer.shardPayloads(
                frame: frame,
                isIDR: isKeyframe,
                regime: config.regime,
                shardBudgetByteCount: config.shardBudgetByteCount
            ),
            encodedByteCount: frame.count,
            regime: config.regime,
            isKeyframe: isKeyframe
        )
    }

    /// The ceiling's session-static worst case (lossy regime with the
    /// lastInputSeq stamp), for postures that must hold whatever the
    /// regime or input stream does mid-session.
    public var worstCaseProtectableFrameByteCount: Int {
        FecGeometryTable.maxDataShards(.lossy)
            * config.shardBudgetByteCount(
                extraTlvByteCount: LastInputSeqTlv.encodedByteCount
            )
    }

    /// Packetizes one encoded frame and enqueues every shard; returns the
    /// shard count. Throws on non-frame-shaped bytes, a lying keyframe
    /// flag or an unprotectable size.
    /// `captureTimestampMicroseconds` rides the envelope timestamp
    /// verbatim. `lastInputSeq`, when set, rides every shard of this frame
    /// as TLV 0x03 and shrinks the frame's shard budget accordingly.
    @discardableResult
    public func ingest(
        frame annexB: [UInt8],
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32? = nil,
        now: UInt64
    ) throws -> Int {
        try ingestBytes(
            frame: annexB, frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, lastInputSeq: lastInputSeq,
            now: now, isBorrowed: false
        )
    }

    /// Synchronous borrowed ingress. Packetization, FEC, queueing and
    /// repair retention finish before return; no input view escapes.
    @discardableResult
    public func ingest(
        frame annexB: UnsafeBufferPointer<UInt8>,
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32? = nil,
        now: UInt64
    ) throws -> Int {
        try ingestBytes(
            frame: annexB, frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, lastInputSeq: lastInputSeq,
            now: now, isBorrowed: true
        )
    }

    func ingestBytes<C>(
        frame annexB: C,
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32?,
        now: UInt64,
        isBorrowed: Bool
    ) throws -> Int
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        let prepared = try Self.prepareFrame(
            annexB,
            isKeyframe: isKeyframe,
            config: preparationConfig(hasLastInputSeq: lastInputSeq != nil)
        )
        return ingestPrepared(
            prepared,
            frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            lastInputSeq: lastInputSeq,
            now: now,
            isBorrowed: isBorrowed
        )
    }

    /// Ordered half: enqueue every shard unsealed and retain the frame.
    /// Seqs and seals are assigned at release (see the header). Callers
    /// serialize this with every other Session mutation.
    @discardableResult
    public func ingestPrepared(
        _ prepared: PreparedVideoFrame,
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        lastInputSeq: UInt32?,
        now: UInt64,
        isBorrowed: Bool = false
    ) -> Int {
        let queuedBytesBeforeAdmission =
            pacer.queuedBytes(.freshVideo) + pacer.queuedBytes(.videoTail)
        let queuedWireTimeBeforeAdmissionNS = UInt64(
            Double(queuedBytesBeforeAdmission) * 8e9
                / Double(max(pacer.rateBitsPerSecond, 1))
        )
        // The row exists before any shard can release.
        activeFrameTelemetry[frameNumber.rawValue] = VideoFrameTransmitTelemetry(
            frameNumber: frameNumber.rawValue,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            admittedAtNS: now,
            firstTransmitAtNS: nil,
            lastTransmitAtNS: nil,
            encodedBytes: prepared.encodedByteCount,
            shardCount: prepared.shards.count,
            isKeyframe: prepared.isKeyframe,
            averageQP: nil,
            idrCauses: [],
            pacerRateBitsPerSecond: pacer.rateBitsPerSecond,
            fecRegime: prepared.regime,
            queuedWireTimeBeforeAdmissionNS: queuedWireTimeBeforeAdmissionNS,
            purged: false
        )
        var extensions: [WireExtension] = []
        if let connectionId = config.connectionId {
            extensions.append(connectionId.wireExtension)
        }
        if let lastInputSeq {
            extensions.append(LastInputSeqTlv.wireExtension(seq: lastInputSeq))
        }
        for shard in prepared.shards {
            enqueueVideo(
                PendingVideo(
                    pacerClass: .freshVideo,
                    frameNumber: frameNumber,
                    captureMicros: captureTimestampMicroseconds,
                    fec: shard.fec,
                    payload: shard.payload,
                    extensions: extensions,
                    isKeyframe: prepared.isKeyframe
                ),
                urgent: prepared.isKeyframe, now: now
            )
        }
        retain(
            prepared.shards, frameNumber: frameNumber,
            captureMicros: captureTimestampMicroseconds,
            isKeyframe: prepared.isKeyframe,
            extensions: extensions, now: now
        )
        if prepared.isKeyframe { lastKeyframeNumber = frameNumber }
        counters.framesIngested += 1
        if prepared.isKeyframe { counters.keyframesIngested += 1 }
        if isBorrowed {
            counters.borrowedFramesIngested += 1
            counters.borrowedFrameBytesIngested += prepared.encodedByteCount
        }
        counters.shardsEnqueued += prepared.shards.count
        return prepared.shards.count
    }

    // MARK: Repair

    /// The freeze-budget anchor for `frame` (its last shard release); nil
    /// once the store let it go.
    public func repairAnchor(for frame: FrameNumber) -> UInt64? {
        store[frame.rawValue]?.lastSentAtNS
    }

    /// The bytes a repair of `shardIndices` would occupy. Unknown or
    /// already-repaired shards contribute nothing.
    public func repairByteCount(
        frame: FrameNumber, shardIndices: [UInt8]
    ) -> Int {
        guard let stored = store[frame.rawValue] else { return 0 }
        var bytes = 0
        for index in shardIndices where Int(index) < stored.shards.count {
            let shard = stored.shards[Int(index)]
            if !shard.repaired { bytes += shard.payload.count }
        }
        return bytes
    }

    /// Retransmits the named shards of a stored frame as fresh datagrams
    /// at `.videoTail`. One attempt per shard, ever: a shard that already
    /// rode a repair is refused (counted). Returns the count enqueued.
    @discardableResult
    public func enqueueRepair(
        frame: FrameNumber, shardIndices: [UInt8], now: UInt64
    ) -> Int {
        // Moved out and back so marking shards repaired never copies the
        // frame's shard array.
        guard var stored = store.removeValue(forKey: frame.rawValue) else {
            return 0
        }
        defer { store[frame.rawValue] = stored }
        var enqueued = 0
        for index in shardIndices.map(Int.init) {
            guard index < stored.shards.count else { continue }
            guard !stored.shards[index].repaired else {
                counters.repairShardsAlreadySent += 1
                continue
            }
            stored.shards[index].repaired = true
            enqueueVideo(
                PendingVideo(
                    pacerClass: .videoTail,
                    frameNumber: frame,
                    captureMicros: stored.captureMicros,
                    fec: stored.shards[index].fec,
                    payload: stored.shards[index].payload,
                    extensions: stored.extensions,
                    isKeyframe: stored.isKeyframe
                ),
                urgent: false, now: now
            )
            enqueued += 1
        }
        return enqueued
    }

    /// Bytes currently retained for repair (tests and the stats line).
    public var repairStoreBytes: Int { storeBytes }

    /// Whether a queue purge deliberately invalidated this frame. Session
    /// recovery treats a later NACK as superseded, not as a new IDR demand.
    public func wasPurged(_ frame: FrameNumber) -> Bool {
        purgedFrames.contains(frame.rawValue)
    }

    /// Drains completed/purged frame-flight records in bounded batches.
    public func takeFrameTransmitTelemetry() -> [VideoFrameTransmitTelemetry] {
        defer { completedFrameTelemetry.removeAll(keepingCapacity: true) }
        return Array(completedFrameTelemetry)
    }

    /// Joins encoder-side fields onto the frame-flight record without a
    /// per-frame log. The first quantum may complete before the encoder
    /// callback returns, so both active and just-completed rings are
    /// searched.
    public func annotateFrameTelemetry(
        frame: FrameNumber, averageQP: Int?, idrCauses: [String]
    ) {
        if activeFrameTelemetry[frame.rawValue] != nil {
            activeFrameTelemetry[frame.rawValue]?.averageQP = averageQP
            activeFrameTelemetry[frame.rawValue]?.idrCauses = idrCauses
            return
        }
        guard let index = completedFrameTelemetry.lastIndex(where: {
            $0.frameNumber == frame.rawValue
        }) else { return }
        completedFrameTelemetry[index].averageQP = averageQP
        completedFrameTelemetry[index].idrCauses = idrCauses
    }

    private func retain(
        _ shards: [VideoShardPayload],
        frameNumber: FrameNumber,
        captureMicros: UInt64,
        isKeyframe: Bool,
        extensions: [WireExtension],
        now: UInt64
    ) {
        guard config.repairStoreByteCap > 0 else { return }
        let payloadBytes = shards.reduce(0) { $0 + $1.payload.count }
        store[frameNumber.rawValue] = StoredFrame(
            ingestedAtNS: now,
            lastSentAtNS: now,
            captureMicros: captureMicros,
            extensions: extensions,
            isKeyframe: isKeyframe,
            shards: shards.map {
                StoredShard(fec: $0.fec, payload: $0.payload)
            },
            payloadBytes: payloadBytes
        )
        storeOrder.append(frameNumber.rawValue)
        storeBytes += payloadBytes
        evictStore(now: now)
    }

    /// Oldest-first eviction: past the retention window, or over the
    /// byte cap. Insertion order is frame order, so the front is
    /// always the oldest.
    private func evictStore(now: UInt64) {
        var dropFromFront = 0
        for key in storeOrder {
            guard let frame = store[key] else { dropFromFront += 1; continue }
            let expired =
                now &- frame.ingestedAtNS > config.repairRetentionNS
            let overCap = storeBytes > config.repairStoreByteCap
            guard expired || overCap else { break }
            store.removeValue(forKey: key)
            storeBytes -= frame.payloadBytes
            dropFromFront += 1
        }
        if dropFromFront > 0 {
            storeOrder.removeFirst(dropFromFront)
        }
    }

    /// One already-encoded control datagram at class `.control`, ahead
    /// of every queued video shard. The bytes are the full wire image;
    /// the session sealed them (handshake messages travel bare) and owns
    /// the CTRL seq space.
    public func enqueueControl(
        _ bytes: [UInt8],
        seq: ChannelSeq,
        destination: FourTuple? = nil,
        now: UInt64
    ) {
        let datagram = VideoChannelDatagram(
            bytes: bytes,
            pacerClass: .control,
            frameNumber: FrameNumber(rawValue: 0),
            seq: seq,
            isKeyframe: false,
            destination: destination
        )
        enqueue(datagram, urgent: false, frameID: nil, now: now)
    }

    /// One already-sealed audio datagram at class `.audio`: above every
    /// video class and below control, so audio waits behind at most one
    /// ≤1 ms batch. The AudioFramer owns the audio seq space.
    public func enqueueAudio(
        _ bytes: [UInt8],
        seq: ChannelSeq,
        frame: FrameNumber,
        now: UInt64
    ) {
        let datagram = VideoChannelDatagram(
            bytes: bytes,
            pacerClass: .audio,
            frameNumber: frame,
            seq: seq,
            isKeyframe: false,
            destination: nil
        )
        enqueue(datagram, urgent: false, frameID: nil, now: now)
    }

    /// One already-sealed chan-8 bulk datagram at class `.bulk`, the
    /// ladder's tail, so a file transfer never delays a feedback report.
    /// The session owns the chan-8 seq space.
    public func enqueueBulk(
        _ bytes: [UInt8],
        seq: ChannelSeq,
        now: UInt64
    ) {
        let datagram = VideoChannelDatagram(
            bytes: bytes,
            pacerClass: .bulk,
            frameNumber: FrameNumber(rawValue: 0),
            seq: seq,
            isKeyframe: false,
            destination: nil
        )
        enqueue(datagram, urgent: false, frameID: nil, now: now)
    }

    /// Datagrams of `pacerClass` still waiting in the shared schedule.
    public func queuedCount(_ pacerClass: PacerClass) -> Int {
        pacer.queuedCount(pacerClass)
    }

    private func enqueue(
        _ datagram: VideoChannelDatagram,
        urgent: Bool,
        frameID: UInt32?,
        now: UInt64
    ) {
        let tag = nextTag
        nextTag &+= 1
        pending[tag] = .sealed(datagram)
        pacer.enqueue(
            datagram.pacerClass,
            bytes: datagram.bytes.count,
            frameID: frameID,
            urgent: urgent,
            tag: tag,
            now: now
        )
    }

    /// Queues one chan-2 shard unsealed. Its token prices the wire image
    /// the release will build: header, payload and seal overhead.
    private func enqueueVideo(
        _ video: PendingVideo, urgent: Bool, now: UInt64
    ) {
        let tag = nextTag
        nextTag &+= 1
        pending[tag] = .video(video)
        let frame = video.frameNumber.rawValue
        queuedShardsByFrame[frame, default: 0] += 1
        if video.pacerClass == .freshVideo {
            queuedFreshShardsByFrame[frame, default: 0] += 1
        }
        let headerBytes = Envelope(
            channel: config.channel, seq: nextSeq, frame: video.frameNumber,
            timestamp: 0, fec: 0, extensions: video.extensions
        ).headerByteCount
        pacer.enqueue(
            video.pacerClass,
            bytes: headerBytes + video.payload.count + sealOverheadByteCount,
            frameID: frame,
            urgent: urgent,
            tag: tag,
            now: now
        )
    }

    /// Drains every batch the pacer will emit at `now`, handing each
    /// datagram to the sink in pacer order. Returns the datagram count.
    @discardableResult
    public func pump(now: UInt64) -> Int {
        pump(now: now, upThrough: .bulk)
    }

    /// Drains only control/audio. The executable uses this while a prior
    /// video socket write is blocked: latency traffic may cross channels
    /// ahead of sealed video, while no additional video enters the outbox.
    @discardableResult
    public func pumpLatency(now: UInt64) -> Int {
        pump(now: now, upThrough: .audio)
    }

    private func pump(now: UInt64, upThrough highestClass: PacerClass) -> Int {
        expireQueuedRepairs(now: now)
        var sent = 0
        while let batch = pacer.nextBatch(
            now: now, upThrough: highestClass
        ) {
            for token in batch.tokens {
                guard let entry = pending.removeValue(forKey: token.tag)
                else { continue } // unreachable while the pacer is owned
                let datagram: VideoChannelDatagram
                switch entry {
                case .sealed(let sealed):
                    datagram = sealed
                case .video(let video):
                    guard let released = release(video) else {
                        let frame = video.frameNumber.rawValue
                        Self.countDown(&queuedShardsByFrame, frame)
                        if video.pacerClass == .freshVideo {
                            Self.countDown(&queuedFreshShardsByFrame, frame)
                        }
                        continue
                    }
                    datagram = released
                }
                send(datagram)
                if datagram.pacerClass == .freshVideo {
                    store[datagram.frameNumber.rawValue]?.lastSentAtNS = now
                    let frame = datagram.frameNumber.rawValue
                    if activeFrameTelemetry[frame]?.firstTransmitAtNS == nil {
                        activeFrameTelemetry[frame]?.firstTransmitAtNS = now
                    }
                    if Self.countDown(&queuedFreshShardsByFrame, frame),
                       var telemetry =
                        activeFrameTelemetry.removeValue(forKey: frame) {
                        telemetry.lastTransmitAtNS = now
                        appendCompletedTelemetry(telemetry)
                    }
                }
                if datagram.pacerClass == .freshVideo
                    || datagram.pacerClass == .videoTail {
                    Self.countDown(
                        &queuedShardsByFrame, datagram.frameNumber.rawValue)
                }
                counters.datagramsSent += 1
                counters.bytesSent += datagram.bytes.count
                sent += 1
            }
        }
        return sent
    }

    /// The earliest instant `pump` (or, bounded to `.audio`,
    /// `pumpLatency`) can emit; nil when nothing it releases is queued.
    public func nextWake(
        now: UInt64, upThrough highestClass: PacerClass = .bulk
    ) -> UInt64? {
        pacer.nextWake(now: now, upThrough: highestClass)
    }

    public var isIdle: Bool {
        pacer.isEmpty
    }

    public func setRate(bitsPerSecond: Int, now: UInt64) {
        pacer.setRate(bitsPerSecond: bitsPerSecond, now: now)
    }

    public var rateBitsPerSecond: Int {
        pacer.rateBitsPerSecond
    }

    public var pacerTelemetry: PacerTelemetry {
        pacer.telemetry
    }

    /// Live queued bytes for one pacer class. Trains measured while we
    /// hold standing video backlog measure our own pacing, not the path.
    public func queuedBytes(_ priorityClass: PacerClass) -> Int {
        pacer.queuedBytes(priorityClass)
    }

    /// Frame numbers with video-class shards still in the pacer; a NACK
    /// against one is not path evidence.
    public func framesWithQueuedShards() -> Set<UInt32> {
        Set(queuedShardsByFrame.keys)
    }

    /// The fall-repricing purge: bytes admitted at the pre-fall rate
    /// would serialize at the crashed rate as stale glass. Drops every
    /// queued freshVideo/videoTail datagram; control, audio and bulk keep
    /// their place. The caller owes the client a fresh IDR.
    public func purgeQueuedVideo() -> (datagrams: Int, bytes: Int) {
        var datagrams = 0
        var bytes = 0
        var frames: Set<UInt32> = []
        for pacerClass in [PacerClass.freshVideo, .videoTail] {
            for token in pacer.dropClass(pacerClass) {
                guard case .video(let video) =
                    pending.removeValue(forKey: token.tag)
                else { continue }
                datagrams += 1
                bytes += token.bytes
                frames.insert(video.frameNumber.rawValue)
            }
        }
        queuedShardsByFrame.removeAll(keepingCapacity: true)
        queuedFreshShardsByFrame.removeAll(keepingCapacity: true)
        for frame in frames {
            invalidateStoredFrame(frame)
            rememberPurgedFrame(frame)
            if var telemetry = activeFrameTelemetry.removeValue(forKey: frame) {
                telemetry.purged = true
                appendCompletedTelemetry(telemetry)
            }
        }
        return (datagrams, bytes)
    }

    private func expireQueuedRepairs(now: UInt64) {
        let usefulness = config.repairQueueUsefulnessNS
        guard usefulness > 0, now > usefulness else { return }
        let expired = pacer.dropExpired(
            .videoTail, olderThan: now - usefulness
        )
        guard !expired.isEmpty else { return }
        var frames: Set<UInt32> = []
        for token in expired {
            guard case .video(let video) =
                pending.removeValue(forKey: token.tag)
            else { continue }
            frames.insert(video.frameNumber.rawValue)
            Self.countDown(&queuedShardsByFrame, video.frameNumber.rawValue)
            counters.repairShardsExpiredQueued += 1
        }
        for frame in frames { invalidateStoredFrame(frame) }
    }

    /// Counts one queued shard of `frame` down; true when it was the last.
    @discardableResult
    private static func countDown(
        _ counts: inout [UInt32: Int], _ frame: UInt32
    ) -> Bool {
        guard let left = counts[frame] else { return false }
        if left > 1 {
            counts[frame] = left - 1
            return false
        }
        counts.removeValue(forKey: frame)
        return true
    }

    private func invalidateStoredFrame(_ frame: UInt32) {
        guard let stored = store.removeValue(forKey: frame) else { return }
        storeBytes -= stored.payloadBytes
    }

    private func rememberPurgedFrame(_ frame: UInt32) {
        guard purgedFrames.insert(frame).inserted else { return }
        if let forgotten = purgedFrameOrder.append(frame) {
            purgedFrames.remove(forgotten)
        }
    }

    private func appendCompletedTelemetry(
        _ telemetry: VideoFrameTransmitTelemetry
    ) {
        if completedFrameTelemetry.count == Self.frameTelemetryCapacity {
            completedFrameTelemetry.removeFirst()
        }
        completedFrameTelemetry.append(telemetry)
    }

    /// Assigns the next chan-2 seq and seals. A refused seal consumes no
    /// seq, so the seqs that do reach the wire stay gap-free.
    private func release(_ video: PendingVideo) -> VideoChannelDatagram? {
        let envelope = Envelope(
            channel: config.channel,
            seq: nextSeq,
            frame: video.frameNumber,
            timestamp: video.captureMicros,
            fec: video.fec,
            extensions: video.extensions
        )
        guard let bytes = try? encodeSealed(
            envelope: envelope, plaintext: video.payload
        ) else {
            counters.releaseSealFailures += 1
            return nil
        }
        nextSeq = nextSeq.next
        return VideoChannelDatagram(
            bytes: bytes,
            pacerClass: video.pacerClass,
            frameNumber: video.frameNumber,
            seq: envelope.seq,
            isKeyframe: video.isKeyframe,
            destination: nil
        )
    }

    /// Header bytes double as AAD — exactly what the receiver slices off
    /// ahead of the payload.
    private func encodeSealed(
        envelope: Envelope, plaintext: [UInt8]
    ) throws -> [UInt8] {
        guard let seal else {
            return try envelope.encode(plaintextShard: plaintext)
        }
        let datagram = try envelope.sealedDatagram(plaintext[...]) {
            plaintext, aad in try seal(plaintext, aad, envelope)
        }
        counters.sealedDatagramsAssembledInPlace += 1
        return datagram
    }
}
