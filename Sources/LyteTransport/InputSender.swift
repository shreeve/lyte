// InputSender (CL-9): the client half of HS-13's input path, sans-IO.
// Owns the per-session seq counter, encodes 0x16 InputEvents onto the
// reliable ordered CTRL stream (a reordered keystroke is corruption,
// not weather — the transport pillar's ruling), and closes the two
// latency loops the host's accounting makes possible:
//
//   input→inject — the host answers every injection with a 0x17 echo
//     tuple (seq, rxMicros, injectMicros) in the beacon's host-µs
//     domain; the CL-10 HostClockModel maps injectMicros onto the
//     client's own timeline, so the edge is (mapped inject − capture).
//     The host-side receive→inject edge (inject − rx, no clock model
//     needed) is kept too — it is HS-13's own gate figure and a free
//     cross-check.
//
//   input→photon — the host stamps lastInputSeq (TLV 0x03) on every
//     shard of every post-injection video frame; the first DELIVERED
//     sample whose frame carries a stamp ≥ seq closes the loop at
//     (delivery − capture). Honest naming caveat, the CL-8 pattern:
//     delivery is the sample-buffer handoff to the renderer — VT decode
//     + display scan-out ride on top (HS-13's spike measured that tail
//     at ~13 ms); the wire+assembly path is what this edge owns.
//
// Pre-arm (W4b via HS-13): the host runs `.preArmInput` on EVERY
// delivered 0x16 BEFORE injecting — a keypress in IDLE is the WAKE and
// one during a blackout survives FROZEN into RECOVERY's IDR. Driving
// that seam from this end therefore means exactly one thing: send the
// event promptly and NEVER gate on the wire mode or the local overlay.
// `send` deliberately has no mode check.
//
// Sans-IO: no clock reads, no sockets — every entry point takes `now`,
// the send leg is an injected closure (the session wires it to
// ReliableCtrlEndpoint.send), and tests drive the whole loop in virtual
// time. One lock confines the pending books and the histograms.

import Foundation
import LyteWire

/// Exact-percentile latency aggregator — the byte-for-byte shape of
/// HostCore.Histogram (HS-13's edge instrumentation; the root package
/// cannot import HostCore, and the aggregator is ~40 lines of pure
/// Swift). Capped so a runaway producer cannot grow memory without
/// bound: samples past the cap still count and still update min/max,
/// `saturated` says the percentile pool is a prefix.
public struct LatencyHistogram: Sendable {
    public private(set) var count = 0
    public private(set) var minValue: UInt64?
    public private(set) var maxValue: UInt64?
    /// True once the ring has wrapped: percentiles now describe the
    /// most RECENT `capacity` samples, not the whole session.
    public private(set) var saturated = false

    private var samples: [UInt64] = []
    private var writeIndex = 0
    private let capacity: Int

    /// A ROLLING window (owner ruling 2026-07-30): the pre-ring shape
    /// kept the session's FIRST `capacity` samples and froze — an
    /// overlay gauge that described the opening minute forever. The
    /// ring keeps the newest; `count`/`minValue`/`maxValue` stay
    /// session-cumulative (they are odometers, not gauges).
    public init(capacity: Int = 1 << 16) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func record(_ value: UInt64) {
        count += 1
        minValue = minValue.map { Swift.min($0, value) } ?? value
        maxValue = maxValue.map { Swift.max($0, value) } ?? value
        if samples.count < capacity {
            samples.append(value)
        } else {
            samples[writeIndex] = value
            saturated = true
        }
        writeIndex = (writeIndex + 1) % capacity
    }

    /// The exact q-quantile (0...1) over the retained samples by the
    /// nearest-rank method; nil when nothing was recorded.
    public func percentile(_ q: Double) -> UInt64? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let clamped = Swift.min(Swift.max(q, 0), 1)
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        return sorted[Swift.max(rank, 1) - 1]
    }

    public var p50: UInt64? { percentile(0.50) }
    public var p95: UInt64? { percentile(0.95) }
    public var p99: UInt64? { percentile(0.99) }
}

/// One coherent snapshot of the sender's books.
public struct InputSenderStats: Sendable {
    /// 0x16 messages queued on the reliable stream.
    public var eventsSent: UInt64 = 0
    /// Sends the reliable endpoint refused (thrown) — the caller saw
    /// the same error; counted here for the stats line.
    public var sendFailures: UInt64 = 0
    /// Echo tuples consumed from delivered 0x17 messages.
    public var echoTuplesReceived: UInt64 = 0
    /// Echo tuples naming a seq this sender never sent (or already
    /// aged out) — protocol weather worth a counter, never fatal.
    public var unmatchedEchoTuples: UInt64 = 0
    /// Echo tuples that arrived before the clock model had a fit —
    /// their receive→inject edge still recorded; input→inject skipped.
    public var echoesWithoutClockFit: UInt64 = 0
    /// Video shards whose lastInputSeq TLV was malformed (duplicate or
    /// wrong width) — loud counter, per the conn-id TLV's decode rule.
    public var malformedFrameStamps: UInt64 = 0
    /// The newest lastInputSeq stamp seen on any video shard.
    public var lastStampSeen: UInt32?
    /// input→inject: capture → host injection, mapped onto the client
    /// clock via the CL-10 model (µs).
    public var inputToInject = LatencyHistogram()
    /// input→photon: capture → the first delivered sample stamped at or
    /// past the event's seq (µs; see the file comment's honesty caveat).
    public var inputToPhoton = LatencyHistogram()
    /// The host's own receive→inject edge (host µs, no clock mapping)
    /// — HS-13's gate figure, echoed back for free.
    public var hostReceiveToInject = LatencyHistogram()
}

extension InputSenderStats {
    /// The stream overlay's input line (CL-16). Rendered
    /// UNCONDITIONALLY while a session runs: "input 0 sent" is the
    /// datum that discriminates a client-capture failure from a
    /// host-side one, so hiding the line at zero hid exactly the
    /// interesting case. Carries the capture-install verdict for the
    /// same reason — a failed install must be distinguishable from a
    /// dead host.
    public func overlayLine() -> String {
        // Naming (owner-shaped, two consult rounds, 2026-07-30):
        // "applied on host" not "inject" — the measurement rides host
        // echoes and INCLUDES the network leg, so the honest claim is
        // "your action took effect on the host", not an OS-injection
        // micro-timing. Capture state moved to the overlay's state
        // line (it's a session state, not a metric).
        var line = "user:    \(eventsSent) "
            + (eventsSent == 1 ? "event" : "events") + " sent to host"
        if let p50 = inputToInject.p50, let p99 = inputToInject.p99 {
            line += String(
                format: " · applied on host p50/p99 %.1f/%.1f ms",
                Double(p50) / 1000, Double(p99) / 1000)
        }
        return line
    }
}

public final class InputSender: @unchecked Sendable {
    /// Pending books are bounded: input with injection off (the host's
    /// `--input off`) never echoes, and an unmatched book must not grow
    /// for the length of a session. Oldest entries fall off first —
    /// they were failed measurements already.
    static let maxPendingEntries = 4_096
    /// frame → stamp associations kept for the delivery lookup. Frames
    /// deliver within the assembler's holdback window, so a small ring
    /// of recent frames is plenty.
    static let maxFrameStampEntries = 512

    private let sendMessage: (_ message: [UInt8], _ now: ClientTimestamp) throws -> Void
    private let clockModel: HostClockModel

    private let lock = NSLock()
    private var nextSeq: UInt32 = 0
    /// seq → capture µs, awaiting its echo tuple (input→inject).
    private var awaitingEcho: [UInt32: UInt64] = [:]
    /// seq → capture µs, awaiting a stamped frame (input→photon).
    private var awaitingPhoton: [UInt32: UInt64] = [:]
    /// Insertion-ordered seqs for bounded eviction (one order serves
    /// both books — seqs are allocated ascending).
    private var pendingOrder: [UInt32] = []
    /// frame number → lastInputSeq stamp, from shard TLVs.
    private var frameStamps: [UInt32: UInt32] = [:]
    private var frameStampOrder: [UInt32] = []
    private var stats = InputSenderStats()

    public init(
        clockModel: HostClockModel,
        send: @escaping (_ message: [UInt8], _ now: ClientTimestamp) throws -> Void
    ) {
        self.clockModel = clockModel
        self.sendMessage = send
    }

    // MARK: Send

    /// Encodes and queues one input event on the reliable ordered
    /// stream, stamping it with `now` (the capture instant) and the
    /// next session seq. Never gates on wire mode — an event in IDLE
    /// is the host's WAKE, one in FROZEN persists into RECOVERY (the
    /// pre-arm rule; see the file comment). Throws what the reliable
    /// endpoint throws; a refused send allocates no seq.
    @discardableResult
    public func send(
        _ body: InputEvent.Body, now: ClientTimestamp
    ) throws -> UInt32 {
        lock.lock()
        let seq = nextSeq
        let event = InputEvent(
            seq: seq, clientMicroseconds: now.microseconds, body: body
        )
        lock.unlock()

        // The reliable send outside the lock (it takes its own and
        // fires fresh segments synchronously).
        do {
            try sendMessage(event.encode(), now)
        } catch {
            lock.lock()
            stats.sendFailures += 1
            lock.unlock()
            throw error
        }

        lock.lock()
        nextSeq &+= 1
        stats.eventsSent += 1
        awaitingEcho[seq] = now.microseconds
        awaitingPhoton[seq] = now.microseconds
        pendingOrder.append(seq)
        evictOverflowLocked()
        lock.unlock()
        return seq
    }

    // MARK: Echo consumption

    /// Consumes one delivered 0x17: every tuple closes its seq's
    /// input→inject edge (via the clock model's current fit) and
    /// records the host's own receive→inject edge verbatim.
    public func handleEcho(_ echo: InputEcho, now: ClientTimestamp) {
        // One fit for the whole message — mapping tuples against a
        // window that moves between tuples would smear the math.
        let fit = clockModel.estimate()
        lock.lock()
        defer { lock.unlock() }
        for tuple in echo.tuples {
            stats.echoTuplesReceived += 1
            stats.hostReceiveToInject.record(
                tuple.injectedMicroseconds &- tuple.receivedMicroseconds
            )
            guard let sentMicros = awaitingEcho.removeValue(
                forKey: tuple.seq
            ) else {
                stats.unmatchedEchoTuples += 1
                continue
            }
            guard let fit else {
                stats.echoesWithoutClockFit += 1
                continue
            }
            let injectedOnClientClock = fit.map(HostTimestamp(
                microseconds: tuple.injectedMicroseconds
            ))
            // Clamp at zero: the model's residual (~sub-ms) can put a
            // same-millisecond injection nominally "before" capture.
            let edge = Int64(bitPattern:
                injectedOnClientClock.microseconds &- sentMicros)
            stats.inputToInject.record(UInt64(max(edge, 0)))
        }
    }

    // MARK: Frame stamps (input→photon)

    /// Records one video shard's lastInputSeq TLV (any shard of the
    /// frame serves — per-shard stamping is exactly so the association
    /// survives shard loss). Call from the datagram ingest path with
    /// the envelope's extensions.
    public func noteVideoShard(envelope: Envelope) {
        let stamp: UInt32?
        do {
            stamp = try LastInputSeqTlv.decode(extensions: envelope.extensions)
        } catch {
            lock.lock()
            stats.malformedFrameStamps += 1
            lock.unlock()
            return
        }
        guard let stamp else { return }
        lock.lock()
        defer { lock.unlock() }
        stats.lastStampSeen = stamp
        let frame = envelope.frame.rawValue
        if frameStamps[frame] == nil {
            frameStampOrder.append(frame)
            if frameStampOrder.count > Self.maxFrameStampEntries {
                frameStamps.removeValue(forKey: frameStampOrder.removeFirst())
            }
        }
        frameStamps[frame] = stamp
    }

    /// Closes the photon loop for one DELIVERED frame: every pending
    /// event with seq ≤ the frame's stamp (wrap-aware) completes at
    /// `now`. Call from the onSample seam — delivery, not shard
    /// arrival, is the honest instant.
    public func noteFrameDelivered(frame: FrameNumber, now: ClientTimestamp) {
        lock.lock()
        defer { lock.unlock() }
        guard let stamp = frameStamps[frame.rawValue],
              !awaitingPhoton.isEmpty else { return }
        var closed: [UInt32] = []
        for (seq, sentMicros) in awaitingPhoton
        where Int32(bitPattern: stamp &- seq) >= 0 {
            let edge = Int64(bitPattern: now.microseconds &- sentMicros)
            stats.inputToPhoton.record(UInt64(max(edge, 0)))
            closed.append(seq)
        }
        for seq in closed {
            awaitingPhoton.removeValue(forKey: seq)
        }
    }

    // MARK: Snapshots

    public func snapshotStats() -> InputSenderStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Events still awaiting an echo (the live gate's quiescence probe).
    public var pendingEchoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return awaitingEcho.count
    }

    // MARK: Interior

    /// Oldest-first eviction once the pending books outgrow the bound.
    /// Runs under the lock.
    private func evictOverflowLocked() {
        while pendingOrder.count > Self.maxPendingEntries {
            let seq = pendingOrder.removeFirst()
            awaitingEcho.removeValue(forKey: seq)
            awaitingPhoton.removeValue(forKey: seq)
        }
    }
}
