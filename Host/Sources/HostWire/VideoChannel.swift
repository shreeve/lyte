// VideoChannel: the host's video-channel wiring (HS-5), now the session's
// paced send channel (HS-7). One encoded Annex-B frame in — from the NVENC
// packet callback on Linux, from the corpus in the macOS gate test —
// Lyte-UDP datagram byte-blobs out, in pacer order, each tagged with its
// PacerClass so the send loop can map classes to per-packet TOS (video
// 0xA0 CS5, control 0xC0 CS6). Sans-IO in the HostCore style: no sockets,
// no threads, no clock — `now` is injected monotonic nanoseconds
// everywhere and the caller owns scheduling and syscalls.
//
// Crypto seam (§4.1), filled at HS-7: `seal` is injected — the Session's
// NoiseTransport (or the `--insecure` passthrough) turns each plaintext
// shard into the wire payload with the exact header bytes (fixed envelope
// + TLV block) as AAD, the same discipline the client's TransportSender
// pins. Nil (the pre-session HS-5 shape) keeps bare-plaintext framing.
//
// Shard budget, the HS-7 accounting fix: the frozen Wire geometry table
// fills shards to 1112 B, which is exact only for a bare envelope —
// 24 + 1112 + 16 (tag) = 1152. With the HS-12 conn-id TLV block (11 B)
// on every datagram, a full shard would burst the budget
// (24 + 11 + 1112 + 16 = 1163), so the geometry here derives from the
// same parity ladder but with the real headroom: shard ≤ 1128 − tag −
// TLV block (1101 B with the conn-id, 1112 B without). The tag is
// reserved in `--insecure` mode too, so FEC geometry never depends on
// the crypto mode (the §4.2 rule). This is why packetization moved
// in-house from LyteWire.VideoPacketizer: the table cannot be told about
// TLV headroom and Wire/ is not this slice's territory. Everything else
// (balanced split, FecField interior, contiguous ascending seq per
// frame) is byte-identical to the W2 packetizer — the HS-5 gate test
// still proves it against the frozen corpus.
//
// Pacer-class ruling: EVERY shard of every fresh frame — data and parity
// alike — is `.freshVideo`; shards of a keyframe (IDR/parameter sets)
// additionally enqueue `urgent`, which jumps only their own class's FIFO
// (the Pacer's IDR-on-demand semantics) and never starves audio or
// control. Control datagrams (beacons, path challenges, handshake) enter
// through `enqueueControl` and outrank video structurally — HS-6's strict
// priority, all traffic classes through one schedule. The NACK era
// arrived at HS-17: repair retransmits ride `.videoTail` (the overview's
// unified order, conflict 13 — "video tail + NACK retransmits"), below
// fresh video and structurally below audio, so a repair storm can never
// bend the 5 ms cadence.
//
// Repair store (HS-17): every packetized shard — plaintext + its fec
// field — is retained per frame so the session's NACK responder can
// retransmit exactly what the client names. Retention is the build
// plan's "≥4 s rings" (HS-17 row; the overview's send-timestamp ring
// ruling, applied to the bytes themselves), additionally byte-capped so
// a rate spike cannot balloon memory: oldest frames evict first either
// way. A retransmit is a FRESH datagram — fresh seq, fresh nonce, fresh
// seal (the W3/W9 rule: the replay window admits no stale-seq resend) —
// carrying the ORIGINAL frame number, fec field, capture timestamp, and
// per-frame TLV stamps, composed through the same frozen codecs as the
// first flight; zero new wire bytes.

import HostCore
import LyteWire

/// One ready-to-send datagram: encoded envelope + payload bytes plus the
/// routing metadata the send loop needs (class → TOS mapping lives in the
/// caller, matching lyte-pace-check's precedent).
public struct VideoChannelDatagram: Hashable, Sendable {
    /// The full wire image (24 B envelope [+ TLV block] + wire payload),
    /// ≤ 1152 B by construction — `Envelope.encode` enforced it.
    public let bytes: [UInt8]
    public let pacerClass: PacerClass
    public let frameNumber: FrameNumber
    public let seq: ChannelSeq
    /// True for shards of an IDR/parameter-set frame (enqueued urgent).
    public let isKeyframe: Bool
    /// Where this datagram must go: nil is the session's primary path
    /// (the connected peer); set only for path-validation challenges,
    /// which must travel on the exact unvalidated tuple (HS-12).
    public let destination: FourTuple?
}

/// The HS-7 crypto seam: exact header bytes as AAD, envelope for nonce
/// material, plaintext in, wire payload (ciphertext ‖ tag, or the shard
/// unchanged in `--insecure`) out. Mirrors the client seam's shape.
public typealias VideoChannelSealer = (
    _ plaintext: ArraySlice<UInt8>,
    _ aad: ArraySlice<UInt8>,
    _ envelope: Envelope
) throws -> [UInt8]

public struct VideoChannelConfig: Sendable {
    public var channel: ChannelId
    public var firstSeq: ChannelSeq
    /// The STARTING FEC regime column. Live regime policy arrived at
    /// HS-17: the estimator's rung-3 step verdicts move the channel's
    /// regime via `setRegime`, per-frame, from the next ingest.
    public var regime: FecRegime
    /// Pacer rate. Until HS-16 negotiates, the caller's configured
    /// session ceiling is the honest default (Pacer's own rule).
    public var rateBitsPerSecond: Int
    public var pacerQuantumNS: UInt64
    /// HS-12: when set, EVERY outgoing datagram carries the connection-ID
    /// TLV (type 0x01) so the client can attribute datagrams to the
    /// session regardless of source 4-tuple — QUIC's every-packet rule,
    /// chosen over first-packet-only because datagrams are independently
    /// lossy. Cost: 11 B/datagram (count + TLV header + 8 B value) plus
    /// a shard budget of 1101 B instead of 1112 B (see the header
    /// comment); the worst case 24 + 11 + 1101 + 16 = 1152 B lands
    /// exactly on the budget, and `Envelope.encode` keeps enforcing it.
    /// Nil (default) sends the bare envelope with full-size shards.
    public var connectionId: ConnectionId?
    /// HS-17: how long sent shards stay repairable. The build plan's
    /// "≥4 s rings"; frames older than this evict from the store.
    public var repairRetentionNS: UInt64
    /// HS-17: the store's byte ceiling (plaintext shard bytes). At the
    /// 20 Mbps reference rate 4 s is ~10 MB; the cap holds a rate
    /// spike honest. Oldest frames evict first.
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

    /// The TLV block under this config plus `extraTlvByteCount` bytes of
    /// per-frame TLVs (HS-13's lastInputSeq stamp): the count byte is
    /// paid once, by whichever TLV arrives first.
    func tlvBlockByteCount(extraTlvByteCount: Int) -> Int {
        let connIdBytes =
            connectionId == nil ? 0 : 2 + ConnectionId.byteCount
        let bodyBytes = connIdBytes + extraTlvByteCount
        return bodyBytes == 0 ? 0 : 1 + bodyBytes
    }

    /// The plaintext shard budget under this config's real per-datagram
    /// overhead. The AEAD tag is reserved unconditionally so geometry is
    /// identical with and without crypto (§4.2).
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
    fileprivate struct Shard: Sendable {
        let fec: UInt64
        let payload: [UInt8]
    }

    fileprivate let shards: [Shard]
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
    /// HS-17: repair retransmits enqueued (fresh datagrams, videoTail).
    public var repairShardsEnqueued = 0
    /// HS-17: requested shards the store no longer held (evicted, or a
    /// shard index the frame never had).
    public var repairShardsUnavailable = 0
    /// HS-17: repair requests refused because the shard already rode a
    /// retransmit (one attempt — no retransmission of retransmissions).
    public var repairShardsAlreadySent = 0
    /// Repair datagrams dropped from videoTail after their usefulness
    /// deadline elapsed while fresher/higher-priority work was ahead.
    public var repairShardsExpiredQueued = 0
    /// Repair-store frames invalidated with a queue purge. They can no
    /// longer be resurrected by a later NACK.
    public var repairFramesPurged = 0
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

    /// The pacer is owned here: this channel is the session's ONE paced
    /// sender — one schedule, strict priority, every class the session
    /// emits. Control rides it via `enqueueControl` (HS-7) and audio
    /// joined via `enqueueAudio` (HS-15) — the "until audio joins the
    /// send loop" moment arrived, and the unification is one shared
    /// schedule rather than an extracted Pacer object, so the HS-5/HS-7
    /// gate behavior is untouched by construction.
    private let pacer: Pacer
    private let send: (VideoChannelDatagram) -> Void
    private let seal: VideoChannelSealer?

    /// The next seq the packetization below will allocate — contiguous
    /// ascending in shard-index order across each frame's k+m shards
    /// (wire contract: the assembler infers a frame's seq range from any
    /// one shard). Repair retransmits draw from the same counter: a
    /// retransmitted shard is a fresh datagram in every seq-visible way.
    public private(set) var nextSeq: ChannelSeq

    /// The §5.2 ladder column in force — HS-16's deferred "per-frame
    /// regime switch", moved by `setRegime` (the estimator's step
    /// verdicts via the session). Applies from the next `ingest`.
    public private(set) var regime: FecRegime

    /// The frame number of the last keyframe packetized — the
    /// staleness gate's "newer than the last IDR" anchor (§1.1 rule 3).
    public private(set) var lastKeyframeNumber: FrameNumber?

    /// Datagrams waiting in the pacer, keyed by their token tag.
    private var pending: [UInt64: VideoChannelDatagram] = [:]
    private var nextTag: UInt64 = 0
    /// Video-class shards still queued, per frame number (HS-28): the
    /// estimator recuses NACKs against frames we have not finished
    /// sending — the client's completion presumption expired mid-drain,
    /// which measures our pacer, not the path.
    private var queuedShardsByFrame: [UInt32: Int] = [:]
    private var queuedFreshShardsByFrame: [UInt32: Int] = [:]
    private var activeFrameTelemetry: [UInt32: VideoFrameTransmitTelemetry] = [:]
    private var completedFrameTelemetry: [VideoFrameTransmitTelemetry] = []
    private static let frameTelemetryCapacity = 256

    // MARK: Repair store (HS-17)

    private struct StoredShard {
        /// The encoded fec field (shard index + geometry) — replayed
        /// verbatim on the repair envelope.
        var fec: UInt64
        var payload: [UInt8]
        /// One attempt per shard (§1.1 rule 3): set when a repair rode.
        var repaired = false
    }

    private struct StoredFrame {
        /// Pacer-domain instant the frame was packetized (retention's
        /// clock).
        var ingestedAtNS: UInt64
        /// The frame's LAST shard release instant so far — the
        /// staleness gate's freeze-budget anchor: the client's freeze
        /// starts when the flight completes (it cannot judge the frame
        /// FEC-impossible before the wire has spoken), so pacer queue
        /// time must not be charged against the repair budget. Updated
        /// at pump time as the frame drains.
        var lastSentAtNS: UInt64
        var captureMicros: UInt64
        var lastInputSeq: UInt32?
        var isKeyframe: Bool
        var shards: [StoredShard]
        var payloadBytes: Int
    }

    private var store: [UInt32: StoredFrame] = [:]
    /// Insertion order = frame order (the session numbers frames
    /// serially ascending), so evictions pop from the front.
    private var storeOrder: [UInt32] = []
    private var storeBytes = 0
    private var purgedFrames: Set<UInt32> = []
    private var purgedFrameOrder: [UInt32] = []
    private static let purgedFrameCapacity = 1_024

    public init(
        config: VideoChannelConfig,
        now: UInt64,
        seal: VideoChannelSealer? = nil,
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
        self.send = send
    }

    /// The HS-17 regime switch: the §5.2 column the NEXT frame's
    /// geometry draws from. Frames already packetized are untouched —
    /// the fec field each shard carries is the wire truth per frame.
    public func setRegime(_ regime: FecRegime) {
        self.regime = regime
    }

    // MARK: Protectable-frame ceiling (HS-25)

    /// The largest encoded frame the CURRENT regime and TLV posture can
    /// ship as ONE protected FEC group — the GF(2⁸) block holds at most
    /// 255 total shards, so the §5.2 ladder protects at most
    /// `maxDataShards(regime)` data shards (231 clean / 204 lossy), each
    /// filled to this config's real shard budget. The wire cannot say
    /// more: the fec field binds one group per frame number and carries
    /// no group index, so a frame above this ceiling is unshippable, not
    /// merely unprotected. The session's ingest guard reads this before
    /// every packetize (frameByteCeiling's resiliency-§2.4 promise,
    /// enforced at the seam that owns geometry).
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

    /// Expensive pure half: validate Annex-B shape and build all RS shards.
    /// This method neither reads nor mutates channel state.
    public static func prepareFrame<C>(
        _ annexB: C,
        isKeyframe: Bool,
        config: VideoFramePreparationConfig
    ) throws -> PreparedVideoFrame
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        let classification = AnnexBCheck.classifyFrame(annexB)
        guard classification.isFrameShaped else {
            throw VideoError.frameNotFrameShaped
        }
        let derivedIdr = classification.containsIrap
        guard isKeyframe == derivedIdr else {
            throw VideoError.idrFlagMismatch(
                claimed: isKeyframe, derived: derivedIdr
            )
        }

        let budget = config.shardBudgetByteCount
        let k = (annexB.count + budget - 1) / budget
        let m = try FecGeometryTable.parityShards(
            forDataShards: k, regime: config.regime
        )
        let geometry = try FecGeometry(
            dataShards: k, parityShards: m, groupByteCount: annexB.count
        )
        let payloads = try FecEncoder.encode(group: annexB, geometry: geometry)
        var shards: [PreparedVideoFrame.Shard] = []
        shards.reserveCapacity(payloads.count)
        for (index, payload) in payloads.enumerated() {
            let field = try FecField.reedSolomonShard(index, of: geometry)
            shards.append(.init(fec: field.encoded, payload: payload))
        }
        return PreparedVideoFrame(
            shards: shards,
            encodedByteCount: annexB.count,
            regime: config.regime,
            isKeyframe: isKeyframe
        )
    }

    /// The ceiling's session-static worst case — the lossy column with
    /// the lastInputSeq stamp riding — for postures that must hold no
    /// matter how the regime or the input stream moves mid-session (the
    /// shell's opening encoder VBV cap derives from this).
    public var worstCaseProtectableFrameByteCount: Int {
        FecGeometryTable.maxDataShards(.lossy)
            * config.shardBudgetByteCount(
                extraTlvByteCount: LastInputSeqTlv.encodedByteCount
            )
    }

    /// Packetizes one encoded frame and enqueues every shard. Throws what
    /// the packetization/envelope/seal steps throw (non-frame-shaped
    /// bytes, a lying keyframe flag, an unprotectable frame size, a
    /// budget breach, a seal refusal) — loud, per the W2 rule. Returns
    /// the number of shards enqueued. `captureTimestampMicroseconds` is
    /// the PipeWire graph-clock capture stamp; it rides the envelope
    /// timestamp field verbatim. `lastInputSeq` (HS-13), when set, rides
    /// every shard of THIS frame as the host-pinned TLV 0x03 — per-shard
    /// like the conn-id, because shards are independently lossy — and
    /// the frame's geometry derives from the correspondingly smaller
    /// shard budget.
    @discardableResult
    public func ingest(
        frame annexB: [UInt8],
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32? = nil,
        interleave: (() -> Void)? = nil,
        now: UInt64
    ) throws -> Int {
        try ingestBytes(
            frame: annexB, frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, lastInputSeq: lastInputSeq,
            interleave: interleave, now: now, isBorrowed: false
        )
    }

    /// Synchronous borrowed ingress. Packetization, FEC, sealing, queueing,
    /// and repair retention finish before return; no input view escapes.
    @discardableResult
    public func ingest(
        frame annexB: UnsafeBufferPointer<UInt8>,
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32? = nil,
        interleave: (() -> Void)? = nil,
        now: UInt64
    ) throws -> Int {
        try ingestBytes(
            frame: annexB, frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, lastInputSeq: lastInputSeq,
            interleave: interleave, now: now, isBorrowed: true
        )
    }

    func ingestBytes<C>(
        frame annexB: C,
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32?,
        interleave: (() -> Void)?,
        now: UInt64,
        isBorrowed: Bool
    ) throws -> Int
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        let queuedBytesBeforeAdmission =
            pacer.queuedBytes(.freshVideo) + pacer.queuedBytes(.videoTail)
        let queuedWireTimeBeforeAdmissionNS = UInt64(
            Double(queuedBytesBeforeAdmission) * 8e9
                / Double(max(pacer.rateBitsPerSecond, 1))
        )
        let prepared = try Self.prepareFrame(
            annexB,
            isKeyframe: isKeyframe,
            config: preparationConfig(hasLastInputSeq: lastInputSeq != nil)
        )
        return try ingestPrepared(
            prepared,
            frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            lastInputSeq: lastInputSeq,
            interleave: interleave,
            now: now,
            isBorrowed: isBorrowed,
            queuedWireTimeBeforeAdmissionNS: queuedWireTimeBeforeAdmissionNS
        )
    }

    /// Ordered half: allocate channel seqs, seal, enqueue, and retain.
    /// Callers serialize this with every other Session mutation.
    @discardableResult
    public func ingestPrepared(
        _ prepared: PreparedVideoFrame,
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        lastInputSeq: UInt32?,
        interleave: (() -> Void)? = nil,
        now: UInt64,
        isBorrowed: Bool = false
    ) throws -> Int {
        let queuedBytesBeforeAdmission =
            pacer.queuedBytes(.freshVideo) + pacer.queuedBytes(.videoTail)
        let queuedWireTimeBeforeAdmissionNS = UInt64(
            Double(queuedBytesBeforeAdmission) * 8e9
                / Double(max(pacer.rateBitsPerSecond, 1))
        )
        return try ingestPrepared(
            prepared,
            frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            lastInputSeq: lastInputSeq,
            interleave: interleave,
            now: now,
            isBorrowed: isBorrowed,
            queuedWireTimeBeforeAdmissionNS: queuedWireTimeBeforeAdmissionNS
        )
    }

    private func ingestPrepared(
        _ prepared: PreparedVideoFrame,
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        lastInputSeq: UInt32?,
        interleave: (() -> Void)?,
        now: UInt64,
        isBorrowed: Bool,
        queuedWireTimeBeforeAdmissionNS: UInt64
    ) throws -> Int {
        var shards: [(envelope: Envelope, payload: [UInt8])] = []
        shards.reserveCapacity(prepared.shards.count)
        for shard in prepared.shards {
            var envelope = Envelope(
                channel: config.channel,
                seq: nextSeq,
                frame: frameNumber,
                timestamp: captureTimestampMicroseconds,
                fec: shard.fec
            )
            if let connectionId = config.connectionId {
                envelope.extensions.append(connectionId.wireExtension)
            }
            if let lastInputSeq {
                envelope.extensions.append(
                    LastInputSeqTlv.wireExtension(seq: lastInputSeq)
                )
            }
            shards.append((envelope, shard.payload))
            nextSeq = nextSeq.next
        }
        interleave?()
        for (index, shard) in shards.enumerated() {
            // A large IDR can require hundreds of seals. Give the
            // executable's audio mailbox a deterministic service point
            // between small groups without weakening frame/seq ordering.
            if index > 0, index.isMultiple(of: 4) { interleave?() }
            let (envelope, payload) = shard
            let datagram = VideoChannelDatagram(
                bytes: try encodeSealed(envelope: envelope, plaintext: payload),
                pacerClass: .freshVideo,
                frameNumber: frameNumber,
                seq: envelope.seq,
                isKeyframe: prepared.isKeyframe,
                destination: nil
            )
            enqueue(datagram, urgent: prepared.isKeyframe,
                    frameID: frameNumber.rawValue, now: now)
        }
        retain(
            shards, frameNumber: frameNumber,
            captureMicros: captureTimestampMicroseconds,
            isKeyframe: prepared.isKeyframe,
            lastInputSeq: lastInputSeq, now: now
        )
        activeFrameTelemetry[frameNumber.rawValue] = VideoFrameTransmitTelemetry(
            frameNumber: frameNumber.rawValue,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            admittedAtNS: now,
            firstTransmitAtNS: nil,
            lastTransmitAtNS: nil,
            encodedBytes: prepared.encodedByteCount,
            shardCount: shards.count,
            isKeyframe: prepared.isKeyframe,
            averageQP: nil,
            idrCauses: [],
            pacerRateBitsPerSecond: pacer.rateBitsPerSecond,
            fecRegime: prepared.regime,
            queuedWireTimeBeforeAdmissionNS: queuedWireTimeBeforeAdmissionNS,
            purged: false
        )
        if prepared.isKeyframe { lastKeyframeNumber = frameNumber }
        counters.framesIngested += 1
        if prepared.isKeyframe { counters.keyframesIngested += 1 }
        if isBorrowed {
            counters.borrowedFramesIngested += 1
            counters.borrowedFrameBytesIngested += prepared.encodedByteCount
        }
        counters.shardsEnqueued += shards.count
        return shards.count
    }

    // MARK: Repair (HS-17)

    /// The freeze-budget anchor for `frame`: its last shard release
    /// instant (see StoredFrame.lastSentAtNS); nil once the store let
    /// it go.
    public func repairAnchor(for frame: FrameNumber) -> UInt64? {
        store[frame.rawValue]?.lastSentAtNS
    }

    /// The wire bytes a repair of `shardIndices` would occupy — the
    /// gate's retxSerialization numerator. Unknown/already-repaired
    /// shards contribute nothing.
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

    /// Retransmits the named shards of a stored frame: each one a FRESH
    /// datagram (fresh seq, fresh seal) carrying the original frame
    /// number, fec field, capture timestamp, and TLV stamps, enqueued
    /// at `.videoTail` — below fresh video, structurally below audio.
    /// One attempt per shard, ever: a shard that already rode a repair
    /// is refused (counted), per §1.1 rule 3. Returns the count
    /// actually enqueued (0 = nothing repairable; the caller judges
    /// what that means). Throws only what the seal path throws.
    @discardableResult
    public func enqueueRepair(
        frame: FrameNumber, shardIndices: [UInt8], now: UInt64
    ) throws -> Int {
        guard var stored = store[frame.rawValue] else {
            counters.repairShardsUnavailable += shardIndices.count
            return 0
        }
        var enqueued = 0
        for index in shardIndices {
            guard Int(index) < stored.shards.count else {
                counters.repairShardsUnavailable += 1
                continue
            }
            guard !stored.shards[Int(index)].repaired else {
                counters.repairShardsAlreadySent += 1
                continue
            }
            let shard = stored.shards[Int(index)]
            var envelope = Envelope(
                channel: config.channel,
                seq: nextSeq,
                frame: frame,
                timestamp: stored.captureMicros,
                fec: shard.fec
            )
            if let connectionId = config.connectionId {
                envelope.extensions.append(connectionId.wireExtension)
            }
            if let lastInputSeq = stored.lastInputSeq {
                envelope.extensions.append(
                    LastInputSeqTlv.wireExtension(seq: lastInputSeq)
                )
            }
            let datagram = VideoChannelDatagram(
                bytes: try encodeSealed(
                    envelope: envelope, plaintext: shard.payload
                ),
                pacerClass: .videoTail,
                frameNumber: frame,
                seq: envelope.seq,
                isKeyframe: stored.isKeyframe,
                destination: nil
            )
            nextSeq = nextSeq.next
            stored.shards[Int(index)].repaired = true
            enqueue(datagram, urgent: false,
                    frameID: frame.rawValue, now: now)
            enqueued += 1
        }
        store[frame.rawValue] = stored
        counters.repairShardsEnqueued += enqueued
        return enqueued
    }

    /// Bytes currently retained for repair (tests and the stats line).
    public var repairStoreBytes: Int { storeBytes }
    /// Frames currently retained for repair.
    public var repairStoreFrameCount: Int { store.count }

    /// Whether a queue purge deliberately invalidated this frame. Session
    /// recovery treats a later NACK as superseded, not as a new IDR demand.
    public func wasPurged(_ frame: FrameNumber) -> Bool {
        purgedFrames.contains(frame.rawValue)
    }

    /// Drains completed/purged frame-flight records in bounded batches.
    public func takeFrameTransmitTelemetry() -> [VideoFrameTransmitTelemetry] {
        defer { completedFrameTelemetry.removeAll(keepingCapacity: true) }
        return completedFrameTelemetry
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
        _ shards: [(envelope: Envelope, payload: [UInt8])],
        frameNumber: FrameNumber,
        captureMicros: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32?,
        now: UInt64
    ) {
        guard config.repairStoreByteCap > 0 else { return }
        let payloadBytes = shards.reduce(0) { $0 + $1.payload.count }
        store[frameNumber.rawValue] = StoredFrame(
            ingestedAtNS: now,
            lastSentAtNS: now,
            captureMicros: captureMicros,
            lastInputSeq: lastInputSeq,
            isKeyframe: isKeyframe,
            shards: shards.map {
                StoredShard(fec: $0.envelope.fec, payload: $0.payload)
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

    /// HS-7: one already-encoded control datagram (beacon, handshake
    /// message, path challenge) through the same pacer, class `.control`
    /// — strict priority puts it ahead of every queued video shard
    /// without starving in-flight batches. The bytes are the full wire
    /// image; sealing (or not — handshake messages travel bare) already
    /// happened at the session layer, which owns the CTRL seq space.
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

    /// HS-15: one already-sealed audio datagram (an Opus data shard or
    /// its group's parity) through the same pacer, class `.audio` —
    /// strictly above every video class and below control, which is
    /// what makes the 5 ms ± 2 ms inter-send bound structural (HS-6:
    /// audio waits behind at most one ≤1 ms batch). The bytes are the
    /// full wire image; the AudioFramer owns the audio seq space and
    /// the session sealed the payload, exactly the `enqueueControl`
    /// division of labor.
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

    /// F-3: one already-sealed chan-8 bulk datagram (the bulk channel's
    /// ARQ frames — accept/ack/complete/abort from the receiving host,
    /// plus the ACKs that pace the sender's chunks) through the same
    /// pacer, class `.bulk` — the ladder's tail, strictly below
    /// telemetry, so a file transfer can never delay a feedback report
    /// by even one batch (design record 20260728-053300 §1). Same
    /// division of labor as `enqueueControl`: the session owns the
    /// chan-8 seq space and sealed the payload.
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

    /// Datagrams of `pacerClass` still waiting in the shared schedule —
    /// the audio thread's "did my packet actually leave" check (HS-15).
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
        pending[tag] = datagram
        if datagram.pacerClass == .freshVideo
            || datagram.pacerClass == .videoTail {
            queuedShardsByFrame[datagram.frameNumber.rawValue, default: 0] += 1
        }
        if datagram.pacerClass == .freshVideo {
            queuedFreshShardsByFrame[
                datagram.frameNumber.rawValue, default: 0
            ] += 1
        }
        pacer.enqueue(
            datagram.pacerClass,
            bytes: datagram.bytes.count,
            frameID: frameID,
            urgent: urgent,
            tag: tag,
            now: now
        )
    }

    /// Drains every batch the pacer will emit at `now`, handing each
    /// datagram to the sink in pacer order. Returns the datagram count.
    @discardableResult
    public func pump(now: UInt64) -> Int {
        expireQueuedRepairs(now: now)
        var sent = 0
        while let batch = pacer.nextBatch(now: now) {
            for token in batch.tokens {
                guard let datagram = pending.removeValue(forKey: token.tag)
                else { continue } // unreachable while the pacer is owned
                send(datagram)
                if datagram.pacerClass == .freshVideo {
                    store[datagram.frameNumber.rawValue]?.lastSentAtNS = now
                    let frame = datagram.frameNumber.rawValue
                    if activeFrameTelemetry[frame]?.firstTransmitAtNS == nil {
                        activeFrameTelemetry[frame]?.firstTransmitAtNS = now
                    }
                    if let freshLeft = queuedFreshShardsByFrame[frame] {
                        if freshLeft <= 1 {
                            queuedFreshShardsByFrame.removeValue(forKey: frame)
                            if var telemetry =
                                activeFrameTelemetry.removeValue(forKey: frame) {
                                telemetry.lastTransmitAtNS = now
                                appendCompletedTelemetry(telemetry)
                            }
                        } else {
                            queuedFreshShardsByFrame[frame] = freshLeft - 1
                        }
                    }
                }
                if datagram.pacerClass == .freshVideo
                    || datagram.pacerClass == .videoTail {
                    let frame = datagram.frameNumber.rawValue
                    if let left = queuedShardsByFrame[frame] {
                        if left <= 1 {
                            queuedShardsByFrame.removeValue(forKey: frame)
                        } else {
                            queuedShardsByFrame[frame] = left - 1
                        }
                    }
                }
                counters.datagramsSent += 1
                counters.bytesSent += datagram.bytes.count
                sent += 1
            }
        }
        return sent
    }

    /// The earliest instant `pump` can emit; nil when nothing is queued.
    /// The caller's loop sleeps until this (Pacer semantics verbatim).
    public func nextWake(now: UInt64) -> UInt64? {
        pacer.nextWake(now: now)
    }

    public var isIdle: Bool {
        pacer.isEmpty
    }

    /// The HS-16 seam, passed through.
    public func setRate(bitsPerSecond: Int, now: UInt64) {
        pacer.setRate(bitsPerSecond: bitsPerSecond, now: now)
    }

    /// The rate the shared pacer is running at right now (HS-16's
    /// evidence surface for tests and logs).
    public var rateBitsPerSecond: Int {
        pacer.rateBitsPerSecond
    }

    public var pacerTelemetry: PacerTelemetry {
        pacer.telemetry
    }

    /// Live queued bytes for one pacer class — the estimator's
    /// self-reference gate reads the video backlog through this
    /// (HS-22c): trains measured while we hold standing backlog are
    /// measurements of our own pacing, not the path.
    public func queuedBytes(_ priorityClass: PacerClass) -> Int {
        pacer.queuedBytes(priorityClass)
    }

    /// Frame numbers with video-class shards still waiting in the
    /// pacer (HS-28): a NACK against one of these is the client
    /// presuming completion of a flight we have not finished — the
    /// estimator recuses it from the post-FEC path evidence.
    public func framesWithQueuedShards() -> Set<UInt32> {
        Set(queuedShardsByFrame.keys)
    }

    /// The fall-repricing purge: bytes admitted at the pre-fall rate
    /// would serialize at the crashed rate as stale glass (80–895 ms
    /// measured). Drops every queued video-class datagram (freshVideo
    /// + videoTail) from the shared schedule and settles the per-frame
    /// census; control, audio, and bulk keep their place. The caller
    /// owes the client a fresh IDR — frames dropped mid-flight can
    /// never complete, and whatever referenced them must re-anchor.
    public func purgeQueuedVideo() -> (datagrams: Int, bytes: Int) {
        var datagrams = 0
        var bytes = 0
        var frames: Set<UInt32> = []
        for pacerClass in [PacerClass.freshVideo, .videoTail] {
            for token in pacer.dropClass(pacerClass) {
                guard let datagram = pending.removeValue(forKey: token.tag)
                else { continue }
                datagrams += 1
                bytes += datagram.bytes.count
                frames.insert(datagram.frameNumber.rawValue)
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
        counters.repairFramesPurged += frames.count
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
            guard let datagram = pending.removeValue(forKey: token.tag) else {
                continue
            }
            frames.insert(datagram.frameNumber.rawValue)
            let frame = datagram.frameNumber.rawValue
            if let left = queuedShardsByFrame[frame] {
                if left <= 1 {
                    queuedShardsByFrame.removeValue(forKey: frame)
                } else {
                    queuedShardsByFrame[frame] = left - 1
                }
            }
            counters.repairShardsExpiredQueued += 1
        }
        for frame in frames { invalidateStoredFrame(frame) }
    }

    private func invalidateStoredFrame(_ frame: UInt32) {
        guard let stored = store.removeValue(forKey: frame) else { return }
        storeBytes -= stored.payloadBytes
    }

    private func rememberPurgedFrame(_ frame: UInt32) {
        guard purgedFrames.insert(frame).inserted else { return }
        purgedFrameOrder.append(frame)
        if purgedFrameOrder.count > Self.purgedFrameCapacity {
            purgedFrames.remove(purgedFrameOrder.removeFirst())
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

    /// Header bytes double as AAD — exactly what the receiver slices off
    /// ahead of the payload (the TransportSender rule, mirrored).
    private func encodeSealed(
        envelope: Envelope, plaintext: [UInt8]
    ) throws -> [UInt8] {
        guard let seal else {
            return try envelope.encode(plaintextShard: plaintext)
        }
        var header = try envelope.encode(payload: [])
        // The sealer API necessarily returns ciphertext‖tag as its own
        // array. Reuse the AAD header as the FINAL datagram buffer:
        // pre-size it before sealing, authenticate exactly these header
        // bytes, then append the returned payload in place. This removes
        // the former third per-shard allocation from
        // `envelope.encode(payload: sealed)` while preserving AEAD
        // sequencing and byte identity.
        header.reserveCapacity(
            header.count + plaintext.count + WireBudget.aeadTagByteCount
        )
        let sealed = try seal(plaintext[...], header[...], envelope)
        guard sealed.count <= WireBudget.maxWirePayloadByteCount else {
            throw WireError.payloadOverBudget(sealed.count)
        }
        let total = header.count + sealed.count
        guard total <= WireBudget.maxDatagramByteCount else {
            throw WireError.datagramOverBudget(total)
        }
        header.append(contentsOf: sealed)
        counters.sealedDatagramsAssembledInPlace += 1
        return header
    }
}
