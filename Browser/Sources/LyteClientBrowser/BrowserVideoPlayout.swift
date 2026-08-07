import LyteCore
import LyteWire

/// Sans-IO browser video organ for B-5: LyteWire `VideoAssembler` plus
/// LyteCore `VideoBeatConductor` / `BoundedRendererHandoff`. Page JS owns
/// WebCodecs decode and WebGPU present; this type never invents frames.
struct BrowserVideoPlayout {
    struct ScheduledFrame: Sendable {
        var frameNumber: UInt32
        var sourceCaptureMicroseconds: UInt64
        var mappedCaptureMicroseconds: UInt64
        var arrivalMicroseconds: UInt64
        var presentationMicroseconds: UInt64
        var cueMicroseconds: UInt64
        var pathDelayMicroseconds: UInt64
        var reserveMicroseconds: UInt64
        var latenessMicroseconds: UInt64
        var isRandomAccess: Bool
        var shouldPresent: Bool
        var shouldFlush: Bool
        var annexBByteCount: Int
    }

    private var assembler = VideoAssembler(
        channel: .videoActive,
        // Browser WT+WASM ingest is slower than native UDP; give groups
        // longer before stale eviction so paced corpus shards can finish.
        config: VideoAssemblerConfig(
            holdbackFrameCount: 6,
            staleAfterMicroseconds: 1_000_000
        )
    )
    private var conductor = VideoBeatConductor()
    private var handoff = BoundedRendererHandoff<UInt32>(
        // Browser proof presents after paced corpus shards land; use a
        // long deadline so expire() during tick does not discard parts
        // before WebCodecs runs (native keep ~cue-scale deadlines).
        config: .init(capacity: 12, deadlineMicroseconds: UInt64.max / 4)
    )
    private var flushBarrier = RendererRecoveryFlushBarrier()

    /// Relative score map: first assembled frame anchors host capture to
    /// client arrival so Conductor path delay is meaningful without a
    /// full HostClockModel (beacon skew fit stays a later organ).
    private var scoreZero: UInt64?
    private var clientZero: UInt64?

    private var annexBByFrame: [UInt32: [UInt8]] = [:]
    private var scheduledByFrame: [UInt32: ScheduledFrame] = [:]
    private var assembledCount: UInt64 = 0
    private var scheduledCount: UInt64 = 0
    private var presentedCount: UInt64 = 0
    private var skippedLateCount: UInt64 = 0
    private var recoveryRequests: UInt64 = 0

    var framesAssembled: UInt64 { assembledCount }
    var framesScheduled: UInt64 { scheduledCount }
    var framesPresented: UInt64 { presentedCount }
    var framesSkippedLate: UInt64 { skippedLateCount }
    var handoffCount: Int { handoff.count }
    var awaitingRandomAccess: Bool { handoff.awaitingRandomAccess }

    mutating func reset() {
        assembler = VideoAssembler(
            channel: .videoActive,
            config: VideoAssemblerConfig(
                holdbackFrameCount: 6,
                staleAfterMicroseconds: 1_000_000
            )
        )
        conductor.reset()
        handoff = BoundedRendererHandoff<UInt32>(
            config: .init(capacity: 12, deadlineMicroseconds: UInt64.max / 4)
        )
        flushBarrier.reset()
        scoreZero = nil
        clientZero = nil
        annexBByFrame.removeAll(keepingCapacity: true)
        scheduledByFrame.removeAll(keepingCapacity: true)
        assembledCount = 0
        scheduledCount = 0
        presentedCount = 0
        skippedLateCount = 0
        recoveryRequests = 0
    }

    /// Unsealed video shard → assembler → Conductor schedule → handoff.
    mutating func ingestShard(
        envelope: Envelope,
        payload: ArraySlice<UInt8>,
        arrivalMicroseconds: UInt64
    ) -> (events: [String], scheduled: [ScheduledFrame]) {
        var notes: [String] = []
        var newly: [ScheduledFrame] = []
        let events = assembler.ingest(
            envelope: envelope,
            payload: payload,
            now: ClientTimestamp(microseconds: arrivalMicroseconds)
        )
        for event in events {
            switch event {
            case .decoded(let unit):
                assembledCount &+= 1
                let scheduled = schedule(unit, arrival: arrivalMicroseconds)
                newly.append(scheduled)
                notes.append(
                    "video: assembled frame=\(scheduled.frameNumber) "
                        + "idr=\(scheduled.isRandomAccess ? 1 : 0) "
                        + "bytes=\(scheduled.annexBByteCount) "
                        + "pts=\(scheduled.presentationMicroseconds) "
                        + "cue=\(scheduled.cueMicroseconds) "
                        + "late=\(scheduled.latenessMicroseconds)"
                )
            case .framesSkipped(let from, let through, let reason):
                notes.append(
                    "video: skipped frames \(from.rawValue)…\(through.rawValue) "
                        + "(\(reason))"
                )
            case .fecImpossible(let frame, let lost, let parity):
                notes.append(
                    "video: fecImpossible frame=\(frame.rawValue) "
                        + "lostData=\(lost) parity=\(parity)"
                )
            case .shardDropped(let reason):
                notes.append("video: shardDropped (\(reason))")
            default:
                break
            }
        }
        return (notes, newly)
    }

    mutating func evictStale(nowMicros: UInt64) -> [String] {
        var notes: [String] = []
        let events = assembler.evictStale(
            now: ClientTimestamp(microseconds: nowMicros)
        )
        for event in events {
            if case .framesSkipped(let from, let through, let reason) = event {
                notes.append(
                    "video: stale-skip \(from.rawValue)…\(through.rawValue) "
                        + "(\(reason))"
                )
            }
        }
        let expired = handoff.expire(nowMicroseconds: nowMicros)
        if expired.recoveryRequested {
            recoveryRequests &+= 1
            notes.append("video: handoff expire → await IRAP")
            for entry in expired.discarded {
                annexBByFrame.removeValue(forKey: entry.element)
                scheduledByFrame.removeValue(forKey: entry.element)
            }
        }
        return notes
    }

    func annexB(frameNumber: UInt32) -> [UInt8]? {
        annexBByFrame[frameNumber]
    }

    func scheduled(frameNumber: UInt32) -> ScheduledFrame? {
        scheduledByFrame[frameNumber]
    }

    /// Pop the next handoff entry whose Conductor beat is due. Late parts
    /// (lateness > 0 at schedule) are never shown — decode-only for chain.
    mutating func popDue(nowMicros: UInt64) -> ScheduledFrame? {
        guard flushBarrier.mayEnqueue else { return nil }
        if let early = pendingEarly {
            if nowMicros >= early.presentationMicroseconds {
                pendingEarly = nil
                return early
            }
            return nil
        }
        while let entry = handoff.popReady() {
            guard let frame = scheduledByFrame[entry.element] else {
                continue
            }
            if !frame.shouldPresent {
                skippedLateCount &+= 1
                annexBByFrame.removeValue(forKey: frame.frameNumber)
                scheduledByFrame.removeValue(forKey: frame.frameNumber)
                if frame.isRandomAccess {
                    handoff.noteRandomAccessEnqueued()
                    conductor.noteRandomAccessEnqueued()
                }
                continue
            }
            if nowMicros < frame.presentationMicroseconds {
                // Not due yet — hold outside the queue (no unshift on policy).
                pendingEarly = frame
                return nil
            }
            return frame
        }
        return nil
    }

    private var pendingEarly: ScheduledFrame?

    mutating func notePresented(frameNumber: UInt32) {
        presentedCount &+= 1
        if let frame = scheduledByFrame[frameNumber], frame.isRandomAccess {
            handoff.noteRandomAccessEnqueued()
            conductor.noteRandomAccessEnqueued()
        }
        annexBByFrame.removeValue(forKey: frameNumber)
        scheduledByFrame.removeValue(forKey: frameNumber)
    }

    mutating func noteDropped(frameNumber: UInt32) {
        annexBByFrame.removeValue(forKey: frameNumber)
        scheduledByFrame.removeValue(forKey: frameNumber)
    }

    // MARK: Interior

    private mutating func schedule(
        _ unit: DecodeUnit, arrival: UInt64
    ) -> ScheduledFrame {
        let capture = unit.timestamp.microseconds
        if scoreZero == nil {
            scoreZero = capture
            clientZero = arrival
        }
        let mapped = clientZero! &+ (capture &- scoreZero!)
        let decision = conductor.schedule(
            mappedCaptureMicroseconds: mapped,
            arrivalMicroseconds: arrival,
            sourceCaptureMicroseconds: capture,
            isRandomAccess: unit.isIDR
        )
        let shouldPresent = decision.latenessMicroseconds == 0
        let frame = ScheduledFrame(
            frameNumber: unit.frameNumber.rawValue,
            sourceCaptureMicroseconds: capture,
            mappedCaptureMicroseconds: mapped,
            arrivalMicroseconds: arrival,
            presentationMicroseconds: decision.presentationMicroseconds,
            cueMicroseconds: decision.cueMicroseconds,
            pathDelayMicroseconds: decision.pathDelayMicroseconds,
            reserveMicroseconds: decision.reserveMicroseconds,
            latenessMicroseconds: decision.latenessMicroseconds,
            isRandomAccess: unit.isIDR,
            shouldPresent: shouldPresent,
            shouldFlush: decision.shouldFlush,
            annexBByteCount: unit.annexB.count
        )
        annexBByFrame[frame.frameNumber] = unit.annexB
        scheduledByFrame[frame.frameNumber] = frame
        scheduledCount &+= 1

        if decision.shouldFlush {
            let outcome = handoff.failEpisode()
            recoveryRequests &+= outcome.recoveryRequested ? 1 : 0
            for entry in outcome.discarded {
                annexBByFrame.removeValue(forKey: entry.element)
                scheduledByFrame.removeValue(forKey: entry.element)
            }
        }

        let outcome = handoff.offer(
            frame.frameNumber,
            frame: RendererFrameDescriptor(
                isRandomAccess: unit.isIDR,
                submittedMicroseconds: arrival
            )
        )
        if outcome.recoveryRequested {
            recoveryRequests &+= 1
        }
        for entry in outcome.discarded where entry.element != frame.frameNumber {
            annexBByFrame.removeValue(forKey: entry.element)
            scheduledByFrame.removeValue(forKey: entry.element)
        }
        if !outcome.accepted {
            // Keep annexB for decode-chain even when handoff rejects present.
            if !unit.isIDR {
                // Non-IRAP rejected during await — still decodeable if JS asks.
            }
        }
        return frame
    }
}
