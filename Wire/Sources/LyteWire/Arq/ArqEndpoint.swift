// ArqEndpoint: the sans-IO reliable ordered-retransmit sublayer. One
// endpoint owns one reliable channel in both directions: it segments
// outbound messages, retransmits until acknowledged, deduplicates and
// reorders inbound segments, and delivers each message exactly once, in
// order, per group. Group 0 is the ordered stream (CTRL, feature
// channels); each non-zero one-shot group (ascending ids) carries one
// message and retransmits independently, so a lost one-shot never delays
// the next.
//
// Time is the injected `now`; `poll` returns datagram payloads for the
// shell to wrap in envelopes (a fresh channel seq each — see
// ArqFrames.swift) and seal. The clock domain parameter makes host- and
// client-clock endpoints distinct types.
//
// Loss recovery is RFC 9002-shaped:
//   - SRTT/RTTVAR from ACKs of segments sent exactly once (Karn), PTO =
//     SRTT + max(4·RTTVAR, granularity), exponential backoff per group
//     while it makes no progress, reset on progress.
//   - Fast retransmit at packet-threshold 3 fires only when an ACK
//     ADVANCES the group's highest acked seq, so a replayed ACK buys no
//     retransmits that fresh information would not have bought.
//   - ACKs carry complete receive state (cumulative + bitmap), are sent
//     on every arrival (duplicates included, so a lost ACK is repaired
//     by the retransmit it failed to suppress), and are never
//     themselves acknowledged.
//
// Every ACK, retransmit and window decision walks at most one receive
// window. Per group, delivered messages are exactly the sent messages, in
// order, each once; groups never block each other; once everything is
// acknowledged both ways, `poll` returns no datagrams and no deadline
// until new work arrives.

public struct ArqConfig: Hashable, Sendable {
    /// RTT assumed before the first sample; first PTO is twice this
    /// (RFC 9002 §6.2.2's shape).
    public var initialRttMicroseconds: Int64
    /// Timer granularity floor for the 4·RTTVAR term.
    public var granularityMicroseconds: Int64
    /// PTO clamp, before backoff.
    public var minPtoMicroseconds: Int64
    /// PTO ceiling, after backoff — bounds retransmit rate under
    /// blackout and forged-ACK adversity alike.
    public var maxPtoMicroseconds: Int64
    /// Backoff doubling stops here (2^6 = 64× before the max clamp).
    public var maxPtoBackoffExponent: Int
    /// Segments retransmitted per PTO expiry (QUIC probes send up to 2
    /// so a lost probe does not cost a full extra PTO).
    public var ptoProbeSegments: Int
    /// RFC 9002 packet threshold for ACK-driven fast retransmit.
    public var packetThreshold: Int
    /// Sent-unacknowledged segments allowed in flight per group
    /// (clamped to the receive window). Independently, a fresh segment
    /// never goes out past `receiveWindowSegments` above the group's
    /// lowest unacknowledged seq, so a lost window head never makes an
    /// honest sender overrun the receiver.
    public var sendWindowSegments: Int
    /// Out-of-order segments buffered past a group's cumulative; capped
    /// by what an ACK bitmap can describe (256).
    public var receiveWindowSegments: Int
    /// Segment body size ceiling; capped by ArqBounds.
    public var maxSegmentBodyByteCount: Int
    /// Maximum encoded ARQ frame-sequence bytes in one emitted datagram.
    /// Defaults to the bare Lyte-UDP plaintext shard ceiling. Carriers that
    /// reserve envelope extensions inject their smaller ceiling here; the
    /// endpoint then segments and packs once, at the owning boundary.
    public var maxDatagramPayloadByteCount: Int
    /// Reassembled message ceiling — receiver protection against a
    /// hostile endless message. Not negotiated: both ends must share it,
    /// and wire v1 fixes 262,144.
    public var maxMessageByteCount: Int
    /// Simultaneously open receive groups — protection against hostile
    /// group spray.
    public var maxActiveReceiveGroups: Int
    /// Closed one-shot receive groups remembered exactly for late-
    /// retransmit dedupe and re-ACK. Past this many, closure is
    /// remembered as a serial watermark: a one-shot id at or behind the
    /// highest evicted id is treated as closed (re-ACKed, never
    /// delivered), which keeps delivery at-most-once in bounded memory.
    public var maxClosedGroupTombstones: Int
    /// Absolute lifetime for incomplete one-shot receive groups. This keeps
    /// a retransmitting abandoned sender from pinning the admission table.
    public var receiveGroupLifetimeMicroseconds: Int64
    /// Bytes held across all incomplete one-shot receive groups: buffered
    /// out-of-order segments plus partial messages. A one-shot segment
    /// that would cross it is refused unacknowledged — unless it
    /// completes its group's message, which releases bytes — so the
    /// sender retries once groups complete or expire. The ordered stream
    /// is never counted: its window and message ceiling bound it.
    public var maxOneShotReceiveByteCount: Int
    /// First segment seq of every group. Wire v1 pins 0; the knob
    /// exists so u16 wrap crossings are simulatable (both ends must
    /// agree, like every config here).
    public var initialSegmentSeq: UInt16

    public init(
        initialRttMicroseconds: Int64 = 100_000,
        granularityMicroseconds: Int64 = 1_000,
        minPtoMicroseconds: Int64 = 10_000,
        maxPtoMicroseconds: Int64 = 8_000_000,
        maxPtoBackoffExponent: Int = 6,
        ptoProbeSegments: Int = 2,
        packetThreshold: Int = 3,
        sendWindowSegments: Int = 128,
        receiveWindowSegments: Int = ArqBounds.maxReceiveWindowSegments,
        maxSegmentBodyByteCount: Int = ArqBounds.maxSegmentBodyByteCount,
        maxDatagramPayloadByteCount: Int =
            WireBudget.maxPlaintextShardByteCount,
        maxMessageByteCount: Int = 262_144,
        maxActiveReceiveGroups: Int = 64,
        maxClosedGroupTombstones: Int = 256,
        receiveGroupLifetimeMicroseconds: Int64 = 30_000_000,
        maxOneShotReceiveByteCount: Int = 1_048_576,
        initialSegmentSeq: UInt16 = 0
    ) {
        self.initialRttMicroseconds = initialRttMicroseconds
        self.granularityMicroseconds = granularityMicroseconds
        self.minPtoMicroseconds = minPtoMicroseconds
        self.maxPtoMicroseconds = maxPtoMicroseconds
        self.maxPtoBackoffExponent = maxPtoBackoffExponent
        self.ptoProbeSegments = ptoProbeSegments
        self.packetThreshold = packetThreshold
        let clampedReceiveWindow = min(
            receiveWindowSegments, ArqBounds.maxReceiveWindowSegments
        )
        self.sendWindowSegments = min(
            sendWindowSegments, clampedReceiveWindow
        )
        self.receiveWindowSegments = clampedReceiveWindow
        self.maxDatagramPayloadByteCount = maxDatagramPayloadByteCount
        self.maxSegmentBodyByteCount = maxSegmentBodyByteCount
        self.maxMessageByteCount = maxMessageByteCount
        self.maxActiveReceiveGroups = maxActiveReceiveGroups
        self.maxClosedGroupTombstones = maxClosedGroupTombstones
        self.receiveGroupLifetimeMicroseconds = max(
            receiveGroupLifetimeMicroseconds, 1
        )
        self.maxOneShotReceiveByteCount = maxOneShotReceiveByteCount
        self.initialSegmentSeq = initialSegmentSeq
        normalizeDatagramBudget()
    }

    /// Re-run when an endpoint takes ownership, so a carrier ceiling
    /// changed after init cannot leave segments larger than the datagram.
    fileprivate mutating func normalizeDatagramBudget() {
        maxDatagramPayloadByteCount = min(
            max(
                maxDatagramPayloadByteCount,
                ArqBounds.maxAckFrameByteCount
            ),
            WireBudget.maxPlaintextShardByteCount
        )
        maxSegmentBodyByteCount = max(
            1,
            min(
                maxSegmentBodyByteCount,
                maxDatagramPayloadByteCount
                    - ArqBounds.segmentHeaderByteCount
            )
        )
    }
}

/// Why ingested bytes were not (fully) used. Reported, never thrown —
/// a receiver cannot refuse the network. Some reasons are routine
/// protocol weather (duplicates, late segments for closed groups); the
/// shell decides what to log.
public enum ArqIgnoreReason: Hashable, Sendable {
    /// The payload failed ARQ frame parsing.
    case malformedPayload(ArqFrameError)
    /// An ACK block naming a channel this endpoint does not own.
    case foreignChannelAck(ChannelId)
    /// An ACK block for a group this endpoint never sent on (and that
    /// is not a plausibly-completed one-shot) — forgery-shaped.
    case ackForUnknownGroup(ArqGroupId)
    /// An ACK block claiming receipt of seqs never sent — forgery.
    case ackForUnsentData(ArqGroupId)
    /// A segment already received (retransmit crossing an ACK, or a
    /// network duplicate). Routine; triggers a re-ACK.
    case duplicateSegment(ArqGroupId, ArqSegmentSeq)
    /// A segment for an already-delivered one-shot group. Routine;
    /// triggers a re-ACK so the sender can finish.
    case segmentOnClosedGroup(ArqGroupId, ArqSegmentSeq)
    /// A segment past the receive window — an honest sender's window
    /// discipline makes this forgery- or bug-shaped.
    case beyondReceiveWindow(ArqGroupId, ArqSegmentSeq)
    /// A new group beyond maxActiveReceiveGroups — group spray.
    case tooManyReceiveGroups(ArqGroupId)
    /// A one-shot segment past maxOneShotReceiveByteCount; refused
    /// unacknowledged.
    case oneShotReceiveBudgetExhausted(ArqGroupId)
    /// A message grew past maxMessageByteCount and poisoned its group —
    /// hostile-peer or config-skew territory. The crossing segment is
    /// acknowledged (it arrived); nothing more of the group is delivered
    /// or acknowledged. A one-shot group is then reclaimed.
    case messageOverBudget(ArqGroupId)
    /// A segment on the poisoned ordered stream. The stream lost a
    /// message and can never deliver in order again, so this repeats for
    /// the endpoint's life; the shell should end the session
    /// (`isOrderedStreamPoisoned`).
    case orderedStreamPoisoned
}

public enum ArqEvent: Hashable, Sendable {
    /// A whole message, exactly once, in order within its group.
    case message(group: ArqGroupId, bytes: [UInt8])
    /// Sender side: a one-shot group is fully acknowledged.
    case oneShotAcknowledged(ArqGroupId)
    case ignored(ArqIgnoreReason)
}

/// Everything `send` can refuse.
public enum ArqSendError: Error, Equatable, Sendable {
    /// Empty messages are meaningless (every CTRL message starts with a
    /// type byte).
    case emptyMessage
    /// Over config.maxMessageByteCount.
    case messageOverBudget(Int)
    /// sendOneShot with group 0 — the stream is not a one-shot.
    case orderedStreamGroupId
    /// One-shot group ids must be fresh and serially ascending; reuse
    /// would collide with the receiver's dedupe state.
    case oneShotGroupNotAscending(ArqGroupId)
    /// The group already holds `ArqBounds.maxQueuedSegmentsPerGroup`
    /// unacknowledged segments — backpressure; retry after ACKs drain it.
    case queueFull
}

public struct ArqEndpoint<ClockDomain>: Sendable {
    public typealias Instant = WireTimestamp<ClockDomain>

    public let channel: ChannelId
    public let config: ArqConfig

    // MARK: Send-side state

    private struct OutSegment {
        /// The encoded frame, byte-identical on every (re)transmission.
        var frameBytes: [UInt8]
        var lastSentAt: Instant
        var sendCount = 1
        /// Queued for retransmission at the next poll.
        var needsSend = false
        /// Fast retransmit fired since the last actual send.
        var fastRetransmitConsumed = false
    }

    /// One group's send state. Seqs are allocated only when a segment
    /// first goes out, so every seq in the ring has crossed the wire and
    /// the ring spans at most `receiveWindowSegments` seqs — serial
    /// arithmetic inside it never wraps. Messages not yet on the wire
    /// wait whole in `queue` and are cut into segments at poll time.
    private struct SendGroup {
        /// slots[head + i] holds seq base + i; nil once acknowledged.
        var slots: [OutSegment?] = []
        var head = 0
        /// Lowest unacknowledged seq (== nextSeq when nothing is in flight).
        var base: UInt16
        var nextSeq: UInt16
        /// Live (sent, unacknowledged) segments in the ring.
        var inFlight = 0
        /// Whole messages awaiting their first transmission, and the
        /// byte offset already cut from the front one.
        var queue: [[UInt8]] = []
        var queueHead = 0
        var queueOffset = 0
        var queuedSegmentCount = 0
        /// Serially highest seq any ACK ever reported received — the
        /// fast-retransmit gate.
        var highestAckedEver: UInt16?
        var backoffExponent = 0
        /// Most recent transmission instant in the group (the RFC 9002
        /// PTO base).
        var lastSendAt: Instant?

        init(initialSeq: UInt16) {
            base = initialSeq
            nextSeq = initialSeq
        }

        var span: Int { Int(nextSeq &- base) }
        var hasQueuedMessages: Bool { queueHead < queue.count }
        var isDrained: Bool { inFlight == 0 && !hasQueuedMessages }
        var outstandingSegmentCount: Int { inFlight + queuedSegmentCount }

        mutating func enqueue(_ message: [UInt8], segmentCount: Int) {
            queue.append(message)
            queuedSegmentCount += segmentCount
        }

        mutating func cutSegment(
            group: ArqGroupId, bodyCeiling: Int, now: Instant
        ) -> [UInt8] {
            let message = queue[queueHead]
            let end = min(queueOffset + bodyCeiling, message.count)
            let endOfMessage = end == message.count
            // Group, 1…ceiling body bytes: the init cannot refuse.
            let frame = (try? ArqSegment(
                group: group,
                seq: ArqSegmentSeq(rawValue: nextSeq),
                endOfMessage: endOfMessage,
                body: Array(message[queueOffset..<end])
            ).encode()) ?? []
            if endOfMessage {
                queue[queueHead] = []
                queueHead += 1
                queueOffset = 0
                if queueHead >= 32, queueHead * 2 >= queue.count {
                    queue.removeFirst(queueHead)
                    queueHead = 0
                }
            } else {
                queueOffset = end
            }
            queuedSegmentCount -= 1
            slots.append(OutSegment(frameBytes: frame, lastSentAt: now))
            nextSeq &+= 1
            inFlight += 1
            return frame
        }

        /// Marks the live segment at ring offset `offset` acknowledged.
        /// Returns its send instant when it was sent exactly once (a
        /// Karn-clean RTT sample), nil otherwise.
        mutating func retire(
            offset: Int
        ) -> (retired: Bool, cleanSentAt: Instant?) {
            guard offset >= 0, offset < slots.count - head,
                  let out = slots[head + offset]
            else { return (false, nil) }
            slots[head + offset] = nil
            inFlight -= 1
            return (true, out.sendCount == 1 ? out.lastSentAt : nil)
        }

        /// Advances `base` past the acknowledged front of the ring.
        mutating func compactFront() {
            while head < slots.count, slots[head] == nil {
                head += 1
                base &+= 1
            }
            if head == slots.count {
                slots.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= slots.count {
                slots.removeFirst(head)
                head = 0
            }
        }
    }

    private var sendGroups: [UInt16: SendGroup] = [:]
    /// Serially highest one-shot group id ever sent — reuse guard, and
    /// the "plausibly completed" bound for late ACKs.
    private var highestOneShotSent: UInt16?
    private var rtt = RttEstimator()

    /// RFC 9002 smoothed RTT, from Karn-clean samples only.
    private struct RttEstimator {
        var srttMicroseconds: Int64?
        var rttvarMicroseconds: Int64 = 0

        mutating func sample(_ sampleMicroseconds: Int64) {
            let sample = max(sampleMicroseconds, 0)
            if let srtt = srttMicroseconds {
                let deviation = abs(srtt - sample)
                rttvarMicroseconds = (3 * rttvarMicroseconds + deviation) / 4
                srttMicroseconds = (7 * srtt + sample) / 8
            } else {
                srttMicroseconds = sample
                rttvarMicroseconds = sample / 2
            }
        }

        /// PTO = SRTT + max(4·RTTVAR, granularity), or twice the initial
        /// RTT before any sample; clamped to the configured band.
        func pto(_ config: ArqConfig) -> Int64 {
            let base: Int64
            if let srtt = srttMicroseconds {
                base = srtt + max(
                    4 * rttvarMicroseconds, config.granularityMicroseconds
                )
            } else {
                base = 2 * config.initialRttMicroseconds
            }
            return min(
                max(base, config.minPtoMicroseconds),
                config.maxPtoMicroseconds
            )
        }
    }

    // MARK: Receive-side state

    private struct RecvGroup {
        /// Seq of the last in-order segment (initial − 1 when none).
        var cumulative: UInt16
        /// Out-of-order segments past the cumulative, by seq.
        var buffered: [UInt16: (endOfMessage: Bool, body: [UInt8])] = [:]
        /// In-order bytes of the message being reassembled.
        var assembling: [UInt8] = []
        /// Body bytes in `buffered`.
        var bufferedByteCount = 0
        var poisoned = false
        var openedAt: Instant

        var heldByteCount: Int { bufferedByteCount + assembling.count }

        /// The canonical ACK bitmap: bit n set when `cumulative + 1 + n`
        /// is buffered, sized by the highest set bit. Walks offsets in
        /// serial order (every buffered seq sits inside the window) and
        /// stops once each buffered segment is found.
        var ackBitmap: [UInt8] {
            var bytes: [UInt8] = []
            var found = 0
            var offset = 0
            while found < buffered.count {
                let seq = cumulative &+ 1 &+ UInt16(truncatingIfNeeded: offset)
                if buffered[seq] != nil {
                    while bytes.count <= offset / 8 { bytes.append(0) }
                    bytes[offset / 8] |= 1 << (offset % 8)
                    found += 1
                }
                offset += 1
            }
            return bytes
        }
    }

    private enum SegmentVerdict {
        case duplicate
        case beyondWindow
        case poisoned
        case accepted(closed: Bool)
    }

    private var recvGroups: [UInt16: RecvGroup] = [:]
    /// Closed one-shot groups: id → final cumulative, for re-ACK.
    private var closedRecvGroups: [UInt16: UInt16] = [:]
    private var closedRecvOrder: [UInt16] = []
    private var closedRecvOrderHead = 0
    /// Serially highest one-shot id whose tombstone was evicted; ids at
    /// or behind it are closed (see `maxClosedGroupTombstones`).
    private var evictedThrough: UInt16?
    /// Groups owed an ACK at the next poll.
    private var ackNeeded: Set<UInt16> = []
    /// Sum of `heldByteCount` over open one-shot receive groups.
    private var oneShotHeldByteCount = 0

    public init(channel: ChannelId, config: ArqConfig = ArqConfig()) {
        self.channel = channel
        var normalized = config
        normalized.normalizeDatagramBudget()
        self.config = normalized
    }

    /// True when nothing remains to send, retransmit, or acknowledge.
    /// A quiescent endpoint polls to ([], nil) until new work arrives.
    public var isQuiescent: Bool {
        ackNeeded.isEmpty && sendGroups.values.allSatisfy(\.isDrained)
    }

    /// True once the ordered stream (group 0) has been poisoned by a
    /// message over `maxMessageByteCount`. Permanent: the stream can
    /// never again deliver in order, so the session should end.
    public var isOrderedStreamPoisoned: Bool {
        recvGroups[ArqGroupId.orderedStream.rawValue]?.poisoned ?? false
    }

    /// Sent-but-unacknowledged plus queued segment count, all groups.
    public var outstandingSegmentCount: Int {
        sendGroups.values.reduce(0) { $0 + $1.outstandingSegmentCount }
    }

    // MARK: - Send

    /// Queues a message on the ordered stream (group 0). Delivery is
    /// exactly-once, in order with every other stream message.
    public mutating func send(message: [UInt8], now: Instant) throws {
        try enqueue(message: message, group: .orderedStream)
    }

    /// The id `sendOneShot(message:now:)` allocates next: one past the
    /// highest one-shot sent, skipping 0 across the u16 wrap.
    public var nextOneShotGroup: ArqGroupId {
        guard let highest = highestOneShotSent else {
            return ArqGroupId(rawValue: 1)
        }
        let next = highest &+ 1
        return ArqGroupId(rawValue: next == 0 ? 1 : next)
    }

    /// Queues a one-shot group's single message under the next
    /// endpoint-allocated group id, which it returns.
    @discardableResult
    public mutating func sendOneShot(
        message: [UInt8], now: Instant
    ) throws -> ArqGroupId {
        let group = nextOneShotGroup
        try sendOneShot(message: message, group: group, now: now)
        return group
    }

    /// Queues a one-shot group's single message. Group ids are caller-
    /// allocated, non-zero, serially ascending per endpoint.
    public mutating func sendOneShot(
        message: [UInt8], group: ArqGroupId, now: Instant
    ) throws {
        guard group.isOneShot else {
            throw ArqSendError.orderedStreamGroupId
        }
        if let highest = highestOneShotSent {
            let distance = Int16(bitPattern: group.rawValue &- highest)
            guard distance > 0 else {
                throw ArqSendError.oneShotGroupNotAscending(group)
            }
        }
        try enqueue(message: message, group: group)
        highestOneShotSent = group.rawValue
    }

    private mutating func enqueue(
        message: [UInt8], group: ArqGroupId
    ) throws {
        guard !message.isEmpty else {
            throw ArqSendError.emptyMessage
        }
        guard message.count <= config.maxMessageByteCount else {
            throw ArqSendError.messageOverBudget(message.count)
        }
        let bodyCeiling = config.maxSegmentBodyByteCount
        let segmentCount = (message.count + bodyCeiling - 1) / bodyCeiling
        let outstanding = sendGroups[group.rawValue]?
            .outstandingSegmentCount ?? 0
        guard outstanding + segmentCount
            <= ArqBounds.maxQueuedSegmentsPerGroup
        else {
            throw ArqSendError.queueFull
        }
        sendGroups[group.rawValue, default: SendGroup(
            initialSeq: config.initialSegmentSeq
        )].enqueue(message, segmentCount: segmentCount)
    }

    // MARK: - Ingest

    /// Feeds one received reliable-channel datagram payload (the bytes
    /// after unseal). Returns every event it caused, in order. Call
    /// `poll` afterwards — ingest only updates state and flags.
    public mutating func ingest(
        payload: ArraySlice<UInt8>, now: Instant
    ) -> [ArqEvent] {
        let frames: [ArqFrame]
        do {
            frames = try ArqFrame.decodeAll(payload)
        } catch let error as ArqFrameError {
            return [.ignored(.malformedPayload(error))]
        } catch {
            return [.ignored(.malformedPayload(.truncatedFrame))]
        }
        reclaimAbandonedReceiveGroups(now: now)
        var events: [ArqEvent] = []
        for frame in frames {
            switch frame {
            case .segment(let segment):
                ingestSegment(segment, now: now, into: &events)
            case .ack(let ack):
                ingestAck(ack, now: now, into: &events)
            }
        }
        return events
    }

    public mutating func ingest(
        payload: [UInt8], now: Instant
    ) -> [ArqEvent] {
        ingest(payload: payload[...], now: now)
    }

    private func isClosedOneShot(_ group: ArqGroupId) -> Bool {
        let gid = group.rawValue
        if closedRecvGroups[gid] != nil { return true }
        guard group.isOneShot, recvGroups[gid] == nil,
              let evictedThrough
        else { return false }
        return Int16(bitPattern: gid &- evictedThrough) <= 0
    }

    private mutating func ingestSegment(
        _ segment: ArqSegment, now: Instant, into events: inout [ArqEvent]
    ) {
        let gid = segment.group.rawValue

        if isClosedOneShot(segment.group) {
            if closedRecvGroups[gid] == nil {
                // Evicted tombstone: the whole message was delivered, so
                // this segment and everything before it was received.
                rememberClosed(gid, cumulative: segment.seq.rawValue)
            }
            ackNeeded.insert(gid)
            events.append(.ignored(
                .segmentOnClosedGroup(segment.group, segment.seq)
            ))
            return
        }

        let isOneShot = segment.group.isOneShot
        if isOneShot, oneShotHeldByteCount + segment.body.count
            > config.maxOneShotReceiveByteCount,
           !(recvGroups[gid].map { Self.completesMessage(segment, in: $0) }
               ?? false) {
            events.append(.ignored(
                .oneShotReceiveBudgetExhausted(segment.group)
            ))
            return
        }
        if recvGroups[gid] == nil {
            // The ordered stream (group 0) is permanent and always
            // admitted; the cap bounds one-shot group spray only — a
            // hostile peer must never starve CTRL itself.
            if isOneShot,
               recvGroups.count >= config.maxActiveReceiveGroups {
                events.append(.ignored(.tooManyReceiveGroups(segment.group)))
                return
            }
            recvGroups[gid] = RecvGroup(
                cumulative: config.initialSegmentSeq &- 1, openedAt: now
            )
        }

        let heldBefore = recvGroups[gid]!.heldByteCount
        let verdict = Self.accept(
            segment, into: &recvGroups[gid]!, config: config, events: &events
        )
        if isOneShot {
            oneShotHeldByteCount += recvGroups[gid]!.heldByteCount - heldBefore
        }
        switch verdict {
        case .poisoned:
            events.append(.ignored(isOneShot
                ? .messageOverBudget(segment.group) : .orderedStreamPoisoned))
        case .beyondWindow:
            events.append(.ignored(
                .beyondReceiveWindow(segment.group, segment.seq)
            ))
        case .duplicate:
            ackNeeded.insert(gid)
            events.append(.ignored(
                .duplicateSegment(segment.group, segment.seq)
            ))
        case .accepted(let closed):
            ackNeeded.insert(gid)
            if closed {
                let cumulative = removeRecvGroup(gid).cumulative
                rememberClosed(gid, cumulative: cumulative)
            }
        }
    }

    /// Buffers one segment and drains the in-order run, appending each
    /// completed message. Mutates the group in place: reassembly never
    /// copies the partial message.
    private static func accept(
        _ segment: ArqSegment, into state: inout RecvGroup,
        config: ArqConfig, events: inout [ArqEvent]
    ) -> SegmentVerdict {
        if state.poisoned { return .poisoned }
        let seq = segment.seq.rawValue
        let distance = Int16(bitPattern: seq &- state.cumulative)
        if distance <= 0 { return .duplicate }
        guard Int(distance) <= config.receiveWindowSegments else {
            return .beyondWindow
        }
        if state.buffered[seq] != nil { return .duplicate }
        var next: (endOfMessage: Bool, body: [UInt8])?
        if distance == 1 {
            next = (segment.endOfMessage, segment.body)
        } else {
            state.buffered[seq] = (segment.endOfMessage, segment.body)
            state.bufferedByteCount += segment.body.count
        }

        while let entry = next {
            state.cumulative &+= 1
            guard state.assembling.count + entry.body.count
                <= config.maxMessageByteCount
            else {
                state.poisoned = true
                state.assembling = []
                state.buffered = [:]
                state.bufferedByteCount = 0
                events.append(.ignored(.messageOverBudget(segment.group)))
                return .accepted(closed: false)
            }
            state.assembling.append(contentsOf: entry.body)
            if entry.endOfMessage {
                events.append(.message(
                    group: segment.group, bytes: state.assembling
                ))
                state.assembling = []
                if segment.group.isOneShot {
                    return .accepted(closed: true)
                }
            }
            next = state.buffered.removeValue(forKey: state.cumulative &+ 1)
            state.bufferedByteCount -= next?.body.count ?? 0
        }
        return .accepted(closed: false)
    }

    /// True when `segment` is the group's next in-order segment and it,
    /// or the buffered run behind it, ends the message: accepting it
    /// releases the group's bytes instead of pinning more, so the budget
    /// never starves a group that is one segment from done.
    private static func completesMessage(
        _ segment: ArqSegment, in state: RecvGroup
    ) -> Bool {
        guard !state.poisoned,
              segment.seq.rawValue == state.cumulative &+ 1 else { return false }
        var seq = segment.seq.rawValue
        var endOfMessage = segment.endOfMessage
        while !endOfMessage {
            seq &+= 1
            guard let entry = state.buffered[seq] else { return false }
            endOfMessage = entry.endOfMessage
        }
        return true
    }

    /// Removes an open receive group, releasing its one-shot bytes.
    @discardableResult
    private mutating func removeRecvGroup(_ gid: UInt16) -> RecvGroup {
        let state = recvGroups.removeValue(forKey: gid)!
        if gid != ArqGroupId.orderedStream.rawValue {
            oneShotHeldByteCount -= state.heldByteCount
        }
        return state
    }

    private mutating func rememberClosed(_ gid: UInt16, cumulative: UInt16) {
        if let existing = closedRecvGroups[gid] {
            if Int16(bitPattern: cumulative &- existing) > 0 {
                closedRecvGroups[gid] = cumulative
            }
            return
        }
        closedRecvGroups[gid] = cumulative
        closedRecvOrder.append(gid)
        while closedRecvOrder.count - closedRecvOrderHead
            > config.maxClosedGroupTombstones {
            let evicted = closedRecvOrder[closedRecvOrderHead]
            closedRecvOrderHead += 1
            closedRecvGroups.removeValue(forKey: evicted)
            if evictedThrough.map({ Int16(bitPattern: evicted &- $0) > 0 })
                ?? true {
                evictedThrough = evicted
            }
        }
        if closedRecvOrderHead >= 64,
           closedRecvOrderHead * 2 >= closedRecvOrder.count {
            closedRecvOrder.removeFirst(closedRecvOrderHead)
            closedRecvOrderHead = 0
        }
    }

    private mutating func ingestAck(
        _ ack: ArqAck, now: Instant, into events: inout [ArqEvent]
    ) {
        for block in ack.blocks {
            guard block.channel == channel else {
                events.append(.ignored(.foreignChannelAck(block.channel)))
                continue
            }
            let gid = block.group.rawValue
            guard sendGroups[gid] != nil else {
                // A late duplicate ACK for a completed one-shot is
                // routine silence; anything else is forgery-shaped.
                let plausiblyCompleted = block.group.isOneShot
                    && highestOneShotSent.map {
                        Int16(bitPattern: gid &- $0) <= 0
                    } ?? false
                if !plausiblyCompleted {
                    events.append(.ignored(.ackForUnknownGroup(block.group)))
                }
                continue
            }
            guard Self.applyAck(
                block, to: &sendGroups[gid]!, rtt: &rtt, config: config,
                now: now
            ) else {
                events.append(.ignored(.ackForUnsentData(block.group)))
                continue
            }
            if block.group.isOneShot, sendGroups[gid]!.isDrained {
                sendGroups.removeValue(forKey: gid)
                events.append(.oneShotAcknowledged(block.group))
            }
        }
    }

    /// Retires everything one ACK block covers and runs the fast-
    /// retransmit gate. Returns false (touching nothing) for a block
    /// claiming seqs never sent — forgery.
    private static func applyAck(
        _ block: ArqAck.Block, to state: inout SendGroup,
        rtt: inout RttEstimator, config: ArqConfig, now: Instant
    ) -> Bool {
        // Forgery bound: nothing past the highest SENT seq may be
        // acknowledged. Offsets are measured from base, where the ring
        // (span ≤ receive window) holds every seq ever sent and not yet
        // retired: the cumulative is placed serially, and the highest
        // reported seq lies a bitmap's length (≤ 256) above it, unwrapped
        // — so a cumulative near half the serial space cannot carry the
        // bitmap around to "behind" the ring. A cumulative behind base is
        // a stale ACK, not a forgery. (highestReported is initial − 1
        // when the block reports nothing.)
        let cumulativeOffset = Int(
            Int16(bitPattern: block.cumulative.rawValue &- state.base))
        let claimHigh = block.highestReported.rawValue
        let highOffset = cumulativeOffset
            + Int(claimHigh &- block.cumulative.rawValue)
        guard highOffset < state.span else { return false }

        var progressed = false
        func retire(offset: Int) {
            let outcome = state.retire(offset: offset)
            guard outcome.retired else { return }
            progressed = true
            if let sentAt = outcome.cleanSentAt {
                rtt.sample(now.microseconds(since: sentAt))
            }
        }
        // Cumulative: every seq from base through the cumulative — at
        // most the ring's span, by the bound above.
        if cumulativeOffset >= 0 {
            for offset in 0...cumulativeOffset { retire(offset: offset) }
        }
        // Bitmap: seqs cumulative+1+n.
        for (byteOffset, byte) in block.receivedBitmap.enumerated()
        where byte != 0 {
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                retire(offset: cumulativeOffset + 1 + byteOffset * 8 + bit)
            }
        }
        let baseBefore = state.base
        if progressed {
            state.backoffExponent = 0
            state.compactFront()
        }

        // Fast retransmit, gated on a NEW high mark (replay-proof): every
        // live segment packetThreshold or more behind it goes again once.
        let advanced = state.highestAckedEver.map {
            Int16(bitPattern: claimHigh &- $0) > 0
        } ?? true
        if advanced {
            state.highestAckedEver = claimHigh
            // Still inside the ring: compaction moved base forward by
            // what it retired, never past the claim.
            let reach = highOffset - Int(state.base &- baseBefore)
                - config.packetThreshold
            if reach >= 0 {
                for index in state.head...(state.head + reach) {
                    guard var out = state.slots[index],
                          !out.needsSend, !out.fastRetransmitConsumed
                    else { continue }
                    out.needsSend = true
                    out.fastRetransmitConsumed = true
                    state.slots[index] = out
                }
            }
        }
        return true
    }

    // MARK: - Poll

    /// Advances timers and collects output. Returns datagram payloads
    /// packed directly within `config.maxDatagramPayloadByteCount`, ready
    /// for an envelope with a fresh channel seq, and the next instant `poll`
    /// must run again, nil when no timer is armed. Call after every
    /// ingest/send and at the returned deadline.
    public mutating func poll(
        now: Instant
    ) -> (datagrams: [[UInt8]], nextTimerDeadline: Instant?) {
        reclaimAbandonedReceiveGroups(now: now)
        firePtoTimers(now: now)

        var frames: [[UInt8]] = []
        appendAckFrames(into: &frames)
        appendSegmentFrames(now: now, into: &frames)

        // Pack frames in order, starting a new datagram whenever the
        // next frame would cross the ceiling.
        var datagrams: [[UInt8]] = []
        var current: [UInt8] = []
        for frame in frames {
            if !current.isEmpty,
               current.count + frame.count > config.maxDatagramPayloadByteCount {
                datagrams.append(current)
                current = []
            }
            current.append(contentsOf: frame)
        }
        if !current.isEmpty {
            datagrams.append(current)
        }
        return (datagrams, nextDeadline())
    }

    private mutating func firePtoTimers(now: Instant) {
        let pto = rtt.pto(config)
        var index = sendGroups.startIndex
        while index != sendGroups.endIndex {
            Self.firePto(
                &sendGroups.values[index], pto: pto, config: config, now: now
            )
            sendGroups.formIndex(after: &index)
        }
    }

    /// On an expired PTO, re-queues the first `ptoProbeSegments` live
    /// segments not already queued, and backs off.
    private static func firePto(
        _ state: inout SendGroup, pto: Int64, config: ArqConfig, now: Instant
    ) {
        guard let deadline = groupDeadline(state, pto: pto, config: config),
              deadline <= now
        else { return }
        var probes = 0
        var index = state.head
        while probes < config.ptoProbeSegments, index < state.slots.count {
            if let out = state.slots[index], !out.needsSend {
                state.slots[index]!.needsSend = true
                probes += 1
            }
            index += 1
        }
        if probes > 0 {
            state.backoffExponent = min(
                state.backoffExponent + 1, config.maxPtoBackoffExponent
            )
            // Re-arm from now, not from the stale send instant, so
            // one expiry fires once.
            state.lastSendAt = now
        }
    }

    private mutating func appendAckFrames(into frames: inout [[UInt8]]) {
        guard !ackNeeded.isEmpty else { return }
        var blocks: [ArqAck.Block] = []
        for gid in ackNeeded.sorted() {
            let cumulative: UInt16
            var bitmap = [UInt8]()
            if let closed = closedRecvGroups[gid] {
                cumulative = closed
            } else if let state = recvGroups[gid] {
                cumulative = state.cumulative
                bitmap = state.ackBitmap
            } else {
                continue
            }
            if let block = try? ArqAck.Block(
                channel: channel,
                group: ArqGroupId(rawValue: gid),
                cumulative: ArqSegmentSeq(rawValue: cumulative),
                receivedBitmap: bitmap
            ) {
                blocks.append(block)
            }
        }
        ackNeeded.removeAll()
        var start = 0
        while start < blocks.count {
            let end = min(start + ArqBounds.maxAckBlocks, blocks.count)
            if let ack = try? ArqAck(blocks: Array(blocks[start..<end])) {
                frames.append(ack.encode())
            }
            start = end
        }
    }

    /// Per group in id order: queued retransmits in serial order, then
    /// fresh segments while both windows allow — at most
    /// `sendWindowSegments` in flight, and never past
    /// `receiveWindowSegments` above the lowest unacknowledged seq.
    private mutating func appendSegmentFrames(
        now: Instant, into frames: inout [[UInt8]]
    ) {
        for gid in sendGroups.keys.sorted() {
            Self.emitSegments(
                of: &sendGroups[gid]!, group: ArqGroupId(rawValue: gid),
                config: config, now: now, into: &frames
            )
        }
    }

    private static func emitSegments(
        of state: inout SendGroup, group: ArqGroupId, config: ArqConfig,
        now: Instant, into frames: inout [[UInt8]]
    ) {
        var sentAny = false
        for index in state.head..<state.slots.count {
            guard var out = state.slots[index], out.needsSend else { continue }
            frames.append(out.frameBytes)
            out.lastSentAt = now
            out.sendCount += 1
            out.needsSend = false
            out.fastRetransmitConsumed = false
            state.slots[index] = out
            sentAny = true
        }
        while state.hasQueuedMessages,
              state.inFlight < config.sendWindowSegments,
              state.span < config.receiveWindowSegments {
            frames.append(state.cutSegment(
                group: group, bodyCeiling: config.maxSegmentBodyByteCount,
                now: now
            ))
            sentAny = true
        }
        if sentAny {
            state.lastSendAt = now
        }
    }

    private static func groupDeadline(
        _ state: SendGroup, pto: Int64, config: ArqConfig
    ) -> Instant? {
        guard let lastSend = state.lastSendAt, state.inFlight > 0 else {
            return nil
        }
        let interval = min(
            pto << state.backoffExponent, config.maxPtoMicroseconds
        )
        return lastSend.advanced(byMicroseconds: interval)
    }

    private mutating func reclaimAbandonedReceiveGroups(now: Instant) {
        let lifetime = config.receiveGroupLifetimeMicroseconds
        let abandoned = recvGroups.compactMap { gid, state -> UInt16? in
            guard gid != ArqGroupId.orderedStream.rawValue else { return nil }
            return state.poisoned
                || now.microseconds(since: state.openedAt) >= lifetime
                ? gid : nil
        }
        for gid in abandoned {
            removeRecvGroup(gid)
            ackNeeded.remove(gid)
        }
    }

    private func nextDeadline() -> Instant? {
        let pto = rtt.pto(config)
        return sendGroups.values
            .compactMap { Self.groupDeadline($0, pto: pto, config: config) }
            .min()
    }
}
