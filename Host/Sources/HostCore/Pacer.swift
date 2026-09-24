// Strict-priority token-bucket send pacer. Sans-IO: every entry point
// takes `now` (monotonic ns) and the caller owns scheduling. Tokens are
// opaque byte counts with a class tag; the pacer never sees payloads.
//
// - No emitted batch exceeds `quantumNS` of wire time: burst capacity is
//   one quantum of bytes.
// - A lower class never sends while a higher class has a queued token.
//   FIFO within a class; `urgent` jumps only its own class's queue, and
//   never splits a frame: once a normal token with a frame ID leaves, the
//   rest of that frame leaves before any urgent token.
// - Control and audio never wait for the bucket: a latency-class head
//   that does not fit emits alone and charges the bucket, driving it
//   negative if need be, so the wire total still honors the rate while
//   video waits out the deficit. Otherwise the balance goes negative only
//   by an oversize token emitted alone on a full bucket.
// - Rate is injected (`setRate`); the pacer never estimates anything.

import LyteCore

/// Send classes in strict priority order; lower raw value drains first.
/// Bulk sits strictly below telemetry (mirrors `WirePriority.bulk`):
/// feedback reports price the path for every media class, and a file
/// transfer can always wait.
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
    /// Bits per second the wire is paced at; re-priced through `setRate`.
    public private(set) var rateBitsPerSecond: Int

    /// Batch quantum in nanoseconds.
    public let quantumNS: UInt64

    public private(set) var telemetry = PacerTelemetry()

    // Token bucket, in bytes. Burst capacity is exactly one quantum of
    // bytes at the current rate: that cap *is* the ≤1 ms batch bound.
    private var tokens: Double
    private var burstBytes: Double
    private var bytesPerNS: Double
    private var lastRefillAt: UInt64

    // One FIFO pair per class; urgent drains before normal, except that a
    // started normal frame finishes first. Deque storage reclaims consumed
    // slots, so a queue stays bounded by its live depth.
    private struct ClassQueue {
        var urgent = Deque<PacerToken>()
        var normal = Deque<PacerToken>()
        /// Running total of un-popped bytes, kept by push/pop so hot
        /// backlog reads never walk the queue.
        var bytesQueued = 0
        /// The frame ID of the last normal token popped: while the normal
        /// head still carries it, that frame is mid-release and outranks
        /// urgent tokens.
        var startedFrame: UInt32?

        var isEmpty: Bool { urgent.isEmpty && normal.isEmpty }

        private var continuesStartedFrame: Bool {
            startedFrame != nil && normal.first?.frameID == startedFrame
        }

        var head: PacerToken? {
            continuesStartedFrame ? normal.first : urgent.first ?? normal.first
        }

        mutating func push(_ t: PacerToken) {
            bytesQueued += t.bytes
            if t.urgent { urgent.append(t) } else { normal.append(t) }
        }

        mutating func pop() -> PacerToken? {
            let t: PacerToken
            if continuesStartedFrame {
                t = normal.popFirst()!
            } else if let u = urgent.popFirst() {
                t = u
            } else if let n = normal.popFirst() {
                t = n
            } else {
                return nil
            }
            if !t.urgent { startedFrame = t.frameID }
            bytesQueued -= t.bytes
            return t
        }

        var queuedCount: Int { urgent.count + normal.count }

        /// Every queued token, urgent first, FIFO within each.
        var queued: [PacerToken] { Array(urgent) + Array(normal) }

        /// Each FIFO is pushed in nondecreasing `enqueuedAt` order (every
        /// entry point takes the caller's monotonic `now`), so its expired
        /// tokens are a prefix: O(expired), never a copy of the backlog.
        mutating func dropEnqueued(before cutoff: UInt64) -> [PacerToken] {
            var dropped: [PacerToken] = []
            while let t = urgent.first, t.enqueuedAt < cutoff {
                dropped.append(urgent.removeFirst())
            }
            while let t = normal.first, t.enqueuedAt < cutoff {
                dropped.append(normal.removeFirst())
            }
            for token in dropped { bytesQueued -= token.bytes }
            return dropped
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
        // Start full: an isolated send after quiet goes immediately.
        self.tokens = burstBytes
        self.lastRefillAt = now
    }

    /// Applies a new rate mid-stream. Credit accrued at the old rate up to
    /// `now` is honored first; the burst cap re-sizes immediately.
    public func setRate(bitsPerSecond: Int, now: UInt64) {
        precondition(bitsPerSecond > 0, "pacer rate must be positive")
        refill(now: now)
        rateBitsPerSecond = bitsPerSecond
        bytesPerNS = Double(bitsPerSecond) / 8e9
        burstBytes = Double(quantumNS) * bytesPerNS
        tokens = min(tokens, burstBytes)
    }

    /// Queues one send unit. `urgent` jumps the FIFO of `priorityClass`
    /// only; it never crosses class boundaries and never splits a frame
    /// whose release has begun.
    public func enqueue(_ priorityClass: PacerClass, bytes: Int,
                        frameID: UInt32? = nil, urgent: Bool = false,
                        tag: UInt64 = 0, now: UInt64) {
        precondition(bytes > 0, "token must carry at least one byte")
        let token = PacerToken(priorityClass: priorityClass, bytes: bytes,
                               frameID: frameID, urgent: urgent, tag: tag,
                               enqueuedAt: now)
        queues[priorityClass.rawValue].push(token)
        telemetry.perClass[priorityClass.rawValue].tokensEnqueued += 1
    }

    public var isEmpty: Bool {
        queues.allSatisfy(\.isEmpty)
    }

    public func queuedBytes(_ c: PacerClass) -> Int {
        queues[c.rawValue].bytesQueued
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
    public func nextBatch(
        now: UInt64, upThrough highestAllowedClass: PacerClass = .bulk
    ) -> PacerBatch? {
        refill(now: now)
        var out: [PacerToken] = []
        var outBytes = 0

        while let head = highestHead(),
              head.priorityClass <= highestAllowedClass {
            let need = Double(outBytes + head.bytes)
            if need <= tokens + 1e-3 {
                let t = queues[head.priorityClass.rawValue].pop()!
                out.append(t)
                outBytes += t.bytes
                continue
            }
            // A token larger than the burst cap never fits: emit it alone
            // once the bucket is full, driving the balance negative.
            if out.isEmpty, Double(head.bytes) > burstBytes,
               tokens >= burstBytes - 1e-3 {
                let t = queues[head.priorityClass.rawValue].pop()!
                out.append(t)
                outBytes += t.bytes
            }
            // Latency exemption: control and audio emit alone whatever
            // the balance, charging the bucket.
            else if out.isEmpty, head.priorityClass <= .audio {
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
            let delay = now > t.enqueuedAt ? now - t.enqueuedAt : 0
            c.maxQueueDelayNS = max(c.maxQueueDelayNS, delay)
            telemetry.perClass[t.priorityClass.rawValue] = c
        }
        telemetry.batches += 1
        telemetry.bytesSent += outBytes
        telemetry.maxBatchBytes = max(telemetry.maxBatchBytes, outBytes)
        telemetry.maxBatchWireTimeNS = max(telemetry.maxBatchWireTimeNS, wireNS)

        return PacerBatch(tokens: out, bytes: outBytes, wireTimeNS: wireNS,
                          emittedAt: now)
    }

    /// The earliest time `nextBatch(upThrough:)` can emit, or nil when
    /// nothing it may release is queued.
    public func nextWake(
        now: UInt64, upThrough highestAllowedClass: PacerClass = .bulk
    ) -> UInt64? {
        refill(now: now)
        guard let head = highestHead(),
              head.priorityClass <= highestAllowedClass else { return nil }
        // Latency exemption: control/audio emit now, whatever the balance.
        if head.priorityClass <= .audio { return now }
        let need = min(Double(head.bytes), burstBytes)
        if tokens + 1e-3 >= need { return now }
        let deficit = need - tokens
        return now + UInt64((deficit / bytesPerNS).rounded(.up))
    }

    /// Removes and returns every queued token of `priorityClass`. The
    /// bucket balance is untouched: dropped bytes were never emitted.
    public func dropClass(_ priorityClass: PacerClass) -> [PacerToken] {
        let dropped = queues[priorityClass.rawValue].queued
        queues[priorityClass.rawValue] = ClassQueue()
        return dropped
    }

    /// Drops queued tokens enqueued before `cutoff` (deadline-bearing
    /// tail traffic). Surviving tokens keep their order.
    public func dropExpired(
        _ priorityClass: PacerClass, olderThan cutoff: UInt64
    ) -> [PacerToken] {
        queues[priorityClass.rawValue].dropEnqueued(before: cutoff)
    }

    /// Token slots a class's queue retains, live or consumed (test seam).
    func retainedTokenSlots(_ c: PacerClass) -> Int {
        queues[c.rawValue].urgent.retainedCapacity
            + queues[c.rawValue].normal.retainedCapacity
    }

    /// Reads each class queue in place rather than copying it out.
    private func highestHead() -> PacerToken? {
        for index in queues.indices where !queues[index].isEmpty {
            return queues[index].head
        }
        return nil
    }

    private func refill(now: UInt64) {
        guard now > lastRefillAt else { return }
        let elapsed = now - lastRefillAt
        tokens = min(burstBytes, tokens + Double(elapsed) * bytesPerNS)
        lastRefillAt = now
    }
}
