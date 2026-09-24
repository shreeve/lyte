import LyteClientSession
import LyteCore
import LyteWire

/// Sans-IO browser video organ: `VideoAssembler` + `VideoBeatConductor` +
/// `BoundedRendererHandoff`. Page JS owns WebCodecs decode and WebGPU
/// present. Every assembled frame's Annex-B waits in the decode backlog
/// until the page takes it (decode order is the only order a P-frame chain
/// allows); presentation metadata lives only while the handoff holds the
/// frame. Rejected or late frames are still decoded but never presented.
public struct BrowserVideoPlayout {
    public struct ScheduledFrame: Sendable, Equatable {
        public var frameNumber: UInt32
        public var sourceCaptureMicroseconds: UInt64
        public var arrivalMicroseconds: UInt64
        public var presentationMicroseconds: UInt64
        public var cueMicroseconds: UInt64
        public var pathDelayMicroseconds: UInt64
        public var reserveMicroseconds: UInt64
        public var latenessMicroseconds: UInt64
        public var isRandomAccess: Bool
        public var shouldPresent: Bool
        public var annexBByteCount: Int
    }

    public struct Counters: Sendable, Equatable {
        public var framesAssembled: UInt64 = 0
        public var framesPresented: UInt64 = 0
        public var framesSkippedLate: UInt64 = 0
        /// Frames the handoff refused or discarded (decoded, not presented).
        public var framesNotPresentable: UInt64 = 0
        /// Annex-B evicted because the page stopped taking decode input.
        public var decodeBacklogEvicted: UInt64 = 0
        public var fecImpossible: UInt64 = 0
        /// Shards the assembler dropped (mostly late FEC surplus).
        public var shardsDropped: UInt64 = 0

        public init() {}
    }

    /// Undrained decode input is bounded: about two seconds at 60 fps.
    public static let decodeBacklogCapacity = 120

    private var assembler = VideoAssembler(
        channel: .videoActive,
        // WT + WASM ingest is slower than native UDP; groups get longer
        // before stale eviction so paced shards can finish.
        config: VideoAssemblerConfig(
            holdbackFrameCount: 6,
            staleAfterMicroseconds: 1_000_000
        )
    )
    private var conductor = VideoBeatConductor()
    private var handoff = BoundedRendererHandoff<UInt32>(
        // The page decodes asynchronously; a long deadline keeps expire()
        // from discarding frames before WebCodecs has run.
        config: .init(capacity: 12, deadlineMicroseconds: UInt64.max / 4)
    )

    /// Until the host clock has its first sample, the first assembled
    /// frame anchors host capture to client arrival.
    private var anchor: (capture: UInt64, arrival: UInt64)?

    private var annexBByFrame: [UInt32: [UInt8]] = [:]
    /// Frame numbers in decode order; entries already taken are skipped
    /// when they reach the front.
    private var decodeOrder = Deque<UInt32>()
    private var scheduledByFrame: [UInt32: ScheduledFrame] = [:]
    private var pendingEarly: ScheduledFrame?
    public private(set) var counters = Counters()

    /// The IDR-request episode, the native requester's policy.
    private var recovery = ClientIdrRecovery()

    public init() {}

    public var framesAssembled: UInt64 { counters.framesAssembled }
    public var framesPresented: UInt64 { counters.framesPresented }
    /// Frames whose Annex-B is still waiting for the page to take it.
    public var decodeBacklogCount: Int { annexBByFrame.count }
    /// Frames whose presentation metadata is still held.
    public var presentationBacklogCount: Int {
        scheduledByFrame.count
    }
    public var recoveryOutstanding: Bool { recovery.isOutstanding }

    /// Unsealed video shard → assembler → Conductor schedule → handoff.
    /// Capture times map to the client clock through `hostClock`.
    public mutating func ingestShard(
        envelope: Envelope,
        payload: ArraySlice<UInt8>,
        arrivalMicroseconds: UInt64,
        hostClock: ClientHostClock.Estimate? = nil
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
                counters.framesAssembled &+= 1
                newly.append(schedule(
                    unit, arrival: arrivalMicroseconds, hostClock: hostClock))
            case .framesSkipped(let from, let through, let reason):
                notes.append(
                    "video: skipped frames \(from.rawValue)…\(through.rawValue) (\(reason))"
                )
                demandRecovery(frame: through.rawValue)
            case .fecImpossible(let frame, let lost, let parity):
                counters.fecImpossible &+= 1
                notes.append(
                    "video: fecImpossible frame=\(frame.rawValue) lostData=\(lost) parity=\(parity)"
                )
                demandRecovery(frame: frame.rawValue)
            case .shardDropped:
                // Routine: FEC surplus arriving after its frame completed.
                counters.shardsDropped &+= 1
            default:
                break
            }
        }
        return (notes, newly)
    }

    public mutating func evictStale(nowMicros: UInt64) -> [String] {
        var notes: [String] = []
        for event in assembler.evictStale(now: ClientTimestamp(microseconds: nowMicros)) {
            if case .framesSkipped(let from, let through, let reason) = event {
                notes.append(
                    "video: stale-skip \(from.rawValue)…\(through.rawValue) (\(reason))"
                )
                demandRecovery(frame: through.rawValue)
            }
        }
        let expired = handoff.expire(nowMicroseconds: nowMicros)
        if expired.recoveryRequested {
            notes.append("video: handoff expire → await IRAP")
        }
        absorb(expired)
        return notes
    }

    /// Hands out an assembled frame's Annex-B exactly once, for decode.
    public mutating func takeAnnexB(frameNumber: UInt32) -> [UInt8]? {
        annexBByFrame.removeValue(forKey: frameNumber)
    }

    /// Pops the next handoff entry whose Conductor beat is due. Frames late
    /// at schedule time are never shown (the page still decodes them for
    /// the chain).
    public mutating func popDue(nowMicros: UInt64) -> ScheduledFrame? {
        if let early = pendingEarly {
            guard nowMicros >= early.presentationMicroseconds else { return nil }
            pendingEarly = nil
            return handOff(early)
        }
        while let entry = handoff.popReady() {
            guard let frame = scheduledByFrame.removeValue(forKey: entry.element) else {
                continue
            }
            if !frame.shouldPresent {
                counters.framesSkippedLate &+= 1
                if frame.isRandomAccess {
                    noteRandomAccessHandedOff()
                }
                continue
            }
            if nowMicros < frame.presentationMicroseconds {
                // Not due yet: hold it outside the queue.
                pendingEarly = frame
                return nil
            }
            return handOff(frame)
        }
        return nil
    }

    /// Popping a frame hands it to the page's renderer; a random-access
    /// frame handed off closes the handoff's await-IRAP episode.
    private mutating func handOff(_ frame: ScheduledFrame) -> ScheduledFrame {
        if frame.isRandomAccess {
            noteRandomAccessHandedOff()
        }
        return frame
    }

    public mutating func notePresented(frameNumber: UInt32) {
        counters.framesPresented &+= 1
    }

    /// The page gave up on a frame (decode failed or its bytes were gone).
    public mutating func noteDropped(frameNumber: UInt32) {
        annexBByFrame.removeValue(forKey: frameNumber)
        scheduledByFrame.removeValue(forKey: frameNumber)
        if pendingEarly?.frameNumber == frameNumber {
            pendingEarly = nil
        }
    }

    /// The IDR request due now: an open episode's first, or its retry once
    /// the interval since the last has passed.
    public mutating func idrRequestDue(nowMicros: UInt64) -> IdrRequest? {
        recovery.requestDue(now: ClientTimestamp(microseconds: nowMicros))
    }

    // MARK: Interior

    private mutating func noteRandomAccessHandedOff() {
        handoff.noteRandomAccessEnqueued()
        conductor.noteRandomAccessEnqueued()
    }

    private mutating func demandRecovery(frame: UInt32) {
        recovery.recordDemand(frame: FrameNumber(rawValue: frame))
    }

    private mutating func absorb(_ outcome: BoundedRendererHandoff<UInt32>.Outcome) {
        absorb(discarded: outcome.discarded.map(\.element),
               recoveryRequested: outcome.recoveryRequested)
    }

    /// Discarded entries lose their presentation metadata only; their
    /// Annex-B stays queued for decode so the reference chain holds.
    private mutating func absorb(discarded: [UInt32], recoveryRequested: Bool) {
        for frame in discarded {
            if scheduledByFrame.removeValue(forKey: frame) != nil {
                counters.framesNotPresentable &+= 1
            }
            if pendingEarly?.frameNumber == frame {
                pendingEarly = nil
            }
        }
        if recoveryRequested, let newest = discarded.max() {
            demandRecovery(frame: newest)
        }
    }

    private mutating func storeForDecode(_ frameNumber: UInt32, _ annexB: [UInt8]) {
        annexBByFrame[frameNumber] = annexB
        decodeOrder.append(frameNumber)
        // Evict the oldest undrained entries past the bound; entries already
        // taken are skipped as the head advances.
        while annexBByFrame.count > Self.decodeBacklogCapacity,
              let oldest = decodeOrder.popFirst()
        {
            if annexBByFrame.removeValue(forKey: oldest) != nil {
                counters.decodeBacklogEvicted &+= 1
                demandRecovery(frame: oldest)
            }
        }
        // Frames the page took leave dead entries behind; drop them once
        // they dominate so the log stays bounded.
        if decodeOrder.count > 4 * Self.decodeBacklogCapacity {
            decodeOrder.removeAll { annexBByFrame[$0] == nil }
        }
    }

    private mutating func schedule(
        _ unit: DecodeUnit, arrival: UInt64,
        hostClock: ClientHostClock.Estimate?
    ) -> ScheduledFrame {
        let capture = unit.timestamp.microseconds
        let mapped: UInt64
        if let hostClock {
            mapped = hostClock.map(unit.timestamp).microseconds
        } else {
            let anchor = self.anchor ?? (capture, arrival)
            self.anchor = anchor
            mapped = anchor.arrival &+ (capture &- anchor.capture)
        }
        let decision = conductor.schedule(
            mappedCaptureMicroseconds: mapped,
            arrivalMicroseconds: arrival,
            sourceCaptureMicroseconds: capture
        )
        let frame = ScheduledFrame(
            frameNumber: unit.frameNumber.rawValue,
            sourceCaptureMicroseconds: capture,
            arrivalMicroseconds: arrival,
            presentationMicroseconds: decision.presentationMicroseconds,
            cueMicroseconds: decision.cueMicroseconds,
            pathDelayMicroseconds: decision.pathDelayMicroseconds,
            reserveMicroseconds: decision.reserveMicroseconds,
            latenessMicroseconds: decision.latenessMicroseconds,
            isRandomAccess: unit.isIDR,
            shouldPresent: decision.latenessMicroseconds == 0,
            annexBByteCount: unit.annexB.count
        )
        storeForDecode(frame.frameNumber, unit.annexB)

        if decision.shouldFlush {
            pendingEarly = nil
            let flushed = handoff.failEpisode()
            absorb(flushed)
            // The queue may have been empty (or held only an early frame):
            // the flush still owes the stream an IRAP.
            if flushed.recoveryRequested {
                demandRecovery(frame: frame.frameNumber)
            }
        }
        if unit.isIDR {
            // A usable IRAP answers any open recovery episode, including
            // one its own arrival just opened.
            recovery.noteUsableIrapAccepted()
        }
        let outcome = handoff.offer(
            frame.frameNumber,
            frame: RendererFrameDescriptor(
                isRandomAccess: unit.isIDR,
                submittedMicroseconds: arrival
            )
        )
        if outcome.accepted {
            scheduledByFrame[frame.frameNumber] = frame
        } else {
            counters.framesNotPresentable &+= 1
        }
        absorb(
            discarded: outcome.discarded.map(\.element)
                .filter { $0 != frame.frameNumber },
            recoveryRequested: outcome.recoveryRequested
        )
        if outcome.recoveryRequested, outcome.discarded.isEmpty == false,
           !outcome.accepted
        {
            demandRecovery(frame: frame.frameNumber)
        }
        return frame
    }
}
