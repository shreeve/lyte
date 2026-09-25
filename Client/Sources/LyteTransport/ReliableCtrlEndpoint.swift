// The client's reliable sublayer over one channel (`.ctrl` or chan 8): one
// ArqEndpoint<ClientClock> owns the channel's reliable traffic both ways.
// Inbound payloads starting 0x07/0x08 are wholly ARQ and route here. Every
// ARQ datagram is sealed with a fresh channel seq and tagged with the
// connection ID once the host has taught it (never invented). The endpoint
// packs once at the conn-id-tagged plaintext ceiling, so the shell never
// re-cuts ARQ output. The PTO timer re-arms after every pass; tests drive
// `tick(now:)` instead.

import LyteIO
import Dispatch
import Foundation
import LyteClientSession
import LyteWire

public final class ReliableCtrlEndpoint: @unchecked Sendable {
    /// Reliable-sublayer counters, snapshotted for the CLI.
    public struct Stats: Sendable {
        /// Messages queued outbound.
        public var messagesSent: UInt64 = 0
        /// Messages the ARQ delivered inbound.
        public var messagesDelivered: UInt64 = 0
        /// One-shot groups acknowledged (the client sends none).
        public var oneShotsAcknowledged: UInt64 = 0
        /// Sealed datagrams carrying ARQ frames, fresh and retransmit.
        public var datagramsSent: UInt64 = 0
        /// Ingested ARQ bytes the endpoint refused or deduplicated.
        public var ingestIgnored: UInt64 = 0
        /// ARQ datagrams the send path refused; each heals like loss.
        public var sendFailures: UInt64 = 0
    }

    private let sender: TransportSender
    public let channel: ChannelId
    private let now: @Sendable () -> ClientTimestamp
    /// Every ARQ event, in ingest order, fired outside the lock on the
    /// thread that called `handleCtrlDatagram`.
    private let onEvent: (@Sendable (ArqEvent) -> Void)?

    private let lock = NSLock()
    /// Orders transmissions: taken while `lock` is still held, so polled
    /// batches reach the sender in poll order. Never held while taking
    /// `lock`.
    private let transmitLock = NSLock()
    private var arq: ArqEndpoint<ClientClock>
    /// Learned from the first host datagram carrying the TLV.
    private var connectionId = ClientConnectionIdBook()
    private var stats = Stats()
    /// The production PTO wake; nil until `start()`.
    private var timer: DispatchSourceTimer?
    /// The absolute deadline (µs) the timer is armed at, nil when nothing
    /// is armed. A reschedule within 1 ms of it is skipped (pointer drags
    /// re-derive the same deadline hundreds of times a second). Guarded by
    /// `lock`.
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

    /// Queues one message (starting with its CTRL type byte) on the ordered
    /// stream, group 0; fresh segments leave in this call. Throws
    /// `ArqSendError`; callers treat `.queueFull` as a refused send (on
    /// CTRL it means the host stopped acknowledging, and liveness ends the
    /// session).
    public func send(_ message: [UInt8], now: ClientTimestamp? = nil) throws {
        let now = now ?? self.now()
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

    // MARK: Ingest

    /// Learns the connection ID from the envelope, then consumes a
    /// 0x07/0x08 payload (its ACK leaves in this pass) and returns true;
    /// anything else returns false untouched.
    @discardableResult
    public func handleCtrlDatagram(
        envelope: Envelope, payload: [UInt8], now: ClientTimestamp? = nil
    ) -> Bool {
        let now = now ?? self.now()
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

    /// Arms the production PTO wake. Idempotent.
    public func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(
            queue: .global(qos: .userInitiated))
        // The one-shot fired, so nothing is armed: clear the skip book
        // before re-arming, or an unchanged deadline would sleep forever.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.armedDeadlineMicros = nil
            self.serviceAndUnlock(now: self.now())
        }
        source.resume()
        timer = source
        // Service pre-start work (a bare re-arm could delay it a full PTO).
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

    /// Fires due PTO retransmits and re-arms.
    public func tick(now: ClientTimestamp) {
        lock.lock()
        serviceAndUnlock(now: now)
    }

    /// True when nothing is left to send, retransmit, or acknowledge.
    public var isQuiescent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return arq.isQuiescent
    }

    /// The endpoint's next PTO deadline, nil when none.
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

    /// Adopts a connection ID learned elsewhere (chan 8 borrows CTRL's so
    /// its first datagram is tagged). First writer wins; nil is a no-op.
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

    /// Polls, re-arms, and sends the output. Entered with `lock` held;
    /// returns with it released. Seal and `sendto` run outside `lock`;
    /// `transmitLock` is taken before `lock` is released, so batches leave
    /// in poll order.
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
                    // Refused sends stay armed on PTO and heal like loss.
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
        guard let timer else { return payloads }
        // Re-arm to the reported deadline unless the armed one is within
        // 1 ms (PTOs are 100 ms-scale).
        if let deadline {
            let target = deadline.microseconds
            let unchanged = armedDeadlineMicros.map {
                target >= $0 &- 1_000 && target <= $0 &+ 1_000
            } ?? false
            if !unchanged {
                let delta = max(deadline.microseconds(since: now), 1_000)
                timer.schedule(deadline: .now() + .microseconds(Int(delta)))
                armedDeadlineMicros = target
            }
        } else if armedDeadlineMicros != nil {
            timer.schedule(deadline: .distantFuture)
            armedDeadlineMicros = nil
        }
        return payloads
    }
}
