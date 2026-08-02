import CoreMedia
import Foundation
import LyteWire

/// Pure adaptive video playout policy. All coordinates are client host-clock
/// microseconds; the caller owns clock mapping and renderer side effects.
public struct AdaptiveVideoPlayout: Sendable {
    public struct Config: Sendable, Equatable {
        public var minimumDelayMicroseconds: UInt64
        public var maximumDelayMicroseconds: UInt64
        public var initialDelayMicroseconds: UInt64
        public var excessiveLatenessMicroseconds: UInt64
        public var maximumFreshBurstDebtMicroseconds: UInt64
        public var freshDebtRearmStableFrames: Int
        public var slowShrinkMicroseconds: UInt64
        public var shrinkHoldFrames: Int
        public var shrinkCadenceFrames: Int

        public init(
            minimumDelayMicroseconds: UInt64 = 15_000,
            maximumDelayMicroseconds: UInt64 = 50_000,
            initialDelayMicroseconds: UInt64 = 20_000,
            excessiveLatenessMicroseconds: UInt64 = 50_000,
            maximumFreshBurstDebtMicroseconds: UInt64 = 200_000,
            freshDebtRearmStableFrames: Int = 30,
            slowShrinkMicroseconds: UInt64 = 100,
            shrinkHoldFrames: Int = 600,
            shrinkCadenceFrames: Int = 60
        ) {
            self.minimumDelayMicroseconds = minimumDelayMicroseconds
            self.maximumDelayMicroseconds = maximumDelayMicroseconds
            self.initialDelayMicroseconds = initialDelayMicroseconds
            self.excessiveLatenessMicroseconds = excessiveLatenessMicroseconds
            self.maximumFreshBurstDebtMicroseconds =
                maximumFreshBurstDebtMicroseconds
            self.freshDebtRearmStableFrames = freshDebtRearmStableFrames
            self.slowShrinkMicroseconds = slowShrinkMicroseconds
            self.shrinkHoldFrames = shrinkHoldFrames
            self.shrinkCadenceFrames = shrinkCadenceFrames
        }
    }

    public struct Decision: Sendable, Equatable {
        public var presentationMicroseconds: UInt64
        public var targetDelayMicroseconds: UInt64
        public var latenessMicroseconds: UInt64
        public var shouldFlush: Bool
    }

    public private(set) var config: Config
    public private(set) var targetDelayMicroseconds: UInt64
    private var lastPathDelayMicroseconds: UInt64?
    private var lastSourceCaptureMicroseconds: UInt64?
    private var lastPresentationMicroseconds: UInt64?
    private var lastFreshSourceMicroseconds: UInt64?
    private var lastFreshArrivalMicroseconds: UInt64?
    private var freshBurstDebtMicroseconds: UInt64 = 0
    private var lastFrameWasRetained = false
    private var jitterMicroseconds: Double = 0
    private var debtRecoveryArmed = true
    private var stableFreshFramesAfterDebtRecovery = 0
    private var stableFramesSinceLateness = 0

    public init(config: Config = Config()) {
        precondition(config.minimumDelayMicroseconds <= config.initialDelayMicroseconds)
        precondition(config.initialDelayMicroseconds <= config.maximumDelayMicroseconds)
        precondition(config.freshDebtRearmStableFrames > 0)
        precondition(config.shrinkHoldFrames >= 0)
        precondition(config.shrinkCadenceFrames > 0)
        self.config = config
        self.targetDelayMicroseconds = config.initialDelayMicroseconds
    }

    /// Moves the cushion ceiling mid-flight (the Settings slider is
    /// live). The floor and initial delay recompute from stock so a
    /// ceiling below them drags them down and a later raise restores
    /// them. Lowering clamps the learned delay immediately — the next
    /// frame schedules tighter; raising only grants headroom (delay
    /// still grows solely on measured lateness), so sliding up never
    /// adds latency by itself.
    public mutating func updateDelayCeiling(
        maximumDelayMicroseconds cap: UInt64
    ) {
        let stock = Config()
        config.maximumDelayMicroseconds = cap
        config.minimumDelayMicroseconds =
            min(stock.minimumDelayMicroseconds, cap)
        config.initialDelayMicroseconds =
            min(stock.initialDelayMicroseconds, cap)
        targetDelayMicroseconds = min(
            max(targetDelayMicroseconds,
                config.minimumDelayMicroseconds),
            cap)
    }

    public mutating func reset() {
        targetDelayMicroseconds = config.initialDelayMicroseconds
        lastPathDelayMicroseconds = nil
        lastSourceCaptureMicroseconds = nil
        lastPresentationMicroseconds = nil
        lastFreshSourceMicroseconds = nil
        lastFreshArrivalMicroseconds = nil
        freshBurstDebtMicroseconds = 0
        lastFrameWasRetained = false
        jitterMicroseconds = 0
        debtRecoveryArmed = true
        stableFreshFramesAfterDebtRecovery = 0
        stableFramesSinceLateness = 0
    }

    /// Maps one arrival onto the host-clock presentation timeline. Delay
    /// rises immediately on misses/jitter, then holds long enough to cover
    /// recurring path tails before decaying in sparse 0.1 ms steps.
    public mutating func schedule(
        mappedCaptureMicroseconds: UInt64,
        arrivalMicroseconds: UInt64,
        sourceCaptureMicroseconds: UInt64? = nil,
        isRandomAccess: Bool = false
    ) -> Decision {
        // `isRandomAccess` is intentionally not a close signal. The handoff
        // closes recovery only after AVFoundation actually accepts the IRAP.
        // The host's idle floor and quality ratchet intentionally re-encode
        // retained pixels with their ORIGINAL capture timestamp. Those are
        // dependency-bearing quality refinements, not network-late frames.
        // Scheduling them against the old absolute instant creates a false
        // lateness episode and an IDR feedback loop. Repeats ride from their
        // arrival while retaining the current playout depth; they contribute
        // no path-jitter evidence because no new capture occurred.
        let sourceCapture = sourceCaptureMicroseconds
            ?? mappedCaptureMicroseconds
        let previousSourceCapture = lastSourceCaptureMicroseconds
        if previousSourceCapture == sourceCapture {
            lastFrameWasRetained = true
            let proposed = arrivalMicroseconds &+ targetDelayMicroseconds
            let presentation = max(
                proposed, (lastPresentationMicroseconds ?? 0) &+ 1)
            lastPresentationMicroseconds = presentation
            return Decision(
                presentationMicroseconds: presentation,
                targetDelayMicroseconds: targetDelayMicroseconds,
                latenessMicroseconds: 0,
                shouldFlush: false)
        }
        lastSourceCaptureMicroseconds = sourceCapture

        if !lastFrameWasRetained,
           let previousFreshSource = lastFreshSourceMicroseconds,
           let previousFreshArrival = lastFreshArrivalMicroseconds {
            let sourceStep = sourceCapture > previousFreshSource
                ? sourceCapture - previousFreshSource : 0
            let arrivalStep = arrivalMicroseconds > previousFreshArrival
                ? arrivalMicroseconds - previousFreshArrival : 0
            // Debt is a genuinely compressed catch-up train, not every
            // harmless early-jitter sample. Normal cadence ends the train.
            if sourceStep > 0, arrivalStep < sourceStep / 2 {
                freshBurstDebtMicroseconds &+= sourceStep - arrivalStep
                if !debtRecoveryArmed {
                    stableFreshFramesAfterDebtRecovery = 0
                }
            } else {
                freshBurstDebtMicroseconds = 0
                if !debtRecoveryArmed {
                    stableFreshFramesAfterDebtRecovery += 1
                    if stableFreshFramesAfterDebtRecovery
                        >= config.freshDebtRearmStableFrames {
                        debtRecoveryArmed = true
                        stableFreshFramesAfterDebtRecovery = 0
                    }
                }
            }
        } else {
            freshBurstDebtMicroseconds = 0
        }
        lastFreshSourceMicroseconds = sourceCapture
        lastFreshArrivalMicroseconds = arrivalMicroseconds
        lastFrameWasRetained = false

        let pathDelay = arrivalMicroseconds >= mappedCaptureMicroseconds
            ? arrivalMicroseconds - mappedCaptureMicroseconds : 0
        if let previous = lastPathDelayMicroseconds {
            let delta = Double(previous > pathDelay
                ? previous - pathDelay : pathDelay - previous)
            jitterMicroseconds += 0.25 * (delta - jitterMicroseconds)
        }
        lastPathDelayMicroseconds = pathDelay

        let oldPresentation = mappedCaptureMicroseconds &+ targetDelayMicroseconds
        let lateness = arrivalMicroseconds > oldPresentation
            ? arrivalMicroseconds - oldPresentation : 0
        if lateness > 0 {
            stableFramesSinceLateness = 0
            let growth = max(
                lateness,
                UInt64(jitterMicroseconds.rounded(.up)))
            targetDelayMicroseconds = min(
                config.maximumDelayMicroseconds,
                targetDelayMicroseconds &+ growth)
        } else {
            stableFramesSinceLateness &+= 1
        }
        if lateness == 0,
           stableFramesSinceLateness > config.shrinkHoldFrames,
           (stableFramesSinceLateness - config.shrinkHoldFrames)
               % config.shrinkCadenceFrames == 0,
           targetDelayMicroseconds > config.minimumDelayMicroseconds {
            targetDelayMicroseconds = max(
                config.minimumDelayMicroseconds,
                targetDelayMicroseconds - min(
                    config.slowShrinkMicroseconds,
                    targetDelayMicroseconds - config.minimumDelayMicroseconds))
        }

        // `targetDelay` already grew by the measured lateness above. Rebasing
        // a late frame at arrival + that newly enlarged delay counts the same
        // path excursion twice, turning a bounded Wi-Fi burst into a second
        // full playout stall. Keep the source timeline and clamp only to
        // "not before this frame exists". A blackout catch-up train is still
        // bounded by maximumPresentation and the debt recovery below.
        var scheduled = max(
            mappedCaptureMicroseconds &+ targetDelayMicroseconds,
            arrivalMicroseconds)
        if let previousPresentation = lastPresentationMicroseconds {
            scheduled = max(scheduled, previousPresentation &+ 1)
        }
        let maximumPresentation = arrivalMicroseconds
            &+ config.maximumDelayMicroseconds
        let excessiveDebt =
            freshBurstDebtMicroseconds
                > config.maximumFreshBurstDebtMicroseconds
        let shouldFlush = excessiveDebt && debtRecoveryArmed
        if shouldFlush {
            debtRecoveryArmed = false
        }
        if scheduled > maximumPresentation {
            // Frames in the debt episode are discarded by await-IDR. Keep
            // every accepted PTS inside the advertised horizon. Equal PTS
            // deliberately coalesce an ordinary compressed burst after
            // decode; only a truly stale 200 ms chain starts recovery.
            scheduled = maximumPresentation
        }
        lastPresentationMicroseconds = scheduled
        return Decision(
            presentationMicroseconds: scheduled,
            targetDelayMicroseconds: targetDelayMicroseconds,
            latenessMicroseconds: lateness,
            shouldFlush: shouldFlush)
    }

    public mutating func noteRandomAccessEnqueued() {
        lastPathDelayMicroseconds = nil
        lastSourceCaptureMicroseconds = nil
        // A decoder reset starts a new dependency episode, not a new
        // CoreMedia timebase. Preserve the presentation floor so the IRAP
        // and its successors can never regress across a renderer flush.
        lastFreshSourceMicroseconds = nil
        lastFreshArrivalMicroseconds = nil
        freshBurstDebtMicroseconds = 0
        lastFrameWasRetained = false
        jitterMicroseconds = 0
        // A debt-triggered episode does not re-arm merely because its IDR
        // was enqueued while the same compressed blackout burst continues.
        // Thirty cadence-stable fresh frames prove the collapse has ended.
        if debtRecoveryArmed {
            stableFreshFramesAfterDebtRecovery = 0
        }
    }
}

public final class AdaptiveVideoPlayoutController: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: AdaptiveVideoPlayout

    public init(config: AdaptiveVideoPlayout.Config = .init()) {
        policy = AdaptiveVideoPlayout(config: config)
    }

    public func schedule(
        mappedCaptureMicroseconds: UInt64,
        arrivalMicroseconds: UInt64,
        sourceCaptureMicroseconds: UInt64? = nil,
        isRandomAccess: Bool = false
    ) -> AdaptiveVideoPlayout.Decision {
        lock.lock()
        defer { lock.unlock() }
        return policy.schedule(
            mappedCaptureMicroseconds: mappedCaptureMicroseconds,
            arrivalMicroseconds: arrivalMicroseconds,
            sourceCaptureMicroseconds: sourceCaptureMicroseconds,
            isRandomAccess: isRandomAccess)
    }

    public func reset() {
        lock.lock(); policy.reset(); lock.unlock()
    }

    public func updateDelayCeiling(maximumDelayMicroseconds: UInt64) {
        lock.lock()
        policy.updateDelayCeiling(
            maximumDelayMicroseconds: maximumDelayMicroseconds)
        lock.unlock()
    }

    public func noteRandomAccessEnqueued() {
        lock.lock(); policy.noteRandomAccessEnqueued(); lock.unlock()
    }
}

/// Pure bounded queue policy behind the AV renderer handoff. Inter frames are
/// never discarded individually: pressure/failure discards the whole queued
/// decode episode, enters "await IDR", and asks for one recovery. The first
/// IDR starts a new episode.
public struct BoundedRendererHandoff<Element: Sendable>: Sendable {
    public struct Config: Sendable, Equatable {
        public var capacity: Int
        public var deadlineMicroseconds: UInt64

        public init(capacity: Int = 4, deadlineMicroseconds: UInt64 = 50_000) {
            precondition(capacity > 0)
            self.capacity = capacity
            self.deadlineMicroseconds = deadlineMicroseconds
        }
    }

    public struct Entry: Sendable {
        public var element: Element
        public var isRandomAccess: Bool
        public var submittedMicroseconds: UInt64
    }

    public struct Outcome: Sendable {
        public var accepted: Bool
        public var recoveryRequested: Bool
        public var discarded: [Entry]
    }

    public let config: Config
    public private(set) var awaitingRandomAccess = false
    public private(set) var randomAccessPending = false
    private var entries: [Entry] = []

    public init(config: Config = Config()) {
        self.config = config
        entries.reserveCapacity(config.capacity)
    }

    public var count: Int { entries.count }

    public mutating func offer(
        _ element: Element,
        isRandomAccess: Bool,
        nowMicroseconds: UInt64
    ) -> Outcome {
        let incoming = Entry(
            element: element,
            isRandomAccess: isRandomAccess,
            submittedMicroseconds: nowMicroseconds)
        if awaitingRandomAccess {
            guard !randomAccessPending else {
                return Outcome(
                    accepted: false,
                    recoveryRequested: false,
                    discarded: [incoming])
            }
            guard isRandomAccess else {
                return Outcome(
                    accepted: false,
                    recoveryRequested: false,
                    discarded: [incoming])
            }
            randomAccessPending = true
            entries.append(incoming)
            return Outcome(
                accepted: true, recoveryRequested: false, discarded: [])
        }

        let expired = entries.first.map {
            nowMicroseconds &- $0.submittedMicroseconds
                >= config.deadlineMicroseconds
        } ?? false
        if entries.count >= config.capacity || expired {
            var discarded = entries
            entries.removeAll(keepingCapacity: true)
            if isRandomAccess {
                entries.append(incoming)
            } else {
                discarded.append(incoming)
                awaitingRandomAccess = true
            }
            return Outcome(
                accepted: isRandomAccess,
                recoveryRequested: true,
                discarded: discarded)
        }

        entries.append(incoming)
        return Outcome(
            accepted: true, recoveryRequested: false, discarded: [])
    }

    public mutating func popReady() -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }

    /// Closes await-IDR only after the accepted random-access sample was
    /// actually handed to AVFoundation. Merely queueing it is not enough.
    public mutating func noteRandomAccessEnqueued() {
        guard awaitingRandomAccess, randomAccessPending else { return }
        awaitingRandomAccess = false
        randomAccessPending = false
    }

    /// Renderer failure or adaptive excessive-lateness verdict.
    public mutating func failEpisode() -> Outcome {
        let discarded = entries
        entries.removeAll(keepingCapacity: true)
        let startsRecovery = !awaitingRandomAccess
        awaitingRandomAccess = true
        randomAccessPending = false
        return Outcome(
            accepted: false,
            recoveryRequested: startsRecovery,
            discarded: discarded)
    }

    public mutating func expire(nowMicroseconds: UInt64) -> Outcome {
        guard let first = entries.first,
              nowMicroseconds &- first.submittedMicroseconds
                >= config.deadlineMicroseconds else {
            return Outcome(
                accepted: false,
                recoveryRequested: false,
                discarded: [])
        }
        return failEpisode()
    }

    public mutating func reset() -> [Entry] {
        let discarded = entries
        entries.removeAll(keepingCapacity: true)
        awaitingRandomAccess = false
        randomAccessPending = false
        return discarded
    }
}

/// Pure state seam for AVSampleBufferVideoRenderer's asynchronous recovery
/// flush. No compressed sample may dequeue until the completion callback.
public struct RendererRecoveryFlushBarrier: Sendable, Equatable {
    public private(set) var isFlushInProgress = false

    public init() {}

    @discardableResult
    public mutating func begin() -> Bool {
        guard !isFlushInProgress else { return false }
        isFlushInProgress = true
        return true
    }

    public mutating func complete() {
        isFlushInProgress = false
    }

    public mutating func reset() {
        isFlushInProgress = false
    }

    public var mayEnqueue: Bool { !isFlushInProgress }
}

public enum VideoSampleTiming {
    public static func attachBuildTelemetry(
        to sample: CMSampleBuffer,
        sampleBuildMicroseconds: UInt64,
        assemblyLockHoldMicroseconds: UInt64
    ) {
        let buildKey = "org.lyte.video.sample-build-us" as CFString
        let lockKey = "org.lyte.video.assembly-lock-us" as CFString
        CMSetAttachment(
            sample, key: buildKey,
            value: NSNumber(value: sampleBuildMicroseconds),
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        CMSetAttachment(
            sample, key: lockKey,
            value: NSNumber(value: assemblyLockHoldMicroseconds),
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
    }

    public static func buildTelemetry(
        from sample: CMSampleBuffer
    ) -> VideoFrameBuildTelemetry? {
        let buildKey = "org.lyte.video.sample-build-us" as CFString
        let lockKey = "org.lyte.video.assembly-lock-us" as CFString
        guard let build = CMGetAttachment(
            sample, key: buildKey, attachmentModeOut: nil) as? NSNumber,
              let hold = CMGetAttachment(
                sample, key: lockKey, attachmentModeOut: nil) as? NSNumber
        else { return nil }
        return VideoFrameBuildTelemetry(
            frame: 0,
            assemblyLockHoldMicroseconds: hold.uint64Value,
            sampleBuildMicroseconds: build.uint64Value)
    }

    /// Re-stamps a ready sample into the local CM host-clock domain.
    public static func retimed(
        _ sample: CMSampleBuffer,
        presentationMicroseconds: UInt64
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: Int64(bitPattern: presentationMicroseconds),
                timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }
}
