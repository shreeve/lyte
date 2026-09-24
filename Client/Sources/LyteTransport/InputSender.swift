// InputSender: owns the per-session input seq, encodes 0x16 InputEvents
// onto the reliable ordered CTRL stream (a reordered keystroke is
// corruption), and measures two latency edges:
//
//   input→inject — the host's 0x17 echo tuple (seq, rx, inject) in host µs,
//     mapped onto the client clock by HostClockModel. The host-side
//     receive→inject edge is kept too.
//   input→photon — the first delivered frame stamped with lastInputSeq
//     (TLV 0x03) ≥ seq closes the loop. Delivery is the renderer handoff;
//     decode and scan-out ride on top.
//
// `send` never gates on wire mode: the host pre-arms on every delivered
// event, so input in IDLE is the wake. Every entry point takes `now`.

import LyteIO
import LyteCore
import Foundation
import LyteWire
import Synchronization

/// One coherent snapshot of the sender's books.
public struct InputSenderStats: Sendable {
    /// 0x16 messages queued on the reliable stream.
    public var eventsSent: UInt64 = 0
    /// Sends the reliable endpoint refused (the caller saw the error).
    public var sendFailures: UInt64 = 0
    /// Echo tuples consumed from delivered 0x17 messages.
    public var echoTuplesReceived: UInt64 = 0
    /// Echo tuples naming a seq never sent or already aged out.
    public var unmatchedEchoTuples: UInt64 = 0
    /// Echo tuples before the clock model had a fit (input→inject skipped).
    public var echoesWithoutClockFit: UInt64 = 0
    /// Video shards whose lastInputSeq TLV was malformed.
    public var malformedFrameStamps: UInt64 = 0
    /// The newest lastInputSeq stamp seen on any video shard.
    public var lastStampSeen: UInt32?
    /// Capture → host injection on the client clock (µs). Every input
    /// gauge rolls over the last 360 samples.
    public var inputToInject = Histogram<UInt64>(
        capacity: 360, retention: .rolling)
    /// Capture → first delivered frame stamped at or past the seq (µs).
    public var inputToPhoton = Histogram<UInt64>(
        capacity: 360, retention: .rolling)
    /// The host's own receive→inject edge (host µs, no clock mapping).
    public var hostReceiveToInject = Histogram<UInt64>(
        capacity: 360, retention: .rolling)
}

extension InputSenderStats {
    /// The overlay's input line, shown even at zero: "0 sent" separates
    /// a client-capture failure from a host-side one. "Applied on host"
    /// because the measurement includes the network leg.
    public func overlayLine() -> String {
        var line = "user:    \(eventsSent) "
            + (eventsSent == 1 ? "event" : "events") + " sent to host"
        let pair = inputToInject.percentiles([0.50, 0.99])
        if let p50 = pair[0], let p99 = pair[1] {
            line += String(
                format: " · applied on host p50/p99 %.1f/%.1f ms",
                Double(p50) / 1000, Double(p99) / 1000)
        }
        return line
    }
}

public final class InputSender: @unchecked Sendable {
    /// Pending books are bounded (a host with input off never echoes);
    /// oldest entries fall off first.
    static let maxPendingEntries = 4_096
    /// Recent frame → stamp associations; frames deliver within the
    /// assembler's holdback window.
    static let maxFrameStampEntries = 512

    private let sendMessage: (_ message: [UInt8], _ now: ClientTimestamp) throws -> Void
    private let clockModel: HostClockModel

    /// Serializes whole sends — seq allocation, the reliable enqueue and
    /// the commit — so concurrent callers can neither share a seq nor
    /// enqueue seqs out of order. Never held by the receive thread.
    private let sendLock = NSLock()
    private let lock = NSLock()
    private var nextSeq: UInt32 = 0
    /// seq → capture µs, awaiting its echo tuple (input→inject).
    private var awaitingEcho: [UInt32: UInt64] = [:]
    /// seq → capture µs, awaiting a stamped frame (input→photon).
    private var awaitingPhoton: [UInt32: UInt64] = [:]
    /// Ascending seqs for bounded eviction of both books.
    private var pendingOrder = Deque<UInt32>()
    /// frame number → lastInputSeq stamp, from shard TLVs.
    private var frameStamps: [UInt32: UInt32] = [:]
    private var frameStampOrder = Deque<UInt32>()
    private var stats = InputSenderStats()
    /// True while either pending book holds an event: the video hot
    /// path's fast-out. Lossless, because a stamp seen before a send is
    /// always below that event's seq; malformed stamps go uncounted while
    /// no input pends. Written under `lock`, read relaxed.
    private let hasPendingInput = Atomic<Bool>(false)

    public init(
        clockModel: HostClockModel,
        send: @escaping (_ message: [UInt8], _ now: ClientTimestamp) throws -> Void
    ) {
        self.clockModel = clockModel
        self.sendMessage = send
    }

    // MARK: Send

    /// `send(_:captured:now:)` with `now` as the capture instant.
    @discardableResult
    public func send(
        _ body: InputEvent.Body, now: ClientTimestamp
    ) throws -> UInt32 {
        try send(body, captured: now, now: now)
    }

    /// Encodes and queues one input event. `captured` stamps the event and
    /// its latency books; `now` drives ARQ, whose RTT must not see queue
    /// wait. A refused send allocates no seq. Concurrent callers get
    /// unique seqs enqueued in ascending order.
    @discardableResult
    public func send(
        _ body: InputEvent.Body,
        captured: ClientTimestamp,
        now: ClientTimestamp
    ) throws -> UInt32 {
        sendLock.lock()
        defer { sendLock.unlock() }
        lock.lock()
        let seq = nextSeq
        lock.unlock()
        let event = InputEvent(
            seq: seq, clientMicroseconds: captured.microseconds, body: body
        )

        // Outside the book lock: the endpoint takes its own.
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
        awaitingEcho[seq] = captured.microseconds
        awaitingPhoton[seq] = captured.microseconds
        pendingOrder.append(seq)
        evictOverflowLocked()
        refreshPendingFlagLocked()
        lock.unlock()
        return seq
    }

    // MARK: Echo consumption

    /// Consumes one delivered 0x17 echo.
    public func handleEcho(_ echo: InputEcho, now: ClientTimestamp) {
        // One fit for the whole message.
        let fit = clockModel.estimate()
        lock.lock()
        defer {
            refreshPendingFlagLocked()
            lock.unlock()
        }
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

    /// Records one video shard's lastInputSeq TLV (every shard carries it,
    /// so the association survives shard loss).
    public func noteVideoShard(envelope: Envelope) {
        guard hasPendingInput.load(ordering: .relaxed) else { return }
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

    /// Closes the photon loop for every pending seq ≤ the delivered
    /// frame's stamp (wrap-aware).
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
        refreshPendingFlagLocked()
    }

    // MARK: Snapshots

    public func snapshotStats() -> InputSenderStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Events still awaiting an echo.
    public var pendingEchoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return awaitingEcho.count
    }

    // MARK: Interior

    /// Runs under the lock.
    private func evictOverflowLocked() {
        while pendingOrder.count > Self.maxPendingEntries {
            let seq = pendingOrder.removeFirst()
            awaitingEcho.removeValue(forKey: seq)
            awaitingPhoton.removeValue(forKey: seq)
        }
    }

    /// Runs under the lock after any book mutation.
    private func refreshPendingFlagLocked() {
        hasPendingInput.store(
            !awaitingEcho.isEmpty || !awaitingPhoton.isEmpty,
            ordering: .relaxed
        )
    }
}

/// Queue-side timing owned by the ordered input hop.
public final class InputSendTiming: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var queued: UInt64
        public var sent: UInt64
        public var failed: UInt64
        public var queueWaitMicroseconds: Histogram<UInt64>
    }

    private let lock = NSLock()
    private var queuedCount: UInt64 = 0
    private var sentCount: UInt64 = 0
    private var failedCount: UInt64 = 0
    private var waits = Histogram<UInt64>(capacity: 360, retention: .rolling)

    func queued() {
        lock.lock(); queuedCount += 1; lock.unlock()
    }

    func sent(queueMicroseconds: UInt64) {
        lock.lock()
        sentCount += 1
        waits.record(queueMicroseconds)
        lock.unlock()
    }

    func failed() {
        lock.lock(); failedCount += 1; lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            queued: queuedCount, sent: sentCount, failed: failedCount,
            queueWaitMicroseconds: waits)
    }
}

/// The app capture path's ordered hop, so ARQ/seal/socket work never runs
/// on MainActor.
public final class OrderedInputSender: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "lyte.input.sender", qos: .userInteractive)
    private let lock = NSLock()
    private var accepting = true
    private var cancelled = false
    private let timing = InputSendTiming()
    private let send: @Sendable (InputEvent.Body, ClientTimestamp) throws -> Void

    public init(
        send: @escaping @Sendable (
            InputEvent.Body, ClientTimestamp
        ) throws -> Void
    ) {
        self.send = send
    }

    @discardableResult
    public func enqueue(
        _ body: InputEvent.Body,
        capturedNanoseconds: UInt64 = SystemMonotonicClock.nowNanoseconds
    ) -> Bool {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return false
        }
        // Acceptance and queue insertion are one critical section, so
        // finishAndDrain never misses an accepted event.
        timing.queued()
        queue.async { [self] in
            lock.lock()
            let maySend = !cancelled
            lock.unlock()
            guard maySend else { return }
            let started = SystemMonotonicClock.nowNanoseconds
            do {
                try send(
                    body,
                    ClientTimestamp(
                        microseconds: capturedNanoseconds / 1_000))
                timing.sent(
                    queueMicroseconds: (started &- capturedNanoseconds) / 1_000)
            } catch {
                timing.failed()
            }
        }
        lock.unlock()
        return true
    }

    public func stop() {
        lock.lock()
        accepting = false
        cancelled = true
        lock.unlock()
    }

    /// Orderly close: reject new captures, let everything already accepted
    /// (including synthesized held-key releases) finish in order, then fence.
    public func finishAndDrain() {
        lock.lock(); accepting = false; lock.unlock()
        queue.sync {}
        lock.lock(); cancelled = true; lock.unlock()
    }

    public var snapshot: InputSendTiming.Snapshot { timing.snapshot() }

    /// Deterministic gate seam; production never waits on input work.
    public func drainForTesting() {
        queue.sync {}
    }
}
