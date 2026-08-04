// The client's reliable CTRL sublayer (CL-7's ARQ leg) — the exact
// mirror of the host's HS-8 seam, so reliable CTRL messages flow both
// directions between HostWire.Session and this endpoint through the
// same W3 frame codecs the frozen arq-v1 vectors pin:
//
//   • one ArqEndpoint<ClientClock> owns the reliable CTRL channel in
//     both directions: `send` queues on the ordered stream (group 0),
//     `sendOneShot` on a fresh serially-ascending group; inbound sealed
//     CTRL payloads whose first byte is 0x07/0x08 route WHOLLY here
//     (the one-byte peek — such a payload is a sequence of
//     self-delimiting ARQ frames, never a single typed message).
//   • every ARQ datagram is sealed CTRL like everything else the client
//     sends — TransportSender's envelope-header-as-AAD discipline, a
//     fresh channel seq per datagram (a retransmitted SEGMENT rides a
//     fresh datagram and a fresh nonce; ArqFrames.swift on why) — and
//     is tagged with the session's connection ID once the host's
//     datagrams have taught it (the HS-12 every-packet rule; the client
//     learns the id from the TLV the host mints, it never invents one).
//   • the ARQ endpoint packs once at the carrier's REAL plaintext
//     ceiling — 1101 B with the conn-id TLV (11 B) and the AEAD tag
//     (16 B) both on the datagram (24 + 11 + 1101 + 16 = 1152 exactly).
//     The ceiling is configured before the first datagram, before the
//     conn-id is even learned, so geometry never depends on runtime
//     state and the transport shell never decodes/re-cuts ARQ output.
//   • the PTO deadline rides the client's tick machinery: every
//     send/ingest pass re-arms a timer at the endpoint's reported
//     deadline (the client-side analogue of the host folding the ARQ
//     wake into nextWake and servicing it from the idle-floor tick).
//     Tests never start the timer and drive `tick(now:)` with a virtual
//     clock — the FeedbackSender pattern.
//
// The ARQ-exempt registry traffic stays exempt by construction: beacons,
// echoes, path messages, handshake carriage, and IDR requests never pass
// through here (their type bytes are not 0x07/0x08, and their senders —
// BeaconEchoResponder, IdrRequester — keep their own fire-and-forget
// paths).
//
// F-4: the endpoint is channel-generic now (the ArqEndpoint beneath it
// always was — W10 named this exact day). The default stays `.ctrl`;
// the bulk-transfer channel (chan 8, `ChannelId.bulkTransfer`) runs a
// SECOND instance of this same class so a file transfer and a keystroke
// never share a stream — the transport pillar's independent-lanes rule,
// now real. The budget arithmetic is channel-independent (same envelope
// geometry on every channel); a chan-8 instance never sees non-ARQ
// payloads (the whole channel is ARQ carriage by design).

import LyteIO
import Dispatch
import Foundation
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
    /// Every ARQ event, in ingest order, fired outside the lock —
    /// delivered messages, one-shot acknowledgments, ignore verdicts.
    private let onEvent: (@Sendable (ArqEvent) -> Void)?

    private let lock = NSLock()
    private var arq: ArqEndpoint<ClientClock>
    /// Learned from the first host datagram carrying the TLV; tags every
    /// ARQ datagram from then on. Nil only in the pre-first-beacon
    /// window (the host's session-start beacon teaches it immediately).
    private var connectionId: ConnectionId?
    /// One-shot group ids are endpoint-allocated, serially ascending
    /// from 1 (the ArqEndpoint reuse rule).
    private var nextOneShotGroup: UInt16 = 1
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
        serviceLocked(now: now)
        lock.unlock()
    }

    /// Queues one one-shot message on a fresh group (allocated here,
    /// serially ascending — this endpoint is the sole allocator of its
    /// own group ids). Full acknowledgment surfaces as
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
        let group = ArqGroupId(rawValue: nextOneShotGroup)
        do {
            try arq.sendOneShot(message: message, group: group, now: now)
        } catch {
            lock.unlock()
            throw error
        }
        nextOneShotGroup &+= 1
        stats.messagesSent += 1
        serviceLocked(now: now)
        lock.unlock()
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
        if connectionId == nil,
           let claimed = try? ConnectionId.decode(extensions: envelope.extensions) {
            connectionId = claimed
        }
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
        serviceLocked(now: now)
        lock.unlock()
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
        defer { lock.unlock() }
        guard timer == nil else { return }
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
        serviceLocked(now: self.now())
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
        armedDeadlineMicros = nil
        serviceLocked(now: now())
        lock.unlock()
    }

    /// One timer beat: fires due PTO retransmits and re-arms. The wake
    /// timer calls this; tests call it directly with their clock.
    public func tick(now: ClientTimestamp) {
        lock.lock()
        serviceLocked(now: now)
        lock.unlock()
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
        return connectionId
    }

    /// Adopts a connection ID learned elsewhere (F-4: the chan-8
    /// endpoint borrows the ctrl endpoint's, so a bulk offer leaving
    /// before any chan-8 inbound has taught it still carries the tag —
    /// the HS-12 every-packet rule). First writer wins; nil is a no-op.
    public func adoptConnectionId(_ id: ConnectionId?) {
        guard let id else { return }
        lock.lock()
        if connectionId == nil { connectionId = id }
        lock.unlock()
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: Interior

    /// Polls the endpoint and puts its already carrier-sized output on
    /// the wire. Each datagram seals through the TransportSender like
    /// every other CTRL send (fresh channel seq, header-as-AAD, conn-id
    /// TLV once learned). Re-arms the PTO wake. Runs under the lock.
    private func serviceLocked(now: ClientTimestamp) {
        let (payloads, deadline) = arq.poll(now: now)
        if !payloads.isEmpty {
            let extensions = connectionId.map { [$0.wireExtension] } ?? []
            do {
                for payload in payloads {
                    let sent = try sender.send(
                        channel: channel,
                        timestamp: now,
                        plaintext: payload,
                        extensions: extensions
                    )
                    if sent {
                        stats.datagramsSent += 1
                    } else {
                        // No peer yet / kernel refused: the segments the
                        // poll marked sent stay armed on their PTO
                        // timers — a refused send heals like loss.
                        stats.sendFailures += 1
                    }
                }
            } catch {
                stats.sendFailures += 1
            }
        }
        // Re-schedule the production wake to the endpoint's reported
        // deadline (poll already accounts for what this pass sent) —
        // unless the armed deadline already sits within 1 ms of it
        // (PTOs are 100 ms-scale; a ≤1 ms late wake is nothing, the
        // saved churn at drag rates is hundreds of kernel timer ops/s).
        if let timer {
            if let deadline {
                let target = deadline.microseconds
                let unchanged = armedDeadlineMicros.map {
                    target >= $0 &- 1_000 && target <= $0 &+ 1_000
                } ?? false
                if !unchanged {
                    let delta = max(deadline.microseconds(since: now), 1_000)
                    timer.schedule(
                        deadline: .now() + .microseconds(Int(delta)))
                    armedDeadlineMicros = target
                }
            } else if armedDeadlineMicros != nil {
                timer.schedule(deadline: .distantFuture)
                armedDeadlineMicros = nil
            }
        }
    }

}
