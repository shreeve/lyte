// Strict-priority token-bucket send pacer (HS-6). Pure logic in the
// sans-IO style: no threads, no sockets, no clock — every entry point
// takes `now` as monotonic nanoseconds and the caller owns scheduling.
// Tokens are opaque byte counts with a class tag and metadata; the pacer
// never sees payloads, envelopes, or Wire types.
//
// Invariants (protocol overview §4 rulings 1–2, resiliency §3, timing §4):
// - Batch quantum: no emitted batch exceeds `quantumNS` (default 1 ms) of
//   wire time at the configured rate. Enforced by capping bucket burst
//   capacity at one quantum of bytes.
// - Strict priority: control > audio > freshVideo > videoTail >
//   refinement > telemetry. A lower class never sends while a higher
//   class has a queued token. FIFO within a class; `urgent` tokens jump
//   only their own class's queue (IDR-on-demand), never a higher class.
// - Rate is an injected parameter (the HS-16 seam): `setRate` mid-stream
//   re-caps the bucket and stretches subsequent batches; the pacer never
//   estimates anything.
// - The frame drain bound min(2×frameInterval, 25 ms) is upstream's job
//   via frameByteCeiling; this pacer makes it measurable (per-frame
//   metadata + telemetry) and true for conforming input.

/// Send classes in strict priority order. Lower raw value = higher
/// priority (drains first). The order is the protocol overview's unified
/// ruling: CTRL/input > audio > fresh video > video tail + NACK
/// retransmits > ratchet refinement > telemetry > bulk. The bulk rung is
/// the W10/F-2 ruling (design record 20260728-053300 §1, mirrored as
/// `WirePriority.bulk`): STRICTLY below telemetry, because the 25–50 ms
/// feedback reports price the path for every media class and a 100 MB
/// file is infinitely patient where a stale report mis-prices audio.
public enum PacerClass: Int, CaseIterable, Comparable, Sendable {
    case control = 0
    case audio = 1
    case freshVideo = 2
    case videoTail = 3
    case refinement = 4
    case telemetry = 5
    case bulk = 6

    public static func < (a: PacerClass, b: PacerClass) -> Bool {
        a.rawValue < b.rawValue
    }

    public var name: String {
        switch self {
        case .control: return "control"
        case .audio: return "audio"
        case .freshVideo: return "freshVideo"
        case .videoTail: return "videoTail"
        case .refinement: return "refinement"
        case .telemetry: return "telemetry"
        case .bulk: return "bulk"
        }
    }
}

/// One queued send unit: an opaque byte count plus routing metadata.
/// `tag` is caller-owned (e.g. an index into the caller's packet store);
/// `frameID` lets tests and telemetry measure per-frame drain times.
public struct PacerToken: Equatable, Sendable {
    public let priorityClass: PacerClass
    public let bytes: Int
    public let frameID: UInt32?
    public let urgent: Bool
    public let tag: UInt64
    public let enqueuedAt: UInt64

    public init(priorityClass: PacerClass, bytes: Int, frameID: UInt32?,
                urgent: Bool, tag: UInt64, enqueuedAt: UInt64) {
        self.priorityClass = priorityClass
        self.bytes = bytes
        self.frameID = frameID
        self.urgent = urgent
        self.tag = tag
        self.enqueuedAt = enqueuedAt
    }
}

/// One emitted batch: tokens in send order, total bytes, and the wire
/// time those bytes occupy at the rate in force when the batch left.
public struct PacerBatch: Sendable {
    public let tokens: [PacerToken]
    public let bytes: Int
    public let wireTimeNS: UInt64
    public let emittedAt: UInt64
}

/// Per-class counters. Queue delay is dequeue time minus enqueue time —
/// the pacer's own contribution to latency, before NIC serialization.
public struct PacerClassCounters: Sendable {
    public var tokensEnqueued = 0
    public var tokensSent = 0
    public var bytesEnqueued = 0
    public var bytesSent = 0
    public var maxQueueDelayNS: UInt64 = 0

    public init() {}
}

public struct PacerTelemetry: Sendable {
    /// Indexed by `PacerClass.rawValue`.
    public var perClass = [PacerClassCounters](
        repeating: PacerClassCounters(), count: PacerClass.allCases.count)
    public var batches = 0
    public var bytesSent = 0
    public var maxBatchBytes = 0
    public var maxBatchWireTimeNS: UInt64 = 0

    public init() {}

    public subscript(_ c: PacerClass) -> PacerClassCounters {
        perClass[c.rawValue]
    }
}

public final class Pacer {
    /// Bits per second the wire is paced at (PacerPolicy rate: upstream
    /// supplies 0.8 × btlRate capped at the negotiated session rate;
    /// until HS-16 lands, the negotiated ceiling itself is the default).
    public private(set) var rateBitsPerSecond: Int

    /// Batch quantum in nanoseconds (1 ms per the overview ruling;
    /// resiliency owns the number, so it stays a parameter).
    public let quantumNS: UInt64

    public private(set) var telemetry = PacerTelemetry()

    // Token bucket, in bytes. Burst capacity is exactly one quantum of
    // bytes at the current rate: that cap *is* the ≤1 ms batch bound.
    private var tokens: Double
    private var burstBytes: Double
    private var bytesPerNS: Double
    private var lastRefillAt: UInt64

    // One FIFO pair per class; urgent tokens drain before normal ones
    // within the same class. Index-based heads avoid O(n) removal.
    private struct ClassQueue {
        var urgent: [PacerToken] = []
        var urgentHead = 0
        var normal: [PacerToken] = []
        var normalHead = 0

        var isEmpty: Bool {
            urgentHead >= urgent.count && normalHead >= normal.count
        }

        var head: PacerToken? {
            if urgentHead < urgent.count { return urgent[urgentHead] }
            if normalHead < normal.count { return normal[normalHead] }
            return nil
        }

        mutating func push(_ t: PacerToken) {
            if t.urgent { urgent.append(t) } else { normal.append(t) }
        }

        mutating func pop() -> PacerToken? {
            if urgentHead < urgent.count {
                let t = urgent[urgentHead]
                urgentHead += 1
                if urgentHead == urgent.count { urgent = []; urgentHead = 0 }
                return t
            }
            if normalHead < normal.count {
                let t = normal[normalHead]
                normalHead += 1
                if normalHead == normal.count { normal = []; normalHead = 0 }
                return t
            }
            return nil
        }

        var queuedBytes: Int {
            var b = 0
            for i in urgentHead..<urgent.count { b += urgent[i].bytes }
            for i in normalHead..<normal.count { b += normal[i].bytes }
            return b
        }

        var queuedCount: Int {
            (urgent.count - urgentHead) + (normal.count - normalHead)
        }
    }

    private var queues = [ClassQueue](
        repeating: ClassQueue(), count: PacerClass.allCases.count)

    public init(rateBitsPerSecond: Int, quantumNS: UInt64 = 1_000_000,
                now: UInt64) {
        precondition(rateBitsPerSecond > 0, "pacer rate must be positive")
        precondition(quantumNS > 0, "pacer quantum must be positive")
        self.rateBitsPerSecond = rateBitsPerSecond
        self.quantumNS = quantumNS
        self.bytesPerNS = Double(rateBitsPerSecond) / 8e9
        self.burstBytes = Double(quantumNS) * bytesPerNS
        // Start full: an isolated send after quiet goes immediately at
        // full quantum rate (timing §4 "aperiodicity is free").
        self.tokens = burstBytes
        self.lastRefillAt = now
    }

    /// The HS-16 seam: apply a new PacerPolicy rate mid-stream. Credit
    /// accrued at the old rate up to `now` is honored first; the burst
    /// cap immediately re-sizes so the ≤1-quantum batch bound holds at
    /// the new rate.
    public func setRate(bitsPerSecond: Int, now: UInt64) {
        precondition(bitsPerSecond > 0, "pacer rate must be positive")
        refill(now: now)
        rateBitsPerSecond = bitsPerSecond
        bytesPerNS = Double(bitsPerSecond) / 8e9
        burstBytes = Double(quantumNS) * bytesPerNS
        tokens = min(tokens, burstBytes)
    }

    /// Queues one send unit. `urgent` jumps the FIFO of `priorityClass`
    /// only (a forced IDR preempts queued non-urgent video between
    /// quanta); it never crosses class boundaries, so audio and control
    /// still go first.
    public func enqueue(_ priorityClass: PacerClass, bytes: Int,
                        frameID: UInt32? = nil, urgent: Bool = false,
                        tag: UInt64 = 0, now: UInt64) {
        precondition(bytes > 0, "token must carry at least one byte")
        let token = PacerToken(priorityClass: priorityClass, bytes: bytes,
                               frameID: frameID, urgent: urgent, tag: tag,
                               enqueuedAt: now)
        queues[priorityClass.rawValue].push(token)
        telemetry.perClass[priorityClass.rawValue].tokensEnqueued += 1
        telemetry.perClass[priorityClass.rawValue].bytesEnqueued += bytes
    }

    public var isEmpty: Bool {
        queues.allSatisfy(\.isEmpty)
    }

    public func queuedBytes(_ c: PacerClass) -> Int {
        queues[c.rawValue].queuedBytes
    }

    public func queuedCount(_ c: PacerClass) -> Int {
        queues[c.rawValue].queuedCount
    }

    /// Builds and emits the next batch, or returns nil when nothing is
    /// queued or the bucket cannot yet cover the head token. Tokens are
    /// taken strictly highest-class-first, FIFO (urgent-first) within a
    /// class; the batch closes when the current head no longer fits the
    /// remaining bucket — never by skipping ahead to a smaller
    /// lower-class token, which would invert priority.
    public func nextBatch(now: UInt64) -> PacerBatch? {
        refill(now: now)
        var out: [PacerToken] = []
        var outBytes = 0

        while let head = highestHead() {
            let need = Double(outBytes + head.bytes)
            if need <= tokens + 1e-3 {
                let t = queues[head.priorityClass.rawValue].pop()!
                out.append(t)
                outBytes += t.bytes
                continue
            }
            // A token larger than the burst cap can never fit a full
            // bucket: emit it alone once the bucket is full, driving the
            // balance negative so the overrun is paid back before the
            // next batch. Conforming callers keep datagrams under one
            // quantum of bytes and never hit this.
            if out.isEmpty, Double(head.bytes) > burstBytes,
               tokens >= burstBytes - 1e-3 {
                let t = queues[head.priorityClass.rawValue].pop()!
                out.append(t)
                outBytes += t.bytes
            }
            break
        }

        guard !out.isEmpty else { return nil }
        tokens -= Double(outBytes)

        let wireNS = UInt64((Double(outBytes) / bytesPerNS).rounded(.up))
        for t in out {
            var c = telemetry.perClass[t.priorityClass.rawValue]
            c.tokensSent += 1
            c.bytesSent += t.bytes
            c.maxQueueDelayNS = max(c.maxQueueDelayNS, now - t.enqueuedAt)
            telemetry.perClass[t.priorityClass.rawValue] = c
        }
        telemetry.batches += 1
        telemetry.bytesSent += outBytes
        telemetry.maxBatchBytes = max(telemetry.maxBatchBytes, outBytes)
        telemetry.maxBatchWireTimeNS = max(telemetry.maxBatchWireTimeNS, wireNS)

        return PacerBatch(tokens: out, bytes: outBytes, wireTimeNS: wireNS,
                          emittedAt: now)
    }

    /// The earliest time a call to `nextBatch` can emit, or nil when
    /// nothing is queued. The caller's event loop sleeps until this.
    public func nextWake(now: UInt64) -> UInt64? {
        refill(now: now)
        guard let head = highestHead() else { return nil }
        let need = min(Double(head.bytes), burstBytes)
        if tokens + 1e-3 >= need { return now }
        let deficit = need - tokens
        return now + UInt64((deficit / bytesPerNS).rounded(.up))
    }

    private func highestHead() -> PacerToken? {
        for q in queues where !q.isEmpty { return q.head }
        return nil
    }

    private func refill(now: UInt64) {
        guard now > lastRefillAt else { return }
        let elapsed = now - lastRefillAt
        tokens = min(burstBytes, tokens + Double(elapsed) * bytesPerNS)
        lastRefillAt = now
    }
}
