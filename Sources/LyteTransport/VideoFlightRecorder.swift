import Foundation

/// Bounded, per-frame timing ledger for the real app delivery path.
///
/// A host timestamp gap identifies source/capture cadence. The matching
/// client-ready gap identifies everything through assembly/sample creation.
/// Queue wait and enqueue duration isolate the app/renderer handoff. Apple
/// renderer metrics close the final decode/display boundary.
public final class VideoFlightRecorder: @unchecked Sendable {
    public enum Provenance: String, Sendable, Equatable, Codable {
        case freshCapture
        case retainedRefinement
    }

    public struct Token: Sendable {
        fileprivate let frame: UInt32
        fileprivate let hostMicroseconds: UInt64
        fileprivate let readyNanoseconds: UInt64
        fileprivate let ordinal: UInt64
        fileprivate let provenance: Provenance
    }

    public struct RendererMetrics: Sendable, Equatable, Codable {
        public var totalFrames: Int
        public var droppedFrames: Int
        public var corruptedFrames: Int
        public var accumulatedDelayMilliseconds: Double

        public init(
            totalFrames: Int,
            droppedFrames: Int,
            corruptedFrames: Int,
            accumulatedDelayMilliseconds: Double
        ) {
            self.totalFrames = totalFrames
            self.droppedFrames = droppedFrames
            self.corruptedFrames = corruptedFrames
            self.accumulatedDelayMilliseconds = accumulatedDelayMilliseconds
        }
    }

    public struct Snapshot: Sendable, Equatable, Codable {
        public var frames: UInt64
        public var freshCaptureFrames: UInt64
        public var retainedRefinementFrames: UInt64
        public var pending: Int
        public var maximumPending: Int
        public var sourceGapP50Milliseconds: Double?
        public var sourceGapP99Milliseconds: Double?
        public var readyGapP50Milliseconds: Double?
        public var readyGapP99Milliseconds: Double?
        public var transitStretchP50Milliseconds: Double?
        public var transitStretchP99Milliseconds: Double?
        public var queueWaitP50Milliseconds: Double?
        public var queueWaitP99Milliseconds: Double?
        public var enqueueP50Milliseconds: Double?
        public var enqueueP99Milliseconds: Double?
        public var sampleBuildP99Milliseconds: Double?
        public var assemblyLockHoldP99Milliseconds: Double?
        public var presentationLatenessP99Milliseconds: Double?
        public var targetDelayMilliseconds: Double?
        public var cadenceStalls: UInt64
        public var rendererNotReady: UInt64
        public var rendererDrops: UInt64
        public var rendererFailures: UInt64
        public var rendererRecoveries: UInt64
        public var rendererMetrics: RendererMetrics?

        public var bottleneck: String {
            if rendererFailures > 0
                || (rendererMetrics?.corruptedFrames ?? 0) > 0 {
                return "renderer failure"
            }
            if (rendererMetrics?.droppedFrames ?? 0) > 0 {
                return "renderer dropped frames"
            }
            if rendererNotReady > 0 {
                return "renderer backpressure"
            }
            if (enqueueP99Milliseconds ?? 0) > 8 {
                return "renderer enqueue"
            }
            if (queueWaitP99Milliseconds ?? 0) > 8 || maximumPending > 2 {
                return "app delivery queue"
            }
            if (transitStretchP99Milliseconds ?? 0) > 8 {
                return "network/assembly"
            }
            if (sourceGapP99Milliseconds ?? 0) > 25 {
                return "host capture/encode"
            }
            return "no measured stall"
        }
    }

    public struct FrameObservation: Sendable, Equatable, Codable {
        public var ordinal: UInt64
        public var frame: UInt32
        public var hostMicroseconds: UInt64
        public var provenance: Provenance
        public var sourceGapMilliseconds: Double?
        public var readyGapMilliseconds: Double?
        public var transitStretchMilliseconds: Double?
        public var cadenceStall: Bool
        public var queueDepth: Int
        public var queueWaitMilliseconds: Double
        public var sampleBuildMilliseconds: Double?
        public var assemblyLockHoldMilliseconds: Double?
        public var rendererReady: Bool
        public var rendererDropped: Bool
        public var rendererFailed: Bool
        public var enqueueMilliseconds: Double
        public var scheduledPresentationMicroseconds: UInt64?
        public var targetDelayMilliseconds: Double?
        public var presentationLatenessMilliseconds: Double?
        public var rendererRecovery: Bool
    }

    private let lock = NSLock()
    private let capacity: Int
    private var ring: [FrameObservation] = []
    private var ringIndex = 0
    private var ordinal: UInt64 = 0
    private var pending = 0
    private var maximumPending = 0
    private var rendererNotReady: UInt64 = 0
    private var rendererDrops: UInt64 = 0
    private var rendererFailures: UInt64 = 0
    private var rendererRecoveries: UInt64 = 0
    private var cadenceStalls: UInt64 = 0
    private var rendererMetrics: RendererMetrics?
    private var freshCaptureFrames: UInt64 = 0
    private var retainedRefinementFrames: UInt64 = 0
    private var previousSubmittedHostMicroseconds: UInt64?
    private var previousHostMicroseconds: UInt64?
    private var previousReadyNanoseconds: UInt64?

    public init(capacity: Int = 360) {
        self.capacity = max(1, capacity)
        ring.reserveCapacity(self.capacity)
    }

    public func frameReady(
        frame: UInt32,
        hostMicroseconds: UInt64,
        nowNanoseconds: UInt64
    ) -> Token {
        lock.lock()
        ordinal &+= 1
        pending += 1
        maximumPending = max(maximumPending, pending)
        let provenance: Provenance =
            previousSubmittedHostMicroseconds == hostMicroseconds
            ? .retainedRefinement : .freshCapture
        previousSubmittedHostMicroseconds = hostMicroseconds
        if provenance == .retainedRefinement {
            retainedRefinementFrames &+= 1
        } else {
            freshCaptureFrames &+= 1
        }
        let token = Token(
            frame: frame,
            hostMicroseconds: hostMicroseconds,
            readyNanoseconds: nowNanoseconds,
            ordinal: ordinal,
            provenance: provenance)
        lock.unlock()
        return token
    }

    /// Returns true once per 60 frames so the owner can sample Apple's
    /// asynchronous renderer-performance metrics without a separate timer.
    public func shouldSampleRenderer(after token: Token) -> Bool {
        token.ordinal == 1 || token.ordinal % 60 == 0
    }

    public func frameEnqueued(
        _ token: Token,
        enqueueStartedNanoseconds: UInt64,
        enqueueFinishedNanoseconds: UInt64,
        rendererReady: Bool,
        rendererFailed: Bool,
        rendererDropped: Bool = false,
        sampleBuildMicroseconds: UInt64? = nil,
        assemblyLockHoldMicroseconds: UInt64? = nil,
        scheduledPresentationMicroseconds: UInt64? = nil,
        targetDelayMicroseconds: UInt64? = nil,
        presentationLatenessMicroseconds: UInt64? = nil,
        rendererRecovery: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }

        let sourceGap = previousHostMicroseconds.map {
            Double(token.hostMicroseconds &- $0) / 1_000
        }
        let readyGap = previousReadyNanoseconds.map {
            Double(token.readyNanoseconds &- $0) / 1e6
        }
        let stretch: Double?
        if token.provenance == .freshCapture, let sourceGap, let readyGap {
            stretch = max(0, readyGap - sourceGap)
        } else {
            stretch = nil
        }
        previousHostMicroseconds = token.hostMicroseconds
        previousReadyNanoseconds = token.readyNanoseconds

        let cadenceStall = (sourceGap ?? 0) > 25
        let observation = FrameObservation(
            ordinal: token.ordinal,
            frame: token.frame,
            hostMicroseconds: token.hostMicroseconds,
            provenance: token.provenance,
            sourceGapMilliseconds: sourceGap,
            readyGapMilliseconds: readyGap,
            transitStretchMilliseconds: stretch,
            cadenceStall: cadenceStall,
            queueDepth: pending,
            queueWaitMilliseconds:
                Double(enqueueStartedNanoseconds &- token.readyNanoseconds) / 1e6,
            sampleBuildMilliseconds: sampleBuildMicroseconds.map {
                Double($0) / 1_000
            },
            assemblyLockHoldMilliseconds: assemblyLockHoldMicroseconds.map {
                Double($0) / 1_000
            },
            rendererReady: rendererReady,
            rendererDropped: rendererDropped,
            rendererFailed: rendererFailed,
            enqueueMilliseconds:
                Double(enqueueFinishedNanoseconds &- enqueueStartedNanoseconds) / 1e6,
            scheduledPresentationMicroseconds: scheduledPresentationMicroseconds,
            targetDelayMilliseconds: targetDelayMicroseconds.map {
                Double($0) / 1_000
            },
            presentationLatenessMilliseconds:
                presentationLatenessMicroseconds.map { Double($0) / 1_000 },
            rendererRecovery: rendererRecovery)
        if ring.count < capacity {
            ring.append(observation)
        } else {
            ring[ringIndex] = observation
            ringIndex = (ringIndex + 1) % capacity
        }
        pending = max(0, pending - 1)
        if cadenceStall { cadenceStalls &+= 1 }
        if !rendererReady { rendererNotReady &+= 1 }
        if rendererDropped { rendererDrops &+= 1 }
        if rendererFailed { rendererFailures &+= 1 }
        if rendererRecovery { rendererRecoveries &+= 1 }
    }

    public func recordRendererMetrics(_ metrics: RendererMetrics) {
        lock.lock()
        rendererMetrics = metrics
        lock.unlock()
    }

    /// Counts a recovery that discarded no already-pending frame. The
    /// triggering incoming frame is rejected by the subsequent await-IDR
    /// policy outcome, so there is otherwise no observation on which to
    /// carry the episode marker.
    public func recordRendererRecovery() {
        lock.lock()
        rendererRecoveries &+= 1
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            frames: ordinal,
            freshCaptureFrames: freshCaptureFrames,
            retainedRefinementFrames: retainedRefinementFrames,
            pending: pending,
            maximumPending: maximumPending,
            sourceGapP50Milliseconds:
                percentile(\.sourceGapMilliseconds, percentile: 50),
            sourceGapP99Milliseconds: percentile(\.sourceGapMilliseconds),
            readyGapP50Milliseconds:
                percentile(\.readyGapMilliseconds, percentile: 50),
            readyGapP99Milliseconds: percentile(\.readyGapMilliseconds),
            transitStretchP50Milliseconds:
                percentile(\.transitStretchMilliseconds, percentile: 50),
            transitStretchP99Milliseconds:
                percentile(\.transitStretchMilliseconds),
            queueWaitP50Milliseconds:
                percentile(\.queueWaitMilliseconds, percentile: 50),
            queueWaitP99Milliseconds: percentile(\.queueWaitMilliseconds),
            enqueueP50Milliseconds:
                percentile(\.enqueueMilliseconds, percentile: 50),
            enqueueP99Milliseconds: percentile(\.enqueueMilliseconds),
            sampleBuildP99Milliseconds: percentile(\.sampleBuildMilliseconds),
            assemblyLockHoldP99Milliseconds:
                percentile(\.assemblyLockHoldMilliseconds),
            presentationLatenessP99Milliseconds:
                percentile(\.presentationLatenessMilliseconds),
            targetDelayMilliseconds: ring.last?.targetDelayMilliseconds,
            cadenceStalls: cadenceStalls,
            rendererNotReady: rendererNotReady,
            rendererDrops: rendererDrops,
            rendererFailures: rendererFailures,
            rendererRecoveries: rendererRecoveries,
            rendererMetrics: rendererMetrics)
    }

    public func recentFrames() -> [FrameObservation] {
        lock.lock()
        defer { lock.unlock() }
        guard ring.count == capacity, ringIndex != 0 else { return ring }
        return Array(ring[ringIndex...]) + Array(ring[..<ringIndex])
    }

    public func summaryJSONLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(snapshot()), as: UTF8.self)
    }

    public func reset() {
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        ringIndex = 0
        ordinal = 0
        pending = 0
        maximumPending = 0
        rendererNotReady = 0
        rendererDrops = 0
        rendererFailures = 0
        rendererRecoveries = 0
        cadenceStalls = 0
        rendererMetrics = nil
        freshCaptureFrames = 0
        retainedRefinementFrames = 0
        previousSubmittedHostMicroseconds = nil
        previousHostMicroseconds = nil
        previousReadyNanoseconds = nil
        lock.unlock()
    }

    private func percentile(
        _ keyPath: KeyPath<FrameObservation, Double?>,
        percentile rank: Int = 99
    ) -> Double? {
        percentile(ring.compactMap { $0[keyPath: keyPath] }, rank)
    }

    private func percentile(
        _ keyPath: KeyPath<FrameObservation, Double>,
        percentile rank: Int = 99
    ) -> Double? {
        percentile(ring.map { $0[keyPath: keyPath] }, rank)
    }

    private func percentile(_ values: [Double], _ percentile: Int) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int(
            ceil(Double(percentile) / 100 * Double(sorted.count))) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }
}
