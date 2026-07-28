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

    public init(
        channel: ChannelId = .videoActive,
        firstSeq: ChannelSeq = ChannelSeq(rawValue: 0),
        regime: FecRegime = .clean,
        rateBitsPerSecond: Int,
        pacerQuantumNS: UInt64 = 1_000_000,
        connectionId: ConnectionId? = nil,
        repairRetentionNS: UInt64 = 4_000_000_000,
        repairStoreByteCap: Int = 16 << 20
    ) {
        self.channel = channel
        self.firstSeq = firstSeq
        self.regime = regime
        self.rateBitsPerSecond = rateBitsPerSecond
        self.pacerQuantumNS = pacerQuantumNS
        self.connectionId = connectionId
        self.repairRetentionNS = repairRetentionNS
        self.repairStoreByteCap = repairStoreByteCap
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

    public init() {}
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
        now: UInt64
    ) throws -> Int {
        let shards = try packetize(
            frame: annexB,
            frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe,
            lastInputSeq: lastInputSeq
        )
        for (envelope, payload) in shards {
            let datagram = VideoChannelDatagram(
                bytes: try encodeSealed(envelope: envelope, plaintext: payload),
                pacerClass: .freshVideo,
                frameNumber: frameNumber,
                seq: envelope.seq,
                isKeyframe: isKeyframe,
                destination: nil
            )
            enqueue(datagram, urgent: isKeyframe,
                    frameID: frameNumber.rawValue, now: now)
        }
        retain(
            shards, frameNumber: frameNumber,
            captureMicros: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, lastInputSeq: lastInputSeq, now: now
        )
        if isKeyframe { lastKeyframeNumber = frameNumber }
        counters.framesIngested += 1
        if isKeyframe { counters.keyframesIngested += 1 }
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
        var sent = 0
        while let batch = pacer.nextBatch(now: now) {
            for token in batch.tokens {
                guard let datagram = pending.removeValue(forKey: token.tag)
                else { continue } // unreachable while the pacer is owned
                send(datagram)
                if datagram.pacerClass == .freshVideo {
                    store[datagram.frameNumber.rawValue]?.lastSentAtNS = now
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

    // MARK: Packetization (W2 semantics, HS-7 headroom)

    /// The W2 packetizer's exact behavior — frame-shape and IDR-claim
    /// cross-checks, the parity ladder, balanced split, FecField
    /// interior, contiguous seq allocation — over the config's real
    /// shard budget (header comment). With a bare envelope the geometry
    /// is bit-identical to `FecGeometryTable.geometry`, which the HS-5
    /// gate test still asserts against the frozen corpus.
    private func packetize(
        frame annexB: [UInt8],
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32?
    ) throws -> [(envelope: Envelope, payload: [UInt8])] {
        guard AnnexBCheck.isFrameShaped(annexB) else {
            throw VideoError.frameNotFrameShaped
        }
        let derivedIdr = AnnexBCheck.containsIrap(annexB)
        guard isKeyframe == derivedIdr else {
            throw VideoError.idrFlagMismatch(
                claimed: isKeyframe, derived: derivedIdr
            )
        }

        let budget = config.shardBudgetByteCount(
            extraTlvByteCount: lastInputSeq == nil
                ? 0 : LastInputSeqTlv.encodedByteCount
        )
        let k = (annexB.count + budget - 1) / budget
        let m = try FecGeometryTable.parityShards(
            forDataShards: k, regime: regime
        )
        let geometry = try FecGeometry(
            dataShards: k, parityShards: m, groupByteCount: annexB.count
        )
        let payloads = try FecEncoder.encode(group: annexB, geometry: geometry)

        var shards: [(envelope: Envelope, payload: [UInt8])] = []
        shards.reserveCapacity(payloads.count)
        for (index, payload) in payloads.enumerated() {
            let field = try FecField.reedSolomonShard(index, of: geometry)
            var envelope = Envelope(
                channel: config.channel,
                seq: nextSeq,
                frame: frameNumber,
                timestamp: captureTimestampMicroseconds,
                fec: field.encoded
            )
            if let connectionId = config.connectionId {
                envelope.extensions.append(connectionId.wireExtension)
            }
            if let lastInputSeq {
                envelope.extensions.append(
                    LastInputSeqTlv.wireExtension(seq: lastInputSeq)
                )
            }
            shards.append((envelope, payload))
            nextSeq = nextSeq.next
        }
        return shards
    }

    /// Header bytes double as AAD — exactly what the receiver slices off
    /// ahead of the payload (the TransportSender rule, mirrored).
    private func encodeSealed(
        envelope: Envelope, plaintext: [UInt8]
    ) throws -> [UInt8] {
        guard let seal else {
            return try envelope.encode(plaintextShard: plaintext)
        }
        let header = try envelope.encode(payload: [])
        let sealed = try seal(plaintext[...], header[...], envelope)
        return try envelope.encode(payload: sealed)
    }
}
