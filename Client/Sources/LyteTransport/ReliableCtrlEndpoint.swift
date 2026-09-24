// The client's reliable sublayer over one channel, the mirror of the
// host's, speaking the frame codecs the frozen arq-v1 vectors pin:
//
//   • one ArqEndpoint<ClientClock> owns the channel's reliable traffic in
//     both directions: `send` queues on the ordered stream (group 0),
//     `sendOneShot` on a fresh serially-ascending group; inbound sealed
//     payloads whose first byte is 0x07/0x08 route wholly here (the
//     one-byte peek — such a payload is a sequence of self-delimiting ARQ
//     frames, never a single typed message).
//   • every ARQ datagram is sealed like everything else the client sends
//     (header-as-AAD, a fresh channel seq and nonce per datagram, so a
//     retransmitted segment rides a fresh datagram) and is tagged with the
//     session's connection ID once the host's datagrams have taught it;
//     the client learns the id, it never invents one.
//   • the ARQ endpoint packs once at the carrier's real plaintext ceiling
//     — 1101 B with the conn-id TLV (11 B) and the AEAD tag (16 B) both
//     on the datagram (24 + 11 + 1101 + 16 = 1152 exactly) — configured
//     before the first datagram, so geometry never depends on runtime
//     state and the shell never re-cuts ARQ output.
//   • the PTO deadline rides a timer re-armed after every send/ingest
//     pass. Tests never start it and drive `tick(now:)` with a virtual
//     clock.
//
// ARQ-exempt traffic stays exempt by construction: beacons, echoes, path
// messages, handshake carriage and IDR requests have other type bytes and
// their own fire-and-forget senders.
//
// The session runs two instances: `.ctrl`, and the bulk-transfer channel
// (chan 8), so a file transfer and a keystroke never share a stream. A
// chan-8 instance never sees non-ARQ payloads.

import LyteIO
import Dispatch
import Foundation
import LyteClientSession
import LyteWire

public final class ReliableCtrlEndpoint: @unchecked Sendable {
    /// Reliable-sublayer counters, snapshotted for the CLI.
    public struct Stats: Sendable {
        /// Messages queued outbound (stream + one-shots).
        public var messagesSent: UInt64 = 0
        /// Messages the ARQ delivered inbound — exactly once, in order
        /// within their group.
        public var messagesDelivered: UInt64 = 0
        /// One-shot groups this endpoint sent that are fully acknowledged.
        public var oneShotsAcknowledged: UInt64 = 0
        /// Sealed CTRL datagrams carrying ARQ frames, fresh and
        /// retransmit — the loss-gate's retransmission evidence.
        public var datagramsSent: UInt64 = 0
        /// Ingested ARQ bytes the endpoint refused or deduplicated
        /// (routine protocol weather included).
        public var ingestIgnored: UInt64 = 0
        /// ARQ datagrams the send path refused (seal failure, no peer) —
        /// each heals like a lost datagram on the PTO timer.
        public var sendFailures: UInt64 = 0
    }

    private let sender: TransportSender
    /// The channel this endpoint's datagrams ride (`.ctrl` for the
    /// session's control stream, `.bulkTransfer` for chan 8).
    public let channel: ChannelId
    private let now: @Sendable () -> ClientTimestamp
    /// Every ARQ event, in ingest order, fired outside the lock on the
    /// thread that called `handleCtrlDatagram` (the receive thread in
    /// production) — delivered messages, one-shot acknowledgments,
    /// ignore verdicts.
    private let onEvent: (@Sendable (ArqEvent) -> Void)?

    private let lock = NSLock()
    /// Orders transmissions: taken while `lock` is still held, so polled
    /// batches reach the sender in poll order. Never held while taking
    /// `lock`.
    private let transmitLock = NSLock()
    private var arq: ArqEndpoint<ClientClock>
    /// Learned from the first host datagram carrying the TLV; tags every
    /// ARQ datagram from then on. Empty only in the pre-first-beacon
    /// window (the host's session-start beacon teaches it immediately).
    private var connectionId = ClientConnectionIdBook()
    private var stats = Stats()
    /// The production PTO wake; nil until `start()`. Re-scheduled to the
    /// endpoint's reported deadline after every service pass.
    private var timer: DispatchSourceTimer?
    /// The absolute deadline (µs) the timer is currently armed at, nil
    /// when nothing is armed (fresh, fired, or parked). Pointer drags
    /// run a service pass per event and per host ACK — hundreds/s —
    /// nearly always re-deriving an unchanged PTO deadline; re-arming
    /// the kernel timer for a <1 ms move is churn without effect, so
    /// the reschedule skips inside that band. Guarded by `lock`.
    private var armedDeadlineMicros: UInt64?
    /// When true, `serviceLocked` runs re-arm bookkeeping without a live
    /// DispatchSource so virtual-time tests can pin the wake path.
    var testingAssumeTimerPresent = false
    /// After the latest service pass that evaluated re-arm: true when the
    /// unchanged-deadline band skipped `timer.schedule`.
    private(set) var testingRescheduleSkipped = false

    public init(
        sender: TransportSender,
        channel: ChannelId = .ctrl,
        config: ArqConfig = ArqConfig(),
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(microseconds: SystemMonotonicClock.nowMicroseconds)
        },
        onEvent: (@Sendable (ArqEvent) -> Void)? = nil
    ) {
        // Pack once at the smallest ceiling: a caller may deliberately
        // ask for less, but never more than the established carrier can
        // hold once its connection-id extension and AEAD tag ride along.
        var bounded = config
        bounded.maxDatagramPayloadByteCount = min(
            bounded.maxDatagramPayloadByteCount,
            WireBudget.maxConnectionIdTaggedPlaintextByteCount
        )
        self.arq = ArqEndpoint(channel: channel, config: bounded)
        self.sender = sender
        self.channel = channel
        self.now = now
        self.onEvent = onEvent
    }

    // MARK: Send

    /// Queues one message on the reliable ordered CTRL stream (ARQ group
    /// 0): exactly-once, in-order delivery, RTT-adaptive retransmit until
    /// acknowledged. The message must start with its own CTRL type byte
    /// (the registry rule). Throws `ArqSendError` for an empty or
    /// over-budget message; fresh segments leave in this same call.
    ///
    /// `ArqSendError.queueFull` is backpressure, and every session caller
    /// treats it as a refused send: input counts a failed event, clipboard
    /// returns `.sendRefused`, control replies and the teardown surface a
    /// protocol note. On CTRL a group that deep means the host stopped
    /// acknowledging, and the lifecycle's liveness clock ends the session;
    /// on chan 8 the bulk and clipboard read-ahead caps keep honest
    /// traffic far below the bound.
    public func send(_ message: [UInt8]) throws {
        try send(message, now: now())
    }

    /// Injected-clock variant (tests drive time explicitly).
    public func send(_ message: [UInt8], now: ClientTimestamp) throws {
        lock.lock()
        do {
            try arq.send(message: message, now: now)
        } catch {
            lock.unlock()
            throw error
        }
        stats.messagesSent += 1
        serviceAndUnlock(now: now)
    }

    /// Queues one one-shot message on a fresh group (ArqEndpoint
    /// allocates it: serially ascending, never 0, wrap-safe). Full acknowledgment surfaces as
    /// `.oneShotAcknowledged` through `onEvent`. Returns the group.
    @discardableResult
    public func sendOneShot(_ message: [UInt8]) throws -> ArqGroupId {
        try sendOneShot(message, now: now())
    }

    @discardableResult
    public func sendOneShot(
        _ message: [UInt8], now: ClientTimestamp
    ) throws -> ArqGroupId {
        lock.lock()
        let group: ArqGroupId
        do {
            group = try arq.sendOneShot(message: message, now: now)
        } catch {
            lock.unlock()
            throw error
        }
        stats.messagesSent += 1
        serviceAndUnlock(now: now)
        return group
    }

    // MARK: Ingest

    /// Feeds one accepted CTRL datagram — the receive path's routing
    /// hook. Learns the connection ID from the envelope's TLV block (the
    /// host tags every datagram), then the one-byte peek: a payload
    /// starting with 0x07/0x08 is wholly ARQ and is consumed here (the
    /// ACK the ingest owes, and any fast retransmit it triggered, leave
    /// in this same pass); anything else returns false untouched.
    @discardableResult
    public func handleCtrlDatagram(
        envelope: Envelope, payload: [UInt8]
    ) -> Bool {
        handleCtrlDatagram(envelope: envelope, payload: payload, now: now())
    }

    @discardableResult
    public func handleCtrlDatagram(
        envelope: Envelope, payload: [UInt8], now: ClientTimestamp
    ) -> Bool {
        lock.lock()
        connectionId.learn(from: envelope)
        guard let type = payload.first,
              type == CtrlMessageType.arqSegment || type == CtrlMessageType.arqAck
        else {
            lock.unlock()
            return false
        }
        let events = arq.ingest(payload: payload, now: now)
        for event in events {
            switch event {
            case .message: stats.messagesDelivered += 1
            case .oneShotAcknowledged: stats.oneShotsAcknowledged += 1
            case .ignored: stats.ingestIgnored += 1
            }
        }
        serviceAndUnlock(now: now)
        for event in events {
            onEvent?(event)
        }
        return true
    }

    // MARK: Timers

    /// Arms the production PTO wake. Idempotent. Without it the caller
    /// owns the clock and drives `tick(now:)` (tests, always).
    public func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(
            queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.timerFired()
        }
        source.resume()
        timer = source
        // Work may already be pending from a pre-start send: service it
        // (a bare re-arm could see a due timer and push it a full PTO).
        serviceAndUnlock(now: self.now())
    }

    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        armedDeadlineMicros = nil
        lock.unlock()
        source?.cancel()
    }

    /// The wake path: the one-shot fired, so NOTHING is armed anymore —
    /// the skip bookkeeping must clear before the service pass re-arms,
    /// or an unchanged deadline would skip the re-arm and sleep forever.
    private func timerFired() {
        lock.lock()
        wakeFromTimerAndUnlock(now: now())
    }

    /// Virtual-time wake — same clear-then-service order as production
    /// `timerFired`. `tick` must not clear: tests drive it without a live
    /// DispatchSource, so the skip bookkeeping is unused.
    func testingWakeFromTimer(now: ClientTimestamp) {
        lock.lock()
        wakeFromTimerAndUnlock(now: now)
    }

    /// The absolute µs the re-arm book currently holds, nil when nothing
    /// is armed — the sleep-forever pin's probe.
    var testingArmedDeadlineMicros: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return armedDeadlineMicros
    }

    private func wakeFromTimerAndUnlock(now: ClientTimestamp) {
        armedDeadlineMicros = nil
        serviceAndUnlock(now: now)
    }

    /// One timer beat: fires due PTO retransmits and re-arms. The wake
    /// timer calls this; tests call it directly with their clock.
    public func tick(now: ClientTimestamp) {
        lock.lock()
        serviceAndUnlock(now: now)
    }

    /// True when the sublayer has nothing left to send, retransmit, or
    /// acknowledge (the W-G4 termination property, exposed for idle
    /// accounting and the gate tests).
    public var isQuiescent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return arq.isQuiescent
    }

    /// The endpoint's next PTO deadline, nil when no timer is armed —
    /// the gate tests' wake-machinery probe.
    public var nextDeadline: ClientTimestamp? {
        lock.lock()
        defer { lock.unlock() }
        var probe = arq
        let (_, deadline) = probe.poll(now: ClientTimestamp(microseconds: 0))
        return deadline
    }

    /// The connection ID the host's datagrams taught, nil before the
    /// first TLV-tagged arrival.
    public var learnedConnectionId: ConnectionId? {
        lock.lock()
        defer { lock.unlock() }
        return connectionId.learned
    }

    /// Adopts a connection ID learned elsewhere (F-4: the chan-8
    /// endpoint borrows the ctrl endpoint's, so a bulk offer leaving
    /// before any chan-8 inbound has taught it still carries the tag —
    /// the HS-12 every-packet rule). First writer wins; nil is a no-op.
    public func adoptConnectionId(_ id: ConnectionId?) {
        guard let id else { return }
        lock.lock()
        connectionId.adopt(id)
        lock.unlock()
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: Interior

    /// Polls the endpoint, re-arms the PTO wake, and puts the poll's
    /// already carrier-sized output on the wire. Entered with `lock` held;
    /// returns with it released. Each datagram seals through the
    /// TransportSender like every other send (fresh channel seq,
    /// header-as-AAD, conn-id TLV once learned).
    ///
    /// The seal and `sendto` run outside `lock`, so ingest, stats and
    /// quiescence readers never wait on a syscall. `transmitLock` is taken
    /// before `lock` is released, so batches leave in poll order.
    private func serviceAndUnlock(now: ClientTimestamp) {
        let payloads = serviceLocked(now: now)
        guard !payloads.isEmpty else {
            lock.unlock()
            return
        }
        let extensions = connectionId.extensions
        transmitLock.lock()
        lock.unlock()
        var sent: UInt64 = 0
        var failed: UInt64 = 0
        do {
            for payload in payloads {
                if try sender.send(
                    channel: channel,
                    timestamp: now,
                    plaintext: payload,
                    extensions: extensions
                ) {
                    sent += 1
                } else {
                    // No peer yet / kernel refused: the segments the
                    // poll marked sent stay armed on their PTO timers —
                    // a refused send heals like loss.
                    failed += 1
                }
            }
        } catch {
            failed += 1
        }
        transmitLock.unlock()
        lock.lock()
        stats.datagramsSent += sent
        stats.sendFailures += failed
        lock.unlock()
    }

    /// Polls the endpoint and re-arms the production wake. Runs under
    /// `lock`; returns the payloads to transmit.
    private func serviceLocked(now: ClientTimestamp) -> [[UInt8]] {
        let (payloads, deadline) = arq.poll(now: now)
        // Re-schedule the production wake to the endpoint's reported
        // deadline (poll already accounts for what this pass sent) —
        // unless the armed deadline already sits within 1 ms of it
        // (PTOs are 100 ms-scale; a ≤1 ms late wake is nothing, the
        // saved churn at drag rates is hundreds of kernel timer ops/s).
        // `testingAssumeTimerPresent` lets virtual-time tests exercise
        // the same bookkeeping without a live DispatchSource.
        if timer != nil || testingAssumeTimerPresent {
            if let deadline {
                let target = deadline.microseconds
                let unchanged = armedDeadlineMicros.map {
                    target >= $0 &- 1_000 && target <= $0 &+ 1_000
                } ?? false
                testingRescheduleSkipped = unchanged
                if !unchanged {
                    if let timer {
                        let delta = max(deadline.microseconds(since: now), 1_000)
                        timer.schedule(
                            deadline: .now() + .microseconds(Int(delta)))
                    }
                    armedDeadlineMicros = target
                }
            } else if armedDeadlineMicros != nil {
                testingRescheduleSkipped = false
                timer?.schedule(deadline: .distantFuture)
                armedDeadlineMicros = nil
            }
        }
        return payloads
    }

}
