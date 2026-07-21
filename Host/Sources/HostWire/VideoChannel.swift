// VideoChannel: the host's video-channel wiring (HS-5). One encoded
// Annex-B frame in — from the NVENC packet callback on Linux, from the
// corpus in the macOS gate test — Lyte-UDP datagram byte-blobs out, in
// pacer order, each tagged with its PacerClass so the send loop can map
// classes to per-packet TOS (video 0xA0 CS5). Sans-IO in the HostCore
// style: no sockets, no threads, no clock — `now` is injected monotonic
// nanoseconds everywhere and the caller owns scheduling and syscalls.
//
// Composition, nothing invented here: LyteWire's VideoPacketizer owns the
// per-channel seq and the FEC geometry (ladder per regime); Envelope
// encode enforces the §4.2 budgets (1112 B shard, 1152 B datagram);
// HostCore's Pacer owns batch timing and strict priority. This layer only
// marries them — packetize, encode, enqueue, and hand drained datagrams
// to the sink.
//
// Crypto seam (§4.1): datagrams leave as envelope + bare plaintext shard
// (`--insecure` framing). When Noise lands at HS-7, sealing happens where
// `encodeDatagram()` is called today — the FEC geometry, budgets, and
// pacer math are identical with and without crypto by design, so nothing
// upstream of that call site moves.
//
// Pacer-class ruling for this slice, deliberately simple: EVERY shard of
// every frame — data and parity alike — is `.freshVideo`; shards of a
// keyframe (IDR/parameter sets) additionally enqueue `urgent`, which jumps
// only their own class's FIFO (the Pacer's IDR-on-demand semantics) and
// never starves audio or control. The fresh/tail split (first-quantum
// heuristics, refinement demotion) only becomes meaningful when the
// ratchet and NACK-retransmit paths exist to *produce* tail traffic —
// that is the HS-17/ratchet era's call, and guessing it now would just be
// policy without a consumer. Documented simplification, not an oversight.

import HostCore
import LyteWire

/// One ready-to-send datagram: encoded envelope + payload bytes plus the
/// routing metadata the send loop needs (class → TOS mapping lives in the
/// caller, matching lyte-pace-check's precedent).
public struct VideoChannelDatagram: Hashable, Sendable {
    /// The full wire image (24 B envelope + shard), ≤ 1152 B by
    /// construction — `Envelope.encode` enforced it before this existed.
    public let bytes: [UInt8]
    public let pacerClass: PacerClass
    public let frameNumber: FrameNumber
    public let seq: ChannelSeq
    /// True for shards of an IDR/parameter-set frame (enqueued urgent).
    public let isKeyframe: Bool
}

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

    public init(
        channel: ChannelId = .videoActive,
        firstSeq: ChannelSeq = ChannelSeq(rawValue: 0),
        regime: FecRegime = .clean,
        rateBitsPerSecond: Int,
        pacerQuantumNS: UInt64 = 1_000_000
    ) {
        self.channel = channel
        self.firstSeq = firstSeq
        self.regime = regime
        self.rateBitsPerSecond = rateBitsPerSecond
        self.pacerQuantumNS = pacerQuantumNS
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

    /// The pacer is owned here for now: video is the only paced traffic
    /// on the host until the audio channel (HS-15 era) joins the send
    /// loop, at which point the Pacer lifts out to a shared owner and
    /// token tags get a channel-routing scheme. Owning keeps this slice's
    /// tag space trivially collision-free.
    private let pacer: Pacer
    private var packetizer: VideoPacketizer
    private let send: (VideoChannelDatagram) -> Void

    /// Datagrams waiting in the pacer, keyed by their token tag.
    private var pending: [UInt64: VideoChannelDatagram] = [:]
    private var nextTag: UInt64 = 0

    public init(
        config: VideoChannelConfig,
        now: UInt64,
        send: @escaping (VideoChannelDatagram) -> Void
    ) {
        self.config = config
        self.pacer = Pacer(
            rateBitsPerSecond: config.rateBitsPerSecond,
            quantumNS: config.pacerQuantumNS,
            now: now
        )
        self.packetizer = VideoPacketizer(
            channel: config.channel, firstSeq: config.firstSeq
        )
        self.send = send
    }

    /// Packetizes one encoded frame and enqueues every shard. Throws what
    /// the packetizer/envelope throw (non-frame-shaped bytes, a lying
    /// keyframe flag, an unprotectable frame size, a budget breach) —
    /// loud, per the W2 rule. Returns the number of shards enqueued.
    /// `captureTimestampMicroseconds` is the PipeWire graph-clock capture
    /// stamp; it rides the envelope timestamp field verbatim.
    @discardableResult
    public func ingest(
        frame annexB: [UInt8],
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        now: UInt64
    ) throws -> Int {
        let shards = try packetizer.packetize(
            frame: annexB,
            frameNumber: frameNumber,
            captureTimestamp: HostTimestamp(
                microseconds: captureTimestampMicroseconds
            ),
            isIDR: isKeyframe,
            regime: config.regime
        )
        for shard in shards {
            let datagram = VideoChannelDatagram(
                bytes: try shard.encodeDatagram(),
                pacerClass: .freshVideo,
                frameNumber: frameNumber,
                seq: shard.envelope.seq,
                isKeyframe: isKeyframe
            )
            let tag = nextTag
            nextTag &+= 1
            pending[tag] = datagram
            pacer.enqueue(
                .freshVideo,
                bytes: datagram.bytes.count,
                frameID: frameNumber.rawValue,
                urgent: isKeyframe,
                tag: tag,
                now: now
            )
        }
        counters.framesIngested += 1
        if isKeyframe { counters.keyframesIngested += 1 }
        counters.shardsEnqueued += shards.count
        return shards.count
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

    /// The seq the next packetized shard will carry — resumption and
    /// wrap-test visibility, mirroring the packetizer's own exposure.
    public var nextSeq: ChannelSeq {
        packetizer.nextSeq
    }
}
