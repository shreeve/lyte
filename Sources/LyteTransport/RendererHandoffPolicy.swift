import CoreMedia
import Foundation
import LyteWire

// The renderer-side queue policies that survived the metronome era:
// the bounded episode handoff and the recovery flush barrier. The
// playout policy itself is VideoBeatConductor (the Conductor's video
// instrument) — the adaptive playout retired with it.

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
