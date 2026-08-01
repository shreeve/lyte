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
        public var slowShrinkMicroseconds: UInt64

        public init(
            minimumDelayMicroseconds: UInt64 = 15_000,
            maximumDelayMicroseconds: UInt64 = 50_000,
            initialDelayMicroseconds: UInt64 = 20_000,
            excessiveLatenessMicroseconds: UInt64 = 50_000,
            slowShrinkMicroseconds: UInt64 = 100
        ) {
            self.minimumDelayMicroseconds = minimumDelayMicroseconds
            self.maximumDelayMicroseconds = maximumDelayMicroseconds
            self.initialDelayMicroseconds = initialDelayMicroseconds
            self.excessiveLatenessMicroseconds = excessiveLatenessMicroseconds
            self.slowShrinkMicroseconds = slowShrinkMicroseconds
        }
    }

    public struct Decision: Sendable, Equatable {
        public var presentationMicroseconds: UInt64
        public var targetDelayMicroseconds: UInt64
        public var latenessMicroseconds: UInt64
        public var shouldFlush: Bool
    }

    public let config: Config
    public private(set) var targetDelayMicroseconds: UInt64
    private var lastPathDelayMicroseconds: UInt64?
    private var lastSourceCaptureMicroseconds: UInt64?
    private var jitterMicroseconds: Double = 0
    private var recoveryArmed = true

    public init(config: Config = Config()) {
        precondition(config.minimumDelayMicroseconds <= config.initialDelayMicroseconds)
        precondition(config.initialDelayMicroseconds <= config.maximumDelayMicroseconds)
        self.config = config
        self.targetDelayMicroseconds = config.initialDelayMicroseconds
    }

    public mutating func reset() {
        targetDelayMicroseconds = config.initialDelayMicroseconds
        lastPathDelayMicroseconds = nil
        lastSourceCaptureMicroseconds = nil
        jitterMicroseconds = 0
        recoveryArmed = true
    }

    /// Maps one arrival onto the host-clock presentation timeline. Delay
    /// rises immediately on misses/jitter and decays by only 0.1 ms/frame.
    public mutating func schedule(
        mappedCaptureMicroseconds: UInt64,
        arrivalMicroseconds: UInt64,
        sourceCaptureMicroseconds: UInt64? = nil
    ) -> Decision {
        // The host's idle floor and quality ratchet intentionally re-encode
        // retained pixels with their ORIGINAL capture timestamp. Those are
        // dependency-bearing quality refinements, not network-late frames.
        // Scheduling them against the old absolute instant creates a false
        // lateness episode and an IDR feedback loop. Repeats ride from their
        // arrival while retaining the current playout depth; they contribute
        // no path-jitter evidence because no new capture occurred.
        let sourceCapture = sourceCaptureMicroseconds
            ?? mappedCaptureMicroseconds
        if lastSourceCaptureMicroseconds == sourceCapture {
            return Decision(
                presentationMicroseconds:
                    arrivalMicroseconds &+ targetDelayMicroseconds,
                targetDelayMicroseconds: targetDelayMicroseconds,
                latenessMicroseconds: 0,
                shouldFlush: false)
        }
        lastSourceCaptureMicroseconds = sourceCapture

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
            let growth = max(
                lateness,
                UInt64(jitterMicroseconds.rounded(.up)))
            targetDelayMicroseconds = min(
                config.maximumDelayMicroseconds,
                targetDelayMicroseconds &+ growth)
        } else if targetDelayMicroseconds > config.minimumDelayMicroseconds {
            targetDelayMicroseconds = max(
                config.minimumDelayMicroseconds,
                targetDelayMicroseconds - min(
                    config.slowShrinkMicroseconds,
                    targetDelayMicroseconds - config.minimumDelayMicroseconds))
        }

        let scheduled = mappedCaptureMicroseconds &+ targetDelayMicroseconds
        let excessive = lateness > config.excessiveLatenessMicroseconds
        let shouldFlush = excessive && recoveryArmed
        if shouldFlush {
            recoveryArmed = false
        } else if !excessive {
            recoveryArmed = true
        }
        return Decision(
            presentationMicroseconds: max(scheduled, arrivalMicroseconds),
            targetDelayMicroseconds: targetDelayMicroseconds,
            latenessMicroseconds: lateness,
            shouldFlush: shouldFlush)
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
        sourceCaptureMicroseconds: UInt64? = nil
    ) -> AdaptiveVideoPlayout.Decision {
        lock.lock()
        defer { lock.unlock() }
        return policy.schedule(
            mappedCaptureMicroseconds: mappedCaptureMicroseconds,
            arrivalMicroseconds: arrivalMicroseconds,
            sourceCaptureMicroseconds: sourceCaptureMicroseconds)
    }

    public func reset() {
        lock.lock(); policy.reset(); lock.unlock()
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
            guard isRandomAccess else {
                return Outcome(
                    accepted: false,
                    recoveryRequested: false,
                    discarded: [incoming])
            }
            awaitingRandomAccess = false
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

    /// Renderer failure or adaptive excessive-lateness verdict.
    public mutating func failEpisode() -> Outcome {
        let discarded = entries
        entries.removeAll(keepingCapacity: true)
        let startsRecovery = !awaitingRandomAccess
        awaitingRandomAccess = true
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
        return discarded
    }
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
