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
// Pacer-class ruling for this slice, deliberately simple: EVERY shard of
// every frame — data and parity alike — is `.freshVideo`; shards of a
// keyframe (IDR/parameter sets) additionally enqueue `urgent`, which jumps
// only their own class's FIFO (the Pacer's IDR-on-demand semantics) and
// never starves audio or control. Control datagrams (beacons, path
// challenges, handshake) enter through `enqueueControl` and outrank video
// structurally — HS-6's strict priority, all traffic classes through one
// schedule. The fresh/tail split waits for the ratchet/NACK era, which is
// what would produce tail traffic.

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
    /// The FEC regime column (clean until host-side loss policy exists —
    /// rung 3 of the resiliency ladder is a later slice's call).
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

    public init(
        channel: ChannelId = .videoActive,
        firstSeq: ChannelSeq = ChannelSeq(rawValue: 0),
        regime: FecRegime = .clean,
        rateBitsPerSecond: Int,
        pacerQuantumNS: UInt64 = 1_000_000,
        connectionId: ConnectionId? = nil
    ) {
        self.channel = channel
        self.firstSeq = firstSeq
        self.regime = regime
        self.rateBitsPerSecond = rateBitsPerSecond
        self.pacerQuantumNS = pacerQuantumNS
        self.connectionId = connectionId
    }

    /// The TLV block bytes every datagram of this config carries:
    /// count byte + type/length header + the 8-byte conn-id value.
    var tlvBlockByteCount: Int {
        connectionId == nil ? 0 : 1 + 2 + ConnectionId.byteCount
    }

    /// The plaintext shard budget under this config's real per-datagram
    /// overhead. The AEAD tag is reserved unconditionally so geometry is
    /// identical with and without crypto (§4.2).
    public var shardBudgetByteCount: Int {
        min(
            WireBudget.maxPlaintextShardByteCount,
            WireBudget.maxWirePayloadByteCount
                - WireBudget.aeadTagByteCount
                - tlvBlockByteCount
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

    public init() {}
}

public final class VideoChannel {
    public let config: VideoChannelConfig
    public private(set) var counters = VideoChannelCounters()

    /// The pacer is owned here for now: this channel is the session's
    /// only paced sender until the audio channel (HS-15 era) joins the
    /// send loop, at which point the Pacer lifts out to a shared owner.
    /// Control traffic already rides it via `enqueueControl`, so the
    /// HS-6 strict-priority schedule covers every class the session
    /// emits today.
    private let pacer: Pacer
    private let send: (VideoChannelDatagram) -> Void
    private let seal: VideoChannelSealer?

    /// The next seq the packetization below will allocate — contiguous
    /// ascending in shard-index order across each frame's k+m shards
    /// (wire contract: the assembler infers a frame's seq range from any
    /// one shard).
    public private(set) var nextSeq: ChannelSeq

    /// Datagrams waiting in the pacer, keyed by their token tag.
    private var pending: [UInt64: VideoChannelDatagram] = [:]
    private var nextTag: UInt64 = 0

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
        self.seal = seal
        self.send = send
    }

    /// Packetizes one encoded frame and enqueues every shard. Throws what
    /// the packetization/envelope/seal steps throw (non-frame-shaped
    /// bytes, a lying keyframe flag, an unprotectable frame size, a
    /// budget breach, a seal refusal) — loud, per the W2 rule. Returns
    /// the number of shards enqueued. `captureTimestampMicroseconds` is
    /// the PipeWire graph-clock capture stamp; it rides the envelope
    /// timestamp field verbatim.
    @discardableResult
    public func ingest(
        frame annexB: [UInt8],
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        now: UInt64
    ) throws -> Int {
        let shards = try packetize(
            frame: annexB,
            frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe
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
        counters.framesIngested += 1
        if isKeyframe { counters.keyframesIngested += 1 }
        counters.shardsEnqueued += shards.count
        return shards.count
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
        isKeyframe: Bool
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

        let budget = config.shardBudgetByteCount
        let k = (annexB.count + budget - 1) / budget
        let m = try FecGeometryTable.parityShards(
            forDataShards: k, regime: config.regime
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
