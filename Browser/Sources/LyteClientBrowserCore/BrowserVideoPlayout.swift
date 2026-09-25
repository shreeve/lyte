import LyteClientSession
import LyteCore
import LyteWire

/// Sans-IO browser video organ: `VideoAssembler` + `VideoBeatConductor` +
/// `BoundedRendererHandoff`, with the shared repair policy
/// (`ClientNackPolicy`) and IDR episode (`ClientIdrRecovery`) over them.
/// Page JS owns WebCodecs decode and WebGPU present and executes what this
/// type decides:
///
/// - Decode: a frame's Annex-B waits in the decode backlog until the page
///   takes it, in decode order. Only a decodable frame is ever handed out:
///   while a recovery episode is open only random-access frames enter the
///   backlog, and a frame evicted from it takes every later dependent
///   frame with it. `takeAnnexB` returning nil means "skip this frame".
/// - Presentation: metadata lives only while the handoff holds the frame.
///   A scheduled frame the page must never show says so in its
///   `shouldPresent` (late, refused, or outside an open episode); one the
///   handoff drops later is reported once through `takeAbandoned`.
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
        /// Frames the handoff refused or discarded, or an open recovery
        /// episode kept from it (never presented).
        public var framesNotPresentable: UInt64 = 0
        /// Annex-B evicted because the page stopped taking decode input.
        public var decodeBacklogEvicted: UInt64 = 0
        /// Frames never handed out for decode: their reference chain was
        /// broken (an open recovery episode, or an evicted predecessor).
        public var framesUndecodable: UInt64 = 0
        public var fecImpossible: UInt64 = 0
        /// Shards the assembler dropped (mostly late FEC surplus).
        public var shardsDropped: UInt64 = 0

        public init() {}
    }

    /// What one ingested shard produced: log notes, frames the Conductor
    /// scheduled, and NACK entries for an immediate feedback report.
    public struct Ingested: Sendable {
        public var events: [String] = []
        public var scheduled: [ScheduledFrame] = []
        public var nacks: [FeedbackReport.NackEntry] = []
    }

    /// Undrained decode input is bounded: about two seconds at 60 fps.
    public static let decodeBacklogCapacity = 120

    /// WT + WASM ingest is slower than native UDP; groups get longer
    /// before stale eviction so paced shards can finish.
    static let assemblerConfig = VideoAssemblerConfig(
        holdbackFrameCount: 6,
        staleAfterMicroseconds: 1_000_000
    )

    private var assembler = VideoAssembler(
        channel: .videoActive, config: BrowserVideoPlayout.assemblerConfig)
    /// Rule 3's staleness budget is the assembler's own horizon.
    private var nack = ClientNackPolicy(config: ClientNackPolicy.Config(
        staleBudgetMicroseconds:
            BrowserVideoPlayout.assemblerConfig.staleAfterMicroseconds))
    private var conductor = VideoBeatConductor()
    private var handoff = BoundedRendererHandoff<UInt32>(
        // The page decodes asynchronously; a long deadline keeps expire()
        // from discarding frames before WebCodecs has run.
        config: .init(capacity: 12, deadlineMicroseconds: UInt64.max / 4)
    )

    /// Until the host clock has its first sample, the first assembled
    /// frame anchors host capture to client arrival.
    private var anchor: (capture: UInt64, arrival: UInt64)?

    private var annexBByFrame: [UInt32: (bytes: [UInt8], isRandomAccess: Bool)] = [:]
    /// Frame numbers in decode order; entries already taken are skipped
    /// when they reach the front.
    private var decodeOrder = Deque<UInt32>()
    private var scheduledByFrame: [UInt32: ScheduledFrame] = [:]
    private var pendingEarly: ScheduledFrame?
    /// Frames the handoff dropped after the page was told to present them.
    private var abandoned: [UInt32] = []
    public private(set) var counters = Counters()

    /// The IDR-request episode, the native requester's policy.
    private var recovery = ClientIdrRecovery()

    public init() {}

    public var framesAssembled: UInt64 { counters.framesAssembled }
    /// Frames whose Annex-B is still waiting for the page to take it.
    public var decodeBacklogCount: Int { annexBByFrame.count }
    /// Frames whose presentation metadata is still held.
    public var presentationBacklogCount: Int {
        scheduledByFrame.count
    }
    public var nackStats: ClientNackPolicy.Stats { nack.stats }

    /// Unsealed video shard → assembler → Conductor schedule → handoff.
    /// Capture times map to the client clock through `hostClock`, whose
    /// min RTT also feeds the NACK staleness gate.
    public mutating func ingestShard(
        envelope: Envelope,
        payload: ArraySlice<UInt8>,
        arrivalMicroseconds: UInt64,
        hostClock: ClientHostClock.Estimate? = nil
    ) -> Ingested {
        var ingested = Ingested()
        let now = ClientTimestamp(microseconds: arrivalMicroseconds)
        for event in assembler.ingest(envelope: envelope, payload: payload, now: now) {
            repair(event, rttMicroseconds: hostClock?.minRttMicroseconds,
                   now: now, into: &ingested)
            switch event {
            case .decoded(let unit):
                counters.framesAssembled &+= 1
                ingested.scheduled.append(schedule(
                    unit, arrival: arrivalMicroseconds, hostClock: hostClock))
            case .framesSkipped(let from, let through, let reason):
                ingested.events.append(
                    "video: skipped frames \(from.rawValue)…\(through.rawValue) (\(reason))"
                )
                demandRecovery(frame: through.rawValue)
            case .fecImpossible(let frame, let lost, let parity):
                counters.fecImpossible &+= 1
                ingested.events.append(
                    "video: fecImpossible frame=\(frame.rawValue) lostData=\(lost) parity=\(parity)"
                )
                // A live repair ask holds the IDR for its deadline.
                if !nack.shouldDeferFecImpossible(frame: frame, now: now) {
                    demandRecovery(frame: frame.rawValue)
                }
            case .shardDropped:
                // Routine: FEC surplus arriving after its frame completed.
                counters.shardsDropped &+= 1
            default:
                break
            }
        }
        return ingested
    }

    /// The beat: stale assembler groups, the NACK deadlines, and the
    /// handoff's own expiry.
    public mutating func evictStale(nowMicros: UInt64) -> [String] {
        var swept = Ingested()
        let now = ClientTimestamp(microseconds: nowMicros)
        for event in assembler.evictStale(now: now) {
            repair(event, rttMicroseconds: nil, now: now, into: &swept)
            if case .framesSkipped(let from, let through, let reason) = event {
                swept.events.append(
                    "video: stale-skip \(from.rawValue)…\(through.rawValue) (\(reason))"
                )
                demandRecovery(frame: through.rawValue)
            }
        }
        escalate(nack.tick(now: now), into: &swept)
        let expired = handoff.expire(nowMicroseconds: nowMicros)
        if expired.recoveryRequested {
            swept.events.append("video: handoff expire → await IRAP")
        }
        absorb(expired)
        return swept.events
    }

    /// The host refused to repair `frame` (0x23): its ask stops waiting
    /// and escalates to the IDR episode now.
    public mutating func handleRepairRefusal(
        frame: FrameNumber, nowMicros: UInt64
    ) -> [String] {
        var refused = Ingested()
        escalate(
            nack.handleRefusal(
                frame: frame, now: ClientTimestamp(microseconds: nowMicros)),
            into: &refused)
        return refused.events
    }

    /// Hands out a decodable frame's Annex-B exactly once; nil means the
    /// page skips the frame.
    public mutating func takeAnnexB(frameNumber: UInt32) -> [UInt8]? {
        annexBByFrame.removeValue(forKey: frameNumber)?.bytes
    }

    /// Frames the page was told to present that will never be due: close
    /// them wherever they are. Each is reported once.
    public mutating func takeAbandoned() -> [UInt32] {
        defer { abandoned.removeAll(keepingCapacity: true) }
        return abandoned
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

    public mutating func notePresented() {
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

    /// Forwards one assembler event to the NACK policy, in event order.
    private mutating func repair(
        _ event: VideoAssemblerEvent, rttMicroseconds: Int64?,
        now: ClientTimestamp, into ingested: inout Ingested
    ) {
        guard let signal = VideoRepairSignal(event) else { return }
        escalate(
            nack.handle(signal, rttMicroseconds: rttMicroseconds, now: now),
            into: &ingested)
    }

    private mutating func escalate(
        _ decision: ClientNackPolicy.Decision, into ingested: inout Ingested
    ) {
        ingested.nacks += decision.nacks
        for frame in decision.escalations {
            ingested.events.append(
                "nack: frame \(frame.rawValue) repair abandoned — IDR instead")
            demandRecovery(frame: frame.rawValue)
        }
    }

    private mutating func noteRandomAccessHandedOff() {
        handoff.noteRandomAccessEnqueued()
        conductor.noteRandomAccessEnqueued()
    }

    private mutating func demandRecovery(frame: UInt32) {
        recovery.recordDemand(frame: FrameNumber(rawValue: frame))
    }

    /// Discarded entries lose their presentation metadata only; their
    /// Annex-B stays queued for decode so the reference chain holds. A
    /// requested recovery is one verdict, naming `newest` when a frame
    /// being scheduled caused it.
    private mutating func absorb(
        _ outcome: BoundedRendererHandoff<UInt32>.Outcome,
        newest: UInt32? = nil
    ) {
        for entry in outcome.discarded {
            let frame = entry.element
            if let scheduled = scheduledByFrame.removeValue(forKey: frame) {
                counters.framesNotPresentable &+= 1
                if scheduled.shouldPresent { abandoned.append(frame) }
            }
            if pendingEarly?.frameNumber == frame {
                abandon(early: pendingEarly!)
            }
        }
        if outcome.recoveryRequested,
           let damaged = newest ?? outcome.discarded.map(\.element).max() {
            demandRecovery(frame: damaged)
        }
    }

    private mutating func abandon(early frame: ScheduledFrame) {
        pendingEarly = nil
        abandoned.append(frame.frameNumber)
    }

    private mutating func storeForDecode(_ unit: DecodeUnit) {
        let frameNumber = unit.frameNumber.rawValue
        annexBByFrame[frameNumber] = (unit.annexB, unit.isIDR)
        decodeOrder.append(frameNumber)
        // Evict the oldest undrained entries past the bound; entries already
        // taken are skipped as the head advances.
        while annexBByFrame.count > Self.decodeBacklogCapacity,
              let oldest = decodeOrder.popFirst()
        {
            if annexBByFrame.removeValue(forKey: oldest) != nil {
                counters.decodeBacklogEvicted &+= 1
                demandRecovery(frame: oldest)
                dropDependents()
            }
        }
        // Frames the page took leave dead entries behind; drop them once
        // they dominate so the log stays bounded.
        if decodeOrder.count > 4 * Self.decodeBacklogCapacity {
            decodeOrder.removeAll { annexBByFrame[$0] == nil }
        }
    }

    /// An evicted frame breaks the chain behind it: every queued frame up
    /// to the next random-access one references it.
    private mutating func dropDependents() {
        for frame in decodeOrder {
            guard let entry = annexBByFrame[frame] else { continue }
            if entry.isRandomAccess { return }
            annexBByFrame.removeValue(forKey: frame)
            counters.framesUndecodable &+= 1
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
        // An open episode admits only random-access frames: nothing queued
        // behind the damage may reach the decoder or race the IRAP.
        let admitted = recovery.admits(isRandomAccess: unit.isIDR)
        var frame = ScheduledFrame(
            frameNumber: unit.frameNumber.rawValue,
            sourceCaptureMicroseconds: capture,
            arrivalMicroseconds: arrival,
            presentationMicroseconds: decision.presentationMicroseconds,
            cueMicroseconds: decision.cueMicroseconds,
            pathDelayMicroseconds: decision.pathDelayMicroseconds,
            reserveMicroseconds: decision.reserveMicroseconds,
            latenessMicroseconds: decision.latenessMicroseconds,
            isRandomAccess: unit.isIDR,
            shouldPresent: admitted && decision.latenessMicroseconds == 0,
            annexBByteCount: unit.annexB.count
        )
        if admitted {
            storeForDecode(unit)
        } else {
            counters.framesUndecodable &+= 1
            counters.framesNotPresentable &+= 1
            return frame
        }

        if decision.shouldFlush {
            if let early = pendingEarly { abandon(early: early) }
            // The queue may have been empty (or held only an early frame):
            // the flush still owes the stream an IRAP.
            absorb(handoff.failEpisode(), newest: frame.frameNumber)
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
            frame.shouldPresent = false
        }
        absorb(outcome, newest: frame.frameNumber)
        return frame
    }
}
