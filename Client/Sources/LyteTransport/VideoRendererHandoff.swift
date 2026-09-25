@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import LyteCore
import LyteIO
import LyteWire
import Synchronization

/// The platform renderer surface the handoff drives.
public protocol VideoRendererPort: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    var status: AVQueuedSampleBufferRenderingStatus { get }
    var error: (any Error)? { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func flush(
        removingDisplayedImage: Bool,
        completionHandler: (@Sendable () -> Void)?)
    func requestMediaDataWhenReady(
        on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
    func stopRequestingMediaData()
    func loadVideoPerformanceMetrics(
        completionHandler: @escaping @Sendable (AVVideoPerformanceMetrics?) -> Void)
}

extension AVSampleBufferVideoRenderer: VideoRendererPort {}

/// The session side of renderer recovery: a damaged or backed-up
/// renderer asks for a fresh IRAP, and an IRAP that actually reached the
/// renderer closes the episode.
///
/// Invariant: while the handoff awaits an IRAP, the session's episode is
/// open, so its IDR request keeps retrying. The session closes its episode
/// only for an IRAP that closed the handoff's gate (`closesRecovery`), and
/// the handoff re-asserts the episode whenever it opens a gate for a
/// session demand that the session may have closed meanwhile.
public protocol VideoRecoveryPeer: AnyObject, Sendable {
    func requestVideoRecovery(after frame: FrameNumber, cause: VideoRecoveryCause)
    /// An IRAP reached the renderer; `closesRecovery` says it closed the
    /// handoff's await-IRAP gate rather than landing outside one.
    func noteVideoIrapEnqueued(frame: FrameNumber, closesRecovery: Bool)
    /// The handoff opened a gate for a session demand: reopen the
    /// session's episode (and its IDR request) if it has closed since.
    func ensureVideoRecoveryOpen(after frame: FrameNumber, cause: VideoRecoveryCause)
}


/// The client's production video sink: serial, bounded ownership of
/// compressed samples between the sample-build worker and the renderer.
///
/// - Samples hop onto the serial `queue` before touching the renderer:
///   `enqueue` can block against a main-thread CA transaction.
/// - `isReadyForMoreMediaData == false` queues the complete dependency
///   chain (BoundedRendererHandoff); pressure, a stale entry, or renderer
///   failure discards the whole episode, flushes the renderer, and awaits
///   an IRAP instead of dropping an arbitrary P-frame. No sample dequeues
///   while that flush is outstanding.
/// - Every sample is retimed to the Conductor's presentation beat.
/// - Delivery books and the flight recorder see every frame's fate.
/// - After `stop()` the handoff is inert: nothing more reaches the
///   renderer, the peer, or the books.
public final class VideoRendererHandoff: VideoSink, @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        var sample: CMSampleBuffer
        var unit: DecodeUnit
        var dispatchedNanoseconds: UInt64
        var token: VideoFlightRecorder.Token
        var build: VideoFrameBuildTelemetry?
        var decision: VideoBeatConductor.Decision
        var encounteredRendererBackpressure: Bool
    }

    private struct WeakPeer {
        weak var value: (any VideoRecoveryPeer)?
    }

    private let renderer: any VideoRendererPort
    private let queue: DispatchQueue
    let clockModel: HostClockModel
    /// The Conductor is scheduled on the submitting thread and told of
    /// IRAPs on the delivery queue.
    private let playout: Mutex<VideoBeatConductor>
    private let books: VideoDeliveryBooks
    let recorder: VideoFlightRecorder
    private let onDimensionsChanged: @Sendable (Int32, Int32) -> Void
    private let dimensions = Mutex<(width: Int32, height: Int32)>((0, 0))
    private let peer = Mutex(WeakPeer())
    private let stopped = Atomic<Bool>(false)

    // Queue-confined.
    private var policy: BoundedRendererHandoff<Pending>
    /// Submission instants of the policy's entries, oldest first: entries
    /// only ever leave the policy from the front or all at once, so
    /// trimming this to `policy.count` from the front keeps it exact.
    private var pendingSubmissions = Deque<UInt64>()
    private var expiryTimer: DispatchSourceTimer?
    private var expiryDeadline: UInt64?
    private var requesting = false
    private var recoveryEpisode: UInt64 = 0
    private var activeRecoveryEpisode: UInt64?
    private var forcedMetricsProbes = 0
    private var flushBarrier = RendererRecoveryFlushBarrier()

    public init(
        renderer: any VideoRendererPort,
        queue: DispatchQueue,
        clockModel: HostClockModel = HostClockModel(),
        books: VideoDeliveryBooks,
        recorder: VideoFlightRecorder,
        onDimensionsChanged: @escaping @Sendable (Int32, Int32) -> Void = { _, _ in },
        playoutConfig: VideoBeatConductor.Config = .init(),
        queuedFrameDeadlineMicroseconds: UInt64 = 50_000
    ) {
        self.policy = BoundedRendererHandoff(config: .init(
            deadlineMicroseconds: queuedFrameDeadlineMicroseconds))
        self.renderer = renderer
        self.queue = queue
        self.clockModel = clockModel
        self.books = books
        self.recorder = recorder
        self.onDimensionsChanged = onDimensionsChanged
        self.playout = Mutex(VideoBeatConductor(config: playoutConfig))
    }

    /// Points `layer` at the host time clock, rate 1: the handoff retimes
    /// every sample to a presentation instant on that clock.
    @MainActor
    public static func attachHostClockTimebase(to layer: AVSampleBufferDisplayLayer) {
        let hostClock = CMClockGetHostTimeClock()
        var timebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: hostClock,
            timebaseOut: &timebase) == noErr,
            let timebase else { return }
        CMTimebaseSetTime(timebase, time: CMClockGetTime(hostClock))
        CMTimebaseSetRate(timebase, rate: 1)
        layer.controlTimebase = timebase
    }

    /// The renderer's own verdict (`.failed` when samples do not decode).
    public var rendererStateDescription: String {
        switch renderer.status {
        case .rendering: return "rendering"
        case .failed: return "FAILED: \(String(describing: renderer.error))"
        default: return "idle"
        }
    }

    /// Late-binds the session that feeds this sink (the session is built
    /// with the sink, so it cannot be an init argument). Held weakly.
    public func bind(_ peer: any VideoRecoveryPeer) {
        self.peer.withLock { $0.value = peer }
    }

    public func submit(sample: CMSampleBuffer, unit: DecodeUnit) {
        guard !stopped.load(ordering: .relaxed) else { return }
        nonisolated(unsafe) let transferred = sample
        let dispatched = SystemMonotonicClock.nowNanoseconds
        let arrival = dispatched / 1_000
        let mapped = clockModel.map(unit.timestamp)?.microseconds ?? arrival
        let decision = playout.withLock {
            $0.schedule(
                mappedCaptureMicroseconds: mapped,
                arrivalMicroseconds: arrival,
                sourceCaptureMicroseconds: unit.timestamp.microseconds)
        }
        if PipelineWitness.isEnabled {
            PipelineWitness.record("frameReady", fields: [
                "frame": String(unit.frameNumber.rawValue),
                "captureMicroseconds": String(unit.timestamp.microseconds),
                "mappedCaptureMicroseconds": String(mapped),
                "readyMonotonicNanoseconds": String(dispatched),
                "scheduledPresentationMicroseconds": String(
                    decision.presentationMicroseconds),
                "cueMicroseconds": String(decision.cueMicroseconds),
                "pathDelayMicroseconds": String(
                    decision.pathDelayMicroseconds),
                "reserveMicroseconds": String(decision.reserveMicroseconds),
                "latenessMicroseconds": String(decision.latenessMicroseconds),
            ])
        }
        let pending = Pending(
            sample: transferred,
            unit: unit,
            dispatchedNanoseconds: dispatched,
            token: recorder.frameReady(
                frame: unit.frameNumber.rawValue,
                hostMicroseconds: unit.timestamp.microseconds,
                nowNanoseconds: dispatched),
            build: VideoSampleTiming.buildTelemetry(from: sample),
            decision: decision,
            encounteredRendererBackpressure: false)
        queue.async { [self] in accept(pending) }
        // Teach the owner its coordinate space once per size.
        if let format = CMSampleBufferGetFormatDescription(sample) {
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            let changed = dimensions.withLock { current in
                guard current != (dims.width, dims.height) else { return false }
                current = (dims.width, dims.height)
                return true
            }
            if changed { onDimensionsChanged(dims.width, dims.height) }
        }
    }

    /// The session's pipeline found the stream damaged upstream of this
    /// sink: the current episode is void.
    public func beginRecovery(cause: VideoRecoveryCause, after frame: FrameNumber) {
        queue.async { [self] in
            guard isLive else { return }
            trace(policy.awaitingRandomAccess
                    ? "handoffDamageOverlap" : "handoffDamageReceived",
                  frame: frame.rawValue, cause: cause)
            let outcome = policy.failEpisode()
            process(
                outcome,
                recoveryFrame: frame,
                cause: cause,
                requestRecovery: false)
            // An IRAP that closed the previous gate after this demand was
            // raised may have closed the session's episode with it.
            if outcome.recoveryRequested {
                peer.withLock { $0.value }?.ensureVideoRecoveryOpen(
                    after: frame, cause: cause)
            }
        }
    }

    /// Retires the handoff without blocking. Queued samples are discarded
    /// unrecorded; with `flushingRenderer`, the flush is ordered on the
    /// delivery queue so a successor starts from a clean renderer.
    public func stop(flushingRenderer: Bool = false) {
        guard !stopped.exchange(true, ordering: .relaxed) else { return }
        queue.async { [self] in
            flushBarrier.complete()
            expiryTimer?.cancel()
            expiryTimer = nil
            renderer.stopRequestingMediaData()
            requesting = false
            _ = policy.reset()
            pendingSubmissions.removeAll()
            if flushingRenderer { renderer.flush() }
        }
    }

    // MARK: - Queue-confined

    private var isLive: Bool { !stopped.load(ordering: .relaxed) }

    private func accept(_ incoming: Pending) {
        guard isLive else { return }
        var pending = incoming
        pending.encounteredRendererBackpressure = !renderer.isReadyForMoreMediaData

        if pending.decision.shouldFlush || renderer.status == .failed {
            let cause: VideoRecoveryCause = pending.decision.shouldFlush
                ? .freshPresentationDebt : .rendererFailure
            trace("handoffLocalDamage",
                  frame: pending.unit.frameNumber.rawValue, cause: cause,
                  isRandomAccess: pending.unit.isIDR)
            // An IRAP in hand answers the flush it trips.
            process(
                policy.failEpisode(),
                recoveryFrame: pending.unit.frameNumber,
                cause: cause,
                requestRecovery: !pending.unit.isIDR)
        }

        let now = SystemMonotonicClock.nowMicroseconds
        let outcome = policy.offer(
            pending,
            frame: RendererFrameDescriptor(
                isRandomAccess: pending.unit.isIDR,
                submittedMicroseconds: now))
        if outcome.accepted { pendingSubmissions.append(now) }
        process(
            outcome,
            recoveryFrame: pending.unit.frameNumber,
            cause: .rendererBackpressure)
        recordAdmission(pending, accepted: outcome.accepted)
        if outcome.accepted {
            armRenderer()
            armExpiry()
        }
    }

    private func recordAdmission(_ pending: Pending, accepted: Bool) {
        let kind: String
        if pending.unit.isIDR {
            kind = accepted
                ? "handoffIrapAcceptedPendingEnqueue" : "handoffIrapRejected"
        } else if policy.awaitingRandomAccess, !policy.randomAccessPending {
            // Before the episode's IRAP arrives nothing else may queue;
            // once it is pending, its inter frames legitimately queue
            // behind it.
            kind = accepted
                ? "invariantViolationNonIrapAcceptedDuringRecovery"
                : "handoffRejectedNonIrap"
        } else {
            return
        }
        trace(kind, frame: pending.unit.frameNumber.rawValue,
              isRandomAccess: pending.unit.isIDR)
    }

    private func armRenderer() {
        guard flushBarrier.mayEnqueue, !requesting, policy.count > 0 else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.drainReady()
        }
    }

    /// One timer, re-armed at the oldest pending entry's deadline.
    private func armExpiry() {
        trimSubmissions()
        guard let oldest = pendingSubmissions.first else {
            expiryTimer?.cancel()
            expiryTimer = nil
            expiryDeadline = nil
            return
        }
        let deadline = oldest &+ policy.config.deadlineMicroseconds
        if let armed = expiryDeadline, armed <= deadline, expiryTimer != nil {
            return
        }
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let now = SystemMonotonicClock.nowMicroseconds
        let delay = deadline > now ? deadline - now : 0
        timer.schedule(deadline: .now() + .microseconds(Int(delay)))
        timer.setEventHandler { [weak self] in self?.expire() }
        timer.resume()
        expiryTimer = timer
        expiryDeadline = deadline
    }

    private func trimSubmissions() {
        let excess = pendingSubmissions.count - policy.count
        if excess > 0 { pendingSubmissions.removeFirst(excess) }
    }

    private func expire() {
        expiryTimer = nil
        expiryDeadline = nil
        guard isLive else { return }
        process(
            policy.expire(nowMicroseconds: SystemMonotonicClock.nowMicroseconds),
            recoveryFrame: FrameNumber(rawValue: 0),
            cause: .rendererBackpressure)
        armExpiry()
    }

    private func drainReady() {
        guard isLive, flushBarrier.mayEnqueue else { return }
        if renderer.status == .failed {
            process(
                policy.failEpisode(),
                recoveryFrame: FrameNumber(rawValue: 0),
                cause: .rendererFailure)
            return
        }
        while isLive, renderer.isReadyForMoreMediaData,
              let entry = policy.popReady() {
            trimSubmissions()
            let pending = entry.element
            let closesRecovery = policy.awaitingRandomAccess
                && policy.randomAccessPending
                && pending.unit.isIDR
            let started = SystemMonotonicClock.nowNanoseconds
            guard let timed = VideoSampleTiming.retimed(
                pending.sample,
                presentationMicroseconds: pending.decision.presentationMicroseconds
            ) else {
                var failure = policy.failEpisode()
                failure.discarded.insert(entry, at: 0)
                process(
                    failure,
                    recoveryFrame: pending.unit.frameNumber,
                    cause: .rendererFailure)
                return
            }
            if closesRecovery {
                // `flush()` discards queued samples, but CoreMedia requires
                // this attachment to reset the compressed decoder itself;
                // without it every frame after a flush reads as corrupted.
                CMSetAttachment(
                    timed,
                    key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                    value: kCFBooleanTrue,
                    attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
            }
            let resetAttached = CMGetAttachment(
                timed,
                key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                attachmentModeOut: nil) != nil
            if pending.unit.isIDR || activeRecoveryEpisode != nil
                || forcedMetricsProbes > 0 {
                trace(pending.unit.isIDR
                        ? "rendererEnqueueIrap" : "rendererEnqueueNonIrap",
                      frame: pending.unit.frameNumber.rawValue,
                      isRandomAccess: pending.unit.isIDR, reset: resetAttached)
            }
            if PipelineWitness.isEnabled {
                PipelineWitness.record("rendererEnqueueBegin", fields: [
                    "frame": String(pending.unit.frameNumber.rawValue),
                    "scheduledPresentationMicroseconds": String(
                        pending.decision.presentationMicroseconds),
                ])
            }
            renderer.enqueue(timed)
            if PipelineWitness.isEnabled {
                PipelineWitness.record("rendererEnqueueCompleted", fields: [
                    "frame": String(pending.unit.frameNumber.rawValue),
                ])
            }
            if pending.unit.isIDR {
                policy.noteRandomAccessEnqueued()
                playout.withLock { $0.noteRandomAccessEnqueued() }
                peer.withLock { $0.value }?.noteVideoIrapEnqueued(
                    frame: pending.unit.frameNumber,
                    closesRecovery: closesRecovery)
                if closesRecovery {
                    forcedMetricsProbes = 3
                    trace("handoffRecoveryClosed",
                          frame: pending.unit.frameNumber.rawValue,
                          isRandomAccess: true, reset: resetAttached)
                    activeRecoveryEpisode = nil
                }
            }
            finish(
                pending,
                enqueueStarted: started,
                enqueueFinished: SystemMonotonicClock.nowNanoseconds,
                rendererReady: !pending.encounteredRendererBackpressure,
                rendererFailed: false,
                dropped: false,
                recovery: false)
        }
        if policy.count == 0 {
            renderer.stopRequestingMediaData()
            requesting = false
        }
        armExpiry()
    }

    private func process(
        _ outcome: BoundedRendererHandoff<Pending>.Outcome,
        recoveryFrame: FrameNumber,
        cause: VideoRecoveryCause,
        requestRecovery: Bool = true
    ) {
        trimSubmissions()
        if outcome.recoveryRequested {
            recoveryEpisode &+= 1
            activeRecoveryEpisode = recoveryEpisode
            renderer.stopRequestingMediaData()
            requesting = false
            let startedFlush = flushBarrier.begin()
            recorder.recordRecoveryCause(cause)
            trace(startedFlush
                    ? "rendererRecoveryFlushStarted"
                    : "rendererRecoveryFlushAlreadyPending",
                  frame: recoveryFrame.rawValue, cause: cause)
            if startedFlush {
                renderer.flush(removingDisplayedImage: false) { [weak self] in
                    self?.queue.async { [weak self] in
                        self?.completeRecoveryFlush(
                            frame: recoveryFrame, cause: cause)
                    }
                }
            }
            if requestRecovery {
                peer.withLock { $0.value }?.requestVideoRecovery(
                    after: outcome.discarded.last?.element.unit.frameNumber
                        ?? recoveryFrame,
                    cause: cause)
            }
            if outcome.discarded.isEmpty {
                recorder.recordRendererRecovery()
            }
        }
        for (index, entry) in outcome.discarded.enumerated() {
            finish(
                entry.element,
                rendererReady: renderer.isReadyForMoreMediaData,
                rendererFailed: renderer.status == .failed,
                dropped: true,
                recovery: outcome.recoveryRequested && index == 0)
        }
    }

    private func completeRecoveryFlush(frame: FrameNumber, cause: VideoRecoveryCause) {
        guard isLive else { return }
        flushBarrier.complete()
        trace("rendererRecoveryFlushCompleted", frame: frame.rawValue,
              cause: cause)
        armRenderer()
    }

    /// One recovery-lifecycle record carrying the gate's current state.
    private func trace(
        _ kind: String,
        frame: UInt32,
        cause: VideoRecoveryCause? = nil,
        isRandomAccess: Bool? = nil,
        reset: Bool? = nil
    ) {
        recorder.recordRecoveryLifecycle(
            kind: kind,
            frame: frame,
            cause: cause,
            episode: activeRecoveryEpisode,
            isRandomAccess: isRandomAccess,
            resetDecoderBeforeDecoding: reset,
            awaitingRandomAccess: policy.awaitingRandomAccess,
            randomAccessPending: policy.randomAccessPending,
            pendingCount: policy.count)
    }

    private func finish(
        _ pending: Pending,
        enqueueStarted: UInt64? = nil,
        enqueueFinished: UInt64? = nil,
        rendererReady: Bool = false,
        rendererFailed: Bool = false,
        dropped: Bool,
        recovery: Bool
    ) {
        let started = enqueueStarted ?? SystemMonotonicClock.nowNanoseconds
        let finished = enqueueFinished ?? started
        let finishedMicroseconds = finished / 1_000
        let presentation = pending.decision.presentationMicroseconds
        let handoffLateness = finishedMicroseconds > presentation
            ? finishedMicroseconds - presentation : 0
        books.record(
            hopMilliseconds: Double(finished &- pending.dispatchedNanoseconds) / 1e6)
        recorder.frameEnqueued(
            pending.token,
            enqueueStartedNanoseconds: started,
            enqueueFinishedNanoseconds: finished,
            rendererReady: rendererReady,
            rendererFailed: rendererFailed,
            rendererDropped: dropped,
            sampleBuildMicroseconds: pending.build?.sampleBuildMicroseconds,
            assemblyLockHoldMicroseconds: pending.build?.assemblyLockHoldMicroseconds,
            scheduledPresentationMicroseconds: presentation,
            cueMicroseconds: pending.decision.cueMicroseconds,
            pathDelayMicroseconds: pending.decision.pathDelayMicroseconds,
            reserveMicroseconds: pending.decision.reserveMicroseconds,
            presentationLatenessMicroseconds: max(
                pending.decision.latenessMicroseconds, handoffLateness),
            rendererRecovery: recovery)
        sampleMetricsIfDue(
            after: pending.token,
            frame: pending.unit.frameNumber.rawValue,
            isRandomAccess: pending.unit.isIDR)
    }

    private func sampleMetricsIfDue(
        after token: VideoFlightRecorder.Token,
        frame: UInt32,
        isRandomAccess: Bool
    ) {
        let forced = forcedMetricsProbes > 0
        if forced { forcedMetricsProbes -= 1 }
        guard forced || recorder.shouldSampleRenderer(after: token) else { return }
        renderer.loadVideoPerformanceMetrics { [recorder] metrics in
            if let metrics {
                recorder.recordRendererMetrics(.init(
                    totalFrames: metrics.totalNumberOfFrames,
                    droppedFrames: metrics.numberOfDroppedFrames,
                    corruptedFrames: metrics.numberOfCorruptedFrames,
                    accumulatedDelayMilliseconds:
                        metrics.totalAccumulatedFrameDelay * 1_000),
                    sampledAfter: token,
                    sampledAfterFrame: frame,
                    sampledAfterIsRandomAccess: isRandomAccess)
            }
            // Diagnostic runs only: the summary sorts every percentile.
            if PipelineWitness.isEnabled,
               let json = try? recorder.summaryJSONLine() {
                NSLog("lyte video flight: %@", json)
            }
        }
    }
}
