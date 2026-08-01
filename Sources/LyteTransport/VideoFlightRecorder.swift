import Foundation

/// Bounded, per-frame timing ledger for the real app delivery path.
///
/// A host timestamp gap identifies source/capture cadence. The matching
/// client-ready gap identifies everything through assembly/sample creation.
/// Queue wait and enqueue duration isolate the app/renderer handoff. Apple
/// renderer metrics close the final decode/display boundary.
public final class VideoFlightRecorder: @unchecked Sendable {
    public struct Token: Sendable {
        fileprivate let frame: UInt32
        fileprivate let hostMicroseconds: UInt64
        fileprivate let readyNanoseconds: UInt64
        fileprivate let ordinal: UInt64
    }

    public struct RendererMetrics: Sendable, Equatable {
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

    public struct Snapshot: Sendable, Equatable {
        public var frames: UInt64
        public var pending: Int
        public var maximumPending: Int
        public var sourceGapP99Milliseconds: Double?
        public var readyGapP99Milliseconds: Double?
        public var transitStretchP99Milliseconds: Double?
        public var queueWaitP99Milliseconds: Double?
        public var enqueueP99Milliseconds: Double?
        public var rendererNotReady: UInt64
        public var rendererFailures: UInt64
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

    private struct Observation {
        var sourceGapMilliseconds: Double?
        var readyGapMilliseconds: Double?
        var transitStretchMilliseconds: Double?
        var queueWaitMilliseconds: Double
        var enqueueMilliseconds: Double
    }

    private let lock = NSLock()
    private let capacity: Int
    private var ring: [Observation] = []
    private var ringIndex = 0
    private var ordinal: UInt64 = 0
    private var pending = 0
    private var maximumPending = 0
    private var rendererNotReady: UInt64 = 0
    private var rendererFailures: UInt64 = 0
    private var rendererMetrics: RendererMetrics?
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
        let token = Token(
            frame: frame,
            hostMicroseconds: hostMicroseconds,
            readyNanoseconds: nowNanoseconds,
            ordinal: ordinal)
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
        rendererFailed: Bool
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
        if let sourceGap, let readyGap {
            stretch = max(0, readyGap - sourceGap)
        } else {
            stretch = nil
        }
        previousHostMicroseconds = token.hostMicroseconds
        previousReadyNanoseconds = token.readyNanoseconds

        let observation = Observation(
            sourceGapMilliseconds: sourceGap,
            readyGapMilliseconds: readyGap,
            transitStretchMilliseconds: stretch,
            queueWaitMilliseconds:
                Double(enqueueStartedNanoseconds &- token.readyNanoseconds) / 1e6,
            enqueueMilliseconds:
                Double(enqueueFinishedNanoseconds &- enqueueStartedNanoseconds) / 1e6)
        if ring.count < capacity {
            ring.append(observation)
        } else {
            ring[ringIndex] = observation
            ringIndex = (ringIndex + 1) % capacity
        }
        pending = max(0, pending - 1)
        if !rendererReady { rendererNotReady &+= 1 }
        if rendererFailed { rendererFailures &+= 1 }
    }

    public func recordRendererMetrics(_ metrics: RendererMetrics) {
        lock.lock()
        rendererMetrics = metrics
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            frames: ordinal,
            pending: pending,
            maximumPending: maximumPending,
            sourceGapP99Milliseconds: percentile(\.sourceGapMilliseconds),
            readyGapP99Milliseconds: percentile(\.readyGapMilliseconds),
            transitStretchP99Milliseconds:
                percentile(\.transitStretchMilliseconds),
            queueWaitP99Milliseconds: percentile(\.queueWaitMilliseconds),
            enqueueP99Milliseconds: percentile(\.enqueueMilliseconds),
            rendererNotReady: rendererNotReady,
            rendererFailures: rendererFailures,
            rendererMetrics: rendererMetrics)
    }

    private func percentile(
        _ keyPath: KeyPath<Observation, Double?>
    ) -> Double? {
        percentile(ring.compactMap { $0[keyPath: keyPath] })
    }

    private func percentile(
        _ keyPath: KeyPath<Observation, Double>
    ) -> Double? {
        percentile(ring.map { $0[keyPath: keyPath] })
    }

    private func percentile(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, (sorted.count * 99) / 100)]
    }
}
