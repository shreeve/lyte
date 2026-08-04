// ArqEndpoint (W3): the sans-IO reliable ordered-retransmit sublayer —
// the "few-hundred-line sublayer, not a transport stack" the Lyte-UDP
// decision priced in (§4). One endpoint instance owns one reliable
// channel in both directions: it segments outbound messages, tracks and
// retransmits until acknowledged, deduplicates and reorders inbound
// segments, and delivers each message exactly once, in order, per group.
//
// Consumer shapes (core plan §2):
//   - group 0, the ordered stream: CTRL messages, feature channels —
//     an unbounded in-order message sequence.
//   - one-shot groups (non-zero id, ascending): exactly one message
//     each, retransmitting independently — a fully-lost sparse idle
//     frame never delays the next one (decision record §8.1).
//
// API shape, exactly the plan's: `send(message:group:now:)`,
// `ingest(payload:now:) -> [ArqEvent]`, `poll(now:) -> (datagrams,
// nextTimerDeadline)`. Sans-IO is a rule, not a style: time is the
// injected `now`, datagram payloads come out of `poll` for the shell to
// wrap in envelopes (fresh channel seq each — see ArqFrames.swift on
// why retransmits ride fresh datagrams) and seal; nothing here touches
// sockets, threads, or clocks. The generic clock domain makes a
// host-clock endpoint and a client-clock endpoint different types, so
// a domain mix is a compile error (the WireTimestamp doctrine).
//
// Loss recovery is RFC 9002-shaped, per resiliency §1.3 — RTT-adaptive,
// never fixed-interval:
//   - SRTT/RTTVAR from ACKs of segments sent exactly once (Karn), PTO =
//     SRTT + max(4·RTTVAR, granularity), exponential backoff per group
//     while a group makes no progress, reset on progress.
//   - Fast retransmit at packet-threshold 3: a sent segment three
//     serially past the group's highest-ever acked seq retransmits
//     immediately — but only when an ACK ADVANCES that high mark, so a
//     replayed ACK can never re-trigger it (the W-G4c forgery/replay
//     bound: an attacker replaying captured ACKs buys at most the
//     retransmits fresh information would have bought).
//   - ACKs carry complete receive state (cumulative + bitmap), are sent
//     on every arrival (duplicates included, so a lost ACK is repaired
//     by the retransmit it failed to suppress), and are never
//     themselves acknowledged.
//
// Delivery invariants (gate W-G4): per group, delivered messages are
// exactly the sent messages, in order, each exactly once; groups never
// block each other; when everything is acknowledged and delivered both
// ways the endpoint goes quiescent — `poll` returns no datagrams and no
// deadline, forever, until new work arrives.

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
    /// Sent-unacknowledged segments allowed in flight per group; must
    /// not exceed the receive window.
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
    /// hostile endless message.
    public var maxMessageByteCount: Int
    /// Simultaneously open receive groups — protection against hostile
    /// group spray.
    public var maxActiveReceiveGroups: Int
    /// Closed one-shot receive groups remembered for late-retransmit
    /// dedupe and re-ACK.
    public var maxClosedGroupTombstones: Int
    /// Absolute lifetime for incomplete one-shot receive groups. This keeps
    /// a retransmitting abandoned sender from pinning the admission table.
    public var receiveGroupLifetimeMicroseconds: Int64
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
        self.initialSegmentSeq = initialSegmentSeq
        normalizeDatagramBudget()
    }

    /// Public fields stay mutable for the established configuration style.
    /// Normalize again when an endpoint takes ownership so a caller that
    /// changes the carrier ceiling after init cannot leave segment geometry
    /// larger than the datagram it must ride.
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
    /// A message grew past maxMessageByteCount; the group is poisoned
    /// (no delivery, no ACK) — hostile-peer territory.
    case messageOverBudget(ArqGroupId)
}

public enum ArqEvent: Hashable, Sendable {
    /// A whole message, exactly once, in order within its group.
    case message(group: ArqGroupId, bytes: [UInt8])
    /// Sender side: a one-shot group is fully acknowledged — the
    /// HS-11 "final frame landed, flip to IDLE" signal.
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
}

public struct ArqEndpoint<ClockDomain>: Sendable {
    public typealias Instant = WireTimestamp<ClockDomain>

    public let channel: ChannelId
    public let config: ArqConfig

    // MARK: Send-side state

    private struct OutSegment {
        /// The encoded frame, byte-identical on every (re)transmission.
        var frameBytes: [UInt8]
        var lastSentAt: Instant?
        var sendCount = 0
        /// Queued for (re)transmission at the next poll.
        var needsSend = true
        /// Fast retransmit fired since the last actual send.
        var fastRetransmitConsumed = false
    }

    private struct SendGroup {
        /// Unacknowledged segments by seq.
        var segments: [UInt16: OutSegment] = [:]
        /// Allocation order (serial order); compacted as acks remove.
        var order: [UInt16] = []
        var nextSeq: UInt16
        /// Serially highest seq any ACK ever reported received — the
        /// fast-retransmit gate.
        var highestAckedEver: UInt16?
        var backoffExponent = 0
        /// Live segments that have crossed the wire at least once.
        var sentSegmentCount = 0
        /// Most recent transmission instant in the group (the RFC 9002
        /// PTO base).
        var lastSendAt: Instant?
    }

    private var sendGroups: [UInt16: SendGroup] = [:]
    /// Serially highest one-shot group id ever sent — reuse guard, and
    /// the "plausibly completed" bound for late ACKs.
    private var highestOneShotSent: UInt16?
    private var srttMicroseconds: Int64?
    private var rttvarMicroseconds: Int64 = 0

    // MARK: Receive-side state

    private struct RecvGroup {
        /// Seq of the last in-order segment (initial − 1 when none).
        var cumulative: UInt16
        var buffered: [UInt16: (endOfMessage: Bool, body: [UInt8])] = [:]
        /// In-order bytes of the message being reassembled.
        var assembling: [UInt8] = []
        var poisoned = false
        var openedAt: Instant
    }

    private var recvGroups: [UInt16: RecvGroup] = [:]
    /// Closed one-shot groups: id → final cumulative, for re-ACK.
    private var closedRecvGroups: [UInt16: UInt16] = [:]
    private var closedRecvOrder: [UInt16] = []
    /// Groups owed an ACK at the next poll.
    private var ackNeeded: Set<UInt16> = []

    public init(channel: ChannelId, config: ArqConfig = ArqConfig()) {
        self.channel = channel
        var normalized = config
        normalized.normalizeDatagramBudget()
        self.config = normalized
    }

    /// True when nothing remains to send, retransmit, or acknowledge.
    /// A quiescent endpoint polls to ([], nil) forever (the W-G4
    /// termination property).
    public var isQuiescent: Bool {
        ackNeeded.isEmpty
            && sendGroups.values.allSatisfy { $0.segments.isEmpty }
    }

    /// Sent-but-unacknowledged plus queued segment count, all groups —
    /// the boundedness handle for the adversarial gates.
    public var outstandingSegmentCount: Int {
        sendGroups.values.reduce(0) { $0 + $1.segments.count }
    }

    // MARK: - Send

    /// Queues a message on the ordered stream (group 0). Delivery is
    /// exactly-once, in order with every other stream message.
    public mutating func send(message: [UInt8], now: Instant) throws {
        try enqueue(message: message, group: .orderedStream)
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
        var state = sendGroups[group.rawValue]
            ?? SendGroup(nextSeq: config.initialSegmentSeq)
        let bodyCeiling = config.maxSegmentBodyByteCount
        var offset = 0
        while offset < message.count {
            let end = min(offset + bodyCeiling, message.count)
            let segment = try ArqSegment(
                group: group,
                seq: ArqSegmentSeq(rawValue: state.nextSeq),
                endOfMessage: end == message.count,
                body: Array(message[offset..<end])
            )
            state.segments[state.nextSeq] = OutSegment(
                frameBytes: segment.encode()
            )
            state.order.append(state.nextSeq)
            state.nextSeq &+= 1
            offset = end
        }
        sendGroups[group.rawValue] = state
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

    private mutating func ingestSegment(
        _ segment: ArqSegment, now: Instant, into events: inout [ArqEvent]
    ) {
        let gid = segment.group.rawValue

        if closedRecvGroups[gid] != nil {
            ackNeeded.insert(gid)
            events.append(.ignored(
                .segmentOnClosedGroup(segment.group, segment.seq)
            ))
            return
        }

        var state: RecvGroup
        if let existing = recvGroups[gid] {
            state = existing
        } else {
            // The ordered stream (group 0) is permanent and always
            // admitted; the cap bounds one-shot group spray only — a
            // hostile peer must never starve CTRL itself.
            if segment.group.isOneShot {
                guard recvGroups.count < config.maxActiveReceiveGroups else {
                    events.append(.ignored(
                        .tooManyReceiveGroups(segment.group)
                    ))
                    return
                }
            }
            state = RecvGroup(
                cumulative: config.initialSegmentSeq &- 1,
                openedAt: now
            )
        }
        if state.poisoned {
            events.append(.ignored(.messageOverBudget(segment.group)))
            return
        }

        let distance = Int16(
            bitPattern: segment.seq.rawValue &- state.cumulative
        )
        if distance <= 0 {
            ackNeeded.insert(gid)
            events.append(.ignored(
                .duplicateSegment(segment.group, segment.seq)
            ))
            recvGroups[gid] = state
            return
        }
        guard Int(distance) <= config.receiveWindowSegments else {
            events.append(.ignored(
                .beyondReceiveWindow(segment.group, segment.seq)
            ))
            recvGroups[gid] = state
            return
        }
        if state.buffered[segment.seq.rawValue] != nil {
            ackNeeded.insert(gid)
            events.append(.ignored(
                .duplicateSegment(segment.group, segment.seq)
            ))
            recvGroups[gid] = state
            return
        }

        state.buffered[segment.seq.rawValue] =
            (segment.endOfMessage, segment.body)
        ackNeeded.insert(gid)

        // Drain the in-order run, delivering completed messages.
        var closed = false
        while let entry = state.buffered[state.cumulative &+ 1] {
            state.buffered.removeValue(forKey: state.cumulative &+ 1)
            state.cumulative &+= 1
            guard state.assembling.count + entry.body.count
                <= config.maxMessageByteCount
            else {
                state.poisoned = true
                state.assembling = []
                state.buffered = [:]
                events.append(.ignored(.messageOverBudget(segment.group)))
                break
            }
            state.assembling.append(contentsOf: entry.body)
            if entry.endOfMessage {
                events.append(.message(
                    group: segment.group, bytes: state.assembling
                ))
                state.assembling = []
                if segment.group.isOneShot {
                    closed = true
                    break
                }
            }
        }

        if closed {
            recvGroups.removeValue(forKey: gid)
            closedRecvGroups[gid] = state.cumulative
            closedRecvOrder.append(gid)
            if closedRecvOrder.count > config.maxClosedGroupTombstones {
                let evicted = closedRecvOrder.removeFirst()
                closedRecvGroups.removeValue(forKey: evicted)
            }
        } else {
            recvGroups[gid] = state
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
            guard var state = sendGroups[gid] else {
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

            // Forgery bound: nothing past the highest allocated seq may
            // be acknowledged. (highestReported is initial − 1 when the
            // block reports nothing; against lastAllocated that is a
            // non-positive distance only when nothing was allocated —
            // and a group exists only once something was.)
            let lastAllocated = state.nextSeq &- 1
            let claimHigh = block.highestReported.rawValue
            guard Int16(bitPattern: claimHigh &- lastAllocated) <= 0 else {
                events.append(.ignored(.ackForUnsentData(block.group)))
                continue
            }

            // Retire everything the block covers.
            var progressed = false
            let bitmapSeqs = Set(block.bitmapSeqs.map(\.rawValue))
            for seq in state.order where state.segments[seq] != nil {
                let covered =
                    Int16(bitPattern: block.cumulative.rawValue &- seq) >= 0
                    || bitmapSeqs.contains(seq)
                guard covered else { continue }
                let out = state.segments.removeValue(forKey: seq)!
                progressed = true
                if out.sendCount >= 1 {
                    state.sentSegmentCount -= 1
                }
                if out.sendCount == 1, let sentAt = out.lastSentAt {
                    sampleRtt(now.microseconds(since: sentAt))
                }
            }
            if progressed {
                state.backoffExponent = 0
                let live = state.segments
                state.order.removeAll { live[$0] == nil }
            }

            // Fast retransmit, gated on a NEW high mark (replay-proof).
            let advanced = state.highestAckedEver.map {
                Int16(bitPattern: claimHigh &- $0) > 0
            } ?? true
            if advanced {
                state.highestAckedEver = claimHigh
                for seq in state.order {
                    guard var out = state.segments[seq],
                          out.sendCount >= 1,
                          !out.needsSend,
                          !out.fastRetransmitConsumed,
                          Int16(bitPattern: claimHigh &- seq)
                              >= Int16(config.packetThreshold)
                    else { continue }
                    out.needsSend = true
                    out.fastRetransmitConsumed = true
                    state.segments[seq] = out
                }
            }

            if block.group.isOneShot, state.segments.isEmpty {
                sendGroups.removeValue(forKey: gid)
                events.append(.oneShotAcknowledged(block.group))
            } else {
                sendGroups[gid] = state
            }
        }
    }

    private mutating func sampleRtt(_ sampleMicroseconds: Int64) {
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

        var datagrams: [[UInt8]] = []
        var current: [UInt8] = []
        for frame in frames {
            if !current.isEmpty,
               current.count + frame.count
                   > config.maxDatagramPayloadByteCount {
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
        for gid in sendGroups.keys {
            var state = sendGroups[gid]!
            guard let deadline = groupDeadline(state),
                  deadline <= now
            else { continue }
            var probes = 0
            for seq in state.order {
                guard probes < config.ptoProbeSegments else { break }
                guard var out = state.segments[seq],
                      out.sendCount >= 1, !out.needsSend
                else { continue }
                out.needsSend = true
                state.segments[seq] = out
                probes += 1
            }
            if probes > 0 {
                state.backoffExponent = min(
                    state.backoffExponent + 1, config.maxPtoBackoffExponent
                )
                // Re-arm from now, not from the stale send instant, so
                // one expiry fires once.
                state.lastSendAt = now
            }
            sendGroups[gid] = state
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
                var bytes = [UInt8](
                    repeating: 0,
                    count: ArqBounds.maxAckBitmapByteCount
                )
                var highestBit = -1
                for seq in state.buffered.keys {
                    let distance = Int16(bitPattern: seq &- cumulative)
                    guard distance > 0,
                          Int(distance) <= config.receiveWindowSegments
                    else { continue }
                    let offset = Int(distance) - 1
                    bytes[offset / 8] |= 1 << (offset % 8)
                    highestBit = offset
                }
                if highestBit >= 0 {
                    bitmap = Array(bytes[0...(highestBit / 8)])
                }
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

    private mutating func appendSegmentFrames(
        now: Instant, into frames: inout [[UInt8]]
    ) {
        for gid in sendGroups.keys.sorted() {
            var state = sendGroups[gid]!
            var inFlight = state.sentSegmentCount
            var sentAny = false
            for seq in state.order {
                guard var out = state.segments[seq] else { continue }
                if out.needsSend {
                    let isFresh = out.sendCount == 0
                    if isFresh, inFlight >= config.sendWindowSegments {
                        continue
                    }
                    frames.append(out.frameBytes)
                    out.lastSentAt = now
                    out.sendCount += 1
                    out.needsSend = false
                    out.fastRetransmitConsumed = false
                    state.segments[seq] = out
                    if isFresh {
                        inFlight += 1
                        state.sentSegmentCount += 1
                    }
                    sentAny = true
                }
            }
            if sentAny {
                state.lastSendAt = now
            }
            sendGroups[gid] = state
        }
    }

    private func pto() -> Int64 {
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

    private func groupDeadline(_ state: SendGroup) -> Instant? {
        guard let lastSend = state.lastSendAt else { return nil }
        guard state.sentSegmentCount > 0 else { return nil }
        let interval = min(
            pto() << state.backoffExponent, config.maxPtoMicroseconds
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
            recvGroups.removeValue(forKey: gid)
            ackNeeded.remove(gid)
        }
    }

    private func nextDeadline() -> Instant? {
        var earliest: Instant?
        for state in sendGroups.values {
            guard let deadline = groupDeadline(state) else { continue }
            if earliest == nil || deadline < earliest! {
                earliest = deadline
            }
        }
        return earliest
    }
}
