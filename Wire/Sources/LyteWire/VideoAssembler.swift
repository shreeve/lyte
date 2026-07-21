// VideoAssembler: the receive half of the W2 video interior, sans-IO.
// (envelope, payload) pairs in — any order, with loss, with duplicates —
// DecodeUnits out, in frame order, byte-identical to what the packetizer
// was handed. Core-owned per build plan §4.3: client CL-2 wires this
// module's output straight into the existing render path.
//
// The assembler never throws: a receiver cannot refuse the network.
// Malformed or inconsistent shards are dropped with a reported reason,
// and every decision the resiliency plan needs downstream (fec-impossible
// → CL-3's IDR request; NACK candidates → HS-17, emitted but unconsumed
// until H2 per §4.7) comes out of the same Event stream as the decoded
// frames. Integrity property (gate W-G3): under any injected fault the
// assembler emits correct bytes or nothing — recovered output that fails
// the Annex-B frame-shape check is suppressed, never delivered.
//
// Reorder/holdback policy, pinned here:
//   - DecodeUnits emit in strictly ascending frame order; a frame whose
//     turn has passed can never emit (its late shards drop as stale).
//   - A decoded frame waits for lower-numbered frames (tracked or not —
//     frame numbers are contiguous per channel, so a numbering gap is a
//     frame in flight or lost) until either `holdbackFrameCount` decoded
//     frames are being held, or the wait exceeds `staleAfterMicroseconds`
//     (per the injected clock). Both bounds skip the blockers with a
//     reported reason and move on — bounded latency beats completeness.
//   - Undecoded groups older than `staleAfterMicroseconds` are evicted;
//     `maxTrackedGroups` caps state against hostile frame-number spray.
//
// Loss presumption is QUIC-shaped (resiliency §1.1 rule 2 / RFC 9002
// packet-threshold 3): the packetizer allocates each frame's seqs
// contiguously in shard-index order, so any one shard names every seq the
// group owns; a seq is presumed lost once the channel's highest seen seq
// is `reorderThresholdPackets` past it. Presumed-lost shards feed the
// NACK-candidate lists — no timer.
//
// The fec-impossible verdict uses its own, more conservative threshold
// (`fecImpossibleThresholdPackets`): a spurious NACK candidate costs one
// retransmit request that HS-17 RTT-gates anyway, but a spurious
// fec-impossible costs a CL-3 IDR request, and displacement-d reordering
// can fake seq distances up to 2d. At the G4 model's d ≤ 4 the default
// of 10 stays quiet; at 60 fps it still renders the verdict within a
// frame or two of follow-on traffic — immediate next to the stale
// window. Presumption is not truth either way: the group stays tracked,
// and shards that arrive later anyway can still complete it.

public struct VideoAssemblerConfig: Hashable, Sendable {
    /// Decoded frames held for order before the oldest blocker is skipped.
    public var holdbackFrameCount: Int
    /// Age (injected clock) past which an undecoded group is evicted and
    /// past which a decoded frame stops waiting for its blockers.
    public var staleAfterMicroseconds: Int64
    /// Ceiling on simultaneously tracked groups.
    public var maxTrackedGroups: Int
    /// QUIC packet-threshold: a seq this far behind the channel's highest
    /// seen seq is presumed lost and becomes a NACK candidate.
    public var reorderThresholdPackets: Int
    /// The stricter distance the fec-impossible verdict requires before
    /// writing a shard off entirely (see the header comment).
    public var fecImpossibleThresholdPackets: Int

    public init(
        holdbackFrameCount: Int = 3,
        staleAfterMicroseconds: Int64 = 250_000,
        maxTrackedGroups: Int = 64,
        reorderThresholdPackets: Int = 3,
        fecImpossibleThresholdPackets: Int = 10
    ) {
        self.holdbackFrameCount = holdbackFrameCount
        self.staleAfterMicroseconds = staleAfterMicroseconds
        self.maxTrackedGroups = maxTrackedGroups
        self.reorderThresholdPackets = reorderThresholdPackets
        self.fecImpossibleThresholdPackets = fecImpossibleThresholdPackets
    }
}

/// Why an ingested shard was not used. Reported, never thrown.
public enum VideoShardDropReason: Hashable, Sendable {
    /// Not this assembler's channel — routing upstream misdelivered.
    case wrongChannel(ChannelId)
    /// The fec field failed to decode or names no RS shard.
    case malformedFecField
    /// Payload length disagrees with the geometry's wire length for the
    /// shard's index.
    case payloadLengthMismatch(shardIndex: UInt8, expected: Int, actual: Int)
    /// The frame's turn has passed (emitted or skipped), or the tracker
    /// is full and this frame is older than everything tracked.
    case staleFrame(FrameNumber)
    /// Same frame number, different geometry or seq base than the shard
    /// that opened the group — some sender bug, kept loud.
    case inconsistentGroup(FrameNumber)
    /// This shard index already arrived (duplicate datagram).
    case duplicateShard(FrameNumber, shardIndex: UInt8)
}

public enum VideoFrameSkipReason: Hashable, Sendable {
    /// `holdbackFrameCount` decoded frames were waiting behind this one.
    case holdbackExceeded
    /// The wait for this frame exceeded `staleAfterMicroseconds`.
    case staleGaveUp
    /// The frame recovered to bytes that failed the Annex-B frame-shape
    /// check — suppressed, never delivered (W-G3 integrity property).
    case corruptSuppressed
}

public enum VideoEvictionReason: Hashable, Sendable {
    /// Older than `staleAfterMicroseconds` without decoding.
    case stale
    /// `maxTrackedGroups` reached; the lowest-numbered group made room.
    case capacity
}

/// Per-frame status for callers that poll instead of consuming events.
public enum VideoFrameStatus: Hashable, Sendable {
    /// Shards still wanted; recovery still possible.
    case recoverablePending(receivedShards: Int, dataShards: Int, parityShards: Int)
    /// Decoded, waiting its turn in frame order.
    case complete
    /// Presumed losses exceed best-case parity — CL-3's IDR-request
    /// trigger. Still tracked; late arrivals may yet complete it.
    case fecImpossible
    /// Recovered bytes failed the frame-shape check; will be skipped.
    case corrupt
}

public enum VideoAssemblerEvent: Hashable, Sendable {
    /// A frame, byte-identical to the packetizer's input, in frame order.
    case decoded(DecodeUnit)
    /// Frames `from`…`through` (inclusive) will never emit; the reason
    /// applies to every frame in the range.
    case framesSkipped(from: FrameNumber, through: FrameNumber, reason: VideoFrameSkipReason)
    /// The group cannot recover from what is still plausibly in flight —
    /// emitted once per frame, the CL-3 IDR-request trigger.
    case fecImpossible(FrameNumber, presumedLostDataShards: Int, bestCaseParityShards: Int)
    /// Newly presumed-lost seqs whose retransmit would help this frame —
    /// §4.7's NACK-decision output, unconsumed until HS-17.
    case nackCandidates(FrameNumber, missingSeqs: [ChannelSeq])
    /// The group was dropped undecoded.
    case evicted(FrameNumber, reason: VideoEvictionReason)
    case shardDropped(VideoShardDropReason)
}

public struct VideoAssembler: Sendable {
    public let channel: ChannelId
    public let config: VideoAssemblerConfig

    private struct Group {
        var geometry: FecGeometry
        /// Seq of shard index 0, derived from any shard's (seq, index).
        var seqBase: ChannelSeq
        /// Host capture timestamp from the first-arrived shard.
        var timestampMicroseconds: UInt64
        var firstArrival: ClientTimestamp
        var slots: [[UInt8]?]
        var receivedCount = 0
        var decoded: DecodeUnit?
        var corrupt = false
        var fecImpossibleReported = false
        /// Seqs already emitted as NACK candidates.
        var nackReported: Set<UInt16> = []

        var isDecoded: Bool { decoded != nil }
    }

    private var groups: [UInt32: Group] = [:]
    private var lastEmitted: FrameNumber?
    private var highestSeq: ChannelSeq?

    public init(
        channel: ChannelId = .videoActive,
        config: VideoAssemblerConfig = VideoAssemblerConfig()
    ) {
        self.channel = channel
        self.config = config
    }

    /// The poll-side view of one frame; nil when untracked (never seen,
    /// already emitted, or already skipped/evicted).
    public func status(of frame: FrameNumber) -> VideoFrameStatus? {
        guard let group = groups[frame.rawValue] else { return nil }
        if group.corrupt { return .corrupt }
        if group.isDecoded { return .complete }
        if group.fecImpossibleReported { return .fecImpossible }
        return .recoverablePending(
            receivedShards: group.receivedCount,
            dataShards: group.geometry.dataShards,
            parityShards: group.geometry.parityShards
        )
    }

    /// Ingests one received datagram's (envelope, payload) and returns
    /// every event it caused, decoded frames included, in order. `now` is
    /// the receiver's clock (sans-IO rule: time is injected).
    public mutating func ingest(
        envelope: Envelope,
        payload: ArraySlice<UInt8>,
        now: ClientTimestamp
    ) -> [VideoAssemblerEvent] {
        guard envelope.channel == channel else {
            return [.shardDropped(.wrongChannel(envelope.channel))]
        }
        guard
            let field = try? FecField.decode(envelope.fec),
            case .reedSolomon(let shardIndex, let geometry) = field
        else {
            return [.shardDropped(.malformedFecField)]
        }
        let expected = geometry.wireByteCount(ofShard: Int(shardIndex))
        guard payload.count == expected else {
            return [.shardDropped(.payloadLengthMismatch(
                shardIndex: shardIndex, expected: expected, actual: payload.count
            ))]
        }

        let frame = envelope.frame
        if let last = lastEmitted, frame <= last, groups[frame.rawValue] == nil {
            return [.shardDropped(.staleFrame(frame))]
        }

        var events: [VideoAssemblerEvent] = []
        let seqBase = envelope.seq.advanced(by: Int16(-Int(shardIndex)))

        // Insert the shard (or report why not). Redundant shards for an
        // already-decoded group and exact duplicates report as duplicates
        // but still advance loss presumption below — they are honest
        // signal about what the network delivered.
        if var group = groups[frame.rawValue] {
            guard group.geometry == geometry, group.seqBase == seqBase else {
                return events + [.shardDropped(.inconsistentGroup(frame))]
            }
            if group.isDecoded || group.slots[Int(shardIndex)] != nil {
                events.append(.shardDropped(
                    .duplicateShard(frame, shardIndex: shardIndex)
                ))
            } else {
                group.slots[Int(shardIndex)] = Array(payload)
                group.receivedCount += 1
                attemptDecode(&group, frame: frame)
                groups[frame.rawValue] = group
            }
        } else {
            if let capacityEvents = makeRoom(for: frame, into: &events) {
                return capacityEvents
            }
            var group = Group(
                geometry: geometry,
                seqBase: seqBase,
                timestampMicroseconds: envelope.timestamp,
                firstArrival: now,
                slots: Array(repeating: nil, count: geometry.totalShards)
            )
            group.slots[Int(shardIndex)] = Array(payload)
            group.receivedCount = 1
            attemptDecode(&group, frame: frame)
            groups[frame.rawValue] = group
        }

        if highestSeq == nil || highestSeq! < envelope.seq {
            highestSeq = envelope.seq
        }

        sweepLossPresumption(into: &events)
        evict(now: now, into: &events)
        drain(now: now, into: &events)
        return events
    }

    public mutating func ingest(
        envelope: Envelope, payload: [UInt8], now: ClientTimestamp
    ) -> [VideoAssemblerEvent] {
        ingest(envelope: envelope, payload: payload[...], now: now)
    }

    /// Time-only tick: stale-group eviction and holdback expiry with no
    /// new datagram — the receive loop calls this on its timer.
    public mutating func evictStale(now: ClientTimestamp) -> [VideoAssemblerEvent] {
        var events: [VideoAssemblerEvent] = []
        evict(now: now, into: &events)
        drain(now: now, into: &events)
        return events
    }

    // MARK: - Interior

    /// Frees a slot when the tracker is full. Returns the terminal event
    /// list when the incoming frame itself is the one to reject.
    private mutating func makeRoom(
        for frame: FrameNumber, into events: inout [VideoAssemblerEvent]
    ) -> [VideoAssemblerEvent]? {
        guard groups.count >= config.maxTrackedGroups else { return nil }
        let lowest = groups.keys.min()!
        guard frame.rawValue > lowest else {
            return events + [.shardDropped(.staleFrame(frame))]
        }
        groups.removeValue(forKey: lowest)
        events.append(.evicted(
            FrameNumber(rawValue: lowest), reason: .capacity
        ))
        return nil
    }

    private func attemptDecode(_ group: inout Group, frame: FrameNumber) {
        guard !group.isDecoded, !group.corrupt else { return }
        let k = group.geometry.dataShards
        let missingData = group.slots[..<k].count(where: { $0 == nil })
        let presentParity = group.slots[k...].count(where: { $0 != nil })
        guard missingData <= presentParity else { return }
        guard let bytes = try? FecDecoder.decode(
            shards: group.slots, geometry: group.geometry
        ) else { return }

        guard AnnexBCheck.isFrameShaped(bytes) else {
            group.corrupt = true
            return
        }
        group.decoded = DecodeUnit(
            frameNumber: frame,
            timestamp: HostTimestamp(microseconds: group.timestampMicroseconds),
            isIDR: AnnexBCheck.containsIrap(bytes),
            annexB: bytes
        )
        // Recovery math is done; the shard bytes are dead weight now.
        group.slots = []
    }

    /// QUIC packet-threshold loss presumption across every open group:
    /// new presumed-lost seqs become NACK candidates, and a group whose
    /// presumed losses exceed best-case parity reports fec-impossible.
    private mutating func sweepLossPresumption(
        into events: inout [VideoAssemblerEvent]
    ) {
        guard let highest = highestSeq else { return }
        for key in groups.keys.sorted() {
            var group = groups[key]!
            guard !group.isDecoded, !group.corrupt else { continue }

            let k = group.geometry.dataShards
            var newCandidates: [ChannelSeq] = []
            var presumedLostData = 0
            var bestCaseParity = 0
            for index in 0..<group.geometry.totalShards {
                let present = group.slots[index] != nil
                let seq = group.seqBase.advanced(by: Int16(index))
                let distance = Int(seq.distance(to: highest))
                let nackWorthy = !present
                    && distance >= config.reorderThresholdPackets
                let writtenOff = !present
                    && distance >= config.fecImpossibleThresholdPackets
                if index < k {
                    if writtenOff { presumedLostData += 1 }
                } else if !writtenOff {
                    bestCaseParity += 1
                }
                if nackWorthy, !group.nackReported.contains(seq.rawValue) {
                    group.nackReported.insert(seq.rawValue)
                    newCandidates.append(seq)
                }
            }

            if !newCandidates.isEmpty {
                events.append(.nackCandidates(
                    FrameNumber(rawValue: key), missingSeqs: newCandidates
                ))
            }
            if presumedLostData > bestCaseParity, !group.fecImpossibleReported {
                group.fecImpossibleReported = true
                events.append(.fecImpossible(
                    FrameNumber(rawValue: key),
                    presumedLostDataShards: presumedLostData,
                    bestCaseParityShards: bestCaseParity
                ))
            }
            groups[key] = group
        }
    }

    private mutating func evict(
        now: ClientTimestamp, into events: inout [VideoAssemblerEvent]
    ) {
        for key in groups.keys.sorted() {
            let group = groups[key]!
            guard !group.isDecoded else { continue }
            if now.microseconds(since: group.firstArrival)
                >= config.staleAfterMicroseconds {
                groups.removeValue(forKey: key)
                events.append(.evicted(FrameNumber(rawValue: key), reason: .stale))
            }
        }
    }

    /// The ordered-emission loop implementing the holdback policy in the
    /// header comment. Every pass either emits, skips, or stops.
    private mutating func drain(
        now: ClientTimestamp, into events: inout [VideoAssemblerEvent]
    ) {
        while true {
            guard let lowestTracked = groups.keys.min() else { return }
            let awaited = lastEmitted.map(\.next)
                ?? FrameNumber(rawValue: lowestTracked)

            if let group = groups[awaited.rawValue] {
                if let unit = group.decoded {
                    groups.removeValue(forKey: awaited.rawValue)
                    lastEmitted = awaited
                    events.append(.decoded(unit))
                    continue
                }
                if group.corrupt {
                    groups.removeValue(forKey: awaited.rawValue)
                    lastEmitted = awaited
                    events.append(.framesSkipped(
                        from: awaited, through: awaited, reason: .corruptSuppressed
                    ))
                    continue
                }
                if let reason = holdbackExpiry(now: now) {
                    groups.removeValue(forKey: awaited.rawValue)
                    lastEmitted = awaited
                    events.append(.framesSkipped(
                        from: awaited, through: awaited, reason: reason
                    ))
                    continue
                }
                return
            }

            // The awaited frame is a numbering gap: nothing tracked
            // between `awaited` and the lowest tracked frame. Wait for it
            // within the holdback bounds, then skip the whole gap at once.
            guard awaited.rawValue < lowestTracked else {
                // lastEmitted has passed everything tracked (wrap-around
                // corner); nothing to order against.
                return
            }
            guard let reason = holdbackExpiry(now: now) else { return }
            events.append(.framesSkipped(
                from: awaited,
                through: FrameNumber(rawValue: lowestTracked - 1),
                reason: reason
            ))
            lastEmitted = FrameNumber(rawValue: lowestTracked - 1)
        }
    }

    /// Whether the frames blocking emission have exhausted their welcome:
    /// too many decoded frames held, or the oldest held one waited past
    /// the stale window. Nil while waiting is still the right call.
    private func holdbackExpiry(now: ClientTimestamp) -> VideoFrameSkipReason? {
        var heldCount = 0
        var oldestHeldArrival: ClientTimestamp?
        for group in groups.values where group.isDecoded {
            heldCount += 1
            if oldestHeldArrival == nil || group.firstArrival < oldestHeldArrival! {
                oldestHeldArrival = group.firstArrival
            }
        }
        guard heldCount > 0 else { return nil }
        if heldCount >= config.holdbackFrameCount { return .holdbackExceeded }
        if let oldest = oldestHeldArrival,
           now.microseconds(since: oldest) >= config.staleAfterMicroseconds {
            return .staleGaveUp
        }
        return nil
    }
}
