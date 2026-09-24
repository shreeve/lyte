// LyteVideoPipeline: video datagrams → VideoAssembler → VideoRenderFactory
// → CMSampleBuffer → one VideoSink. Presentation timing is the sink
// owner's; frame order is the assembler's guarantee. Damage leaves through
// `onFecImpossible` and `onRepairSignal`.
//
// Assembly and the books are confined by `lock`. Sample construction runs
// on the serial `sampleQueue`, which alone touches the factory. Callbacks
// never run under `lock`.

import LyteCore
import CoreMedia
import Dispatch
import Foundation
import LyteWire

/// Render-path counters, snapshotted for the CLI's per-frame stats.
public struct VideoPipelineStats: Sendable {
    /// DecodeUnits emitted by the assembler (byte-exact frames).
    public var framesDecoded: UInt64 = 0
    /// Frames the assembler gave up on (holdback, stale, corrupt).
    public var framesSkipped: UInt64 = 0
    /// Sample buffers delivered to the sink.
    public var samplesDelivered: UInt64 = 0
    /// DecodeUnits withheld pre-bootstrap (P-frame before the first IDR).
    public var samplesWithheld: UInt64 = 0
    /// CMSampleBuffer construction failures (CoreMedia refused).
    public var sampleFailures: UInt64 = 0
    /// CoreMedia sample construction on the sample queue, µs.
    public var sampleBuildMicroseconds = Histogram<UInt64>(
        capacity: 360, retention: .rolling)
    /// Lock hold for an ingest that completed a frame (excludes CoreMedia).
    public var assemblyLockHoldMicroseconds = Histogram<UInt64>(
        capacity: 360, retention: .rolling)
    /// fecImpossible verdicts (each also fired the seam callback).
    public var fecImpossibleCount: UInt64 = 0
    /// Groups evicted undecoded (stale or capacity).
    public var evictions: UInt64 = 0
    /// Shards the assembler dropped (duplicates, malformed, stale).
    public var shardsDropped: UInt64 = 0
    /// Fresh-seq repair shards slotted into tracked groups.
    public var repairShardsAccepted: UInt64 = 0
    /// Reliable 0x15 idle frames rendered through the shared factory.
    public var reliableFramesRendered: UInt64 = 0
    /// Reliable frames the datagram path had already delivered.
    public var reliableFramesDeduplicated: UInt64 = 0
    /// Client µs from the first ingested video datagram to the first
    /// delivered sample.
    public var firstSampleMicroseconds: Int64?
    /// Receive-side quality over the last ~5 s; nil until a frame has
    /// decoded inside the window.
    public var quality: VideoQualitySnapshot?
}

public struct VideoFrameBuildTelemetry: Sendable, Equatable {
    public var frame: UInt32
    public var assemblyLockHoldMicroseconds: UInt64
    public var sampleBuildMicroseconds: UInt64
}

/// Incoming video quality derived from the client's own books.
public struct VideoQualitySnapshot: Sendable {
    /// Decoded frames per second over the window.
    public var framesPerSecond: Double
    /// Decoded video bits per second over the window.
    public var bitsPerSecond: Int
    /// Frame-size percentiles over the window, bytes.
    public var frameBytesP50: Int
    public var frameBytesP95: Int
    public var frameBytesMax: Int
}

/// What became of one reliable-channel frame handed to the pipeline.
public enum ReliableFrameOutcome: Equatable, Sendable {
    /// Rendered through the shared factory and delivered to the sink.
    case rendered
    /// The datagram path already delivered this frame number or newer.
    case deduplicated
    /// No format description exists yet (a P-frame before any IDR).
    case withheld
    /// CoreMedia refused the sample (counted in `sampleFailures`).
    case failed
}

public final class LyteVideoPipeline: @unchecked Sendable {
    public let channel: ChannelId

    private let lock = NSLock()
    private var assembler: VideoAssembler
    private let factory = VideoRenderFactory()
    private let sampleQueue = DispatchQueue(
        label: "lyte.video.sample-build", qos: .userInteractive)
    private let asynchronousSampleBuild: Bool
    private let nowNanoseconds: @Sendable () -> UInt64
    private var stats = VideoPipelineStats()
    private var firstIngest: ClientTimestamp?
    /// Confined by `lock`.
    private var qualityWindow = VideoQualityWindow()
    /// The newest frame number delivered by either path; idle-frame
    /// dedupe reference.
    private var newestDeliveredFrame: FrameNumber?

    private let sink: any VideoSink
    private let onFecImpossible: (@Sendable (FrameNumber, _ presumedLostDataShards: Int, _ bestCaseParityShards: Int) -> Void)?
    /// The NackPolicy's feed.
    private let onRepairSignal: (@Sendable (VideoRepairSignal, ClientTimestamp) -> Void)?

    private var evictionTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - sink: receives one ready sample per rendered frame on the sample
    ///     worker. The owner assigns local presentation time.
    ///   - onFecImpossible: fired once per frame the assembler writes off
    ///     as unrecoverable from plausible arrivals.
    ///   - onRepairSignal: the NackPolicy's event feed.
    ///   - nowNanoseconds: the shell's monotonic clock. All convenience
    ///     timestamps and lock/build telemetry derive from this one source.
    public init(
        channel: ChannelId = .videoActive,
        config: VideoAssemblerConfig = VideoAssemblerConfig(),
        asynchronousSampleBuild: Bool = false,
        nowNanoseconds: @escaping @Sendable () -> UInt64,
        sink: any VideoSink,
        onFecImpossible: (@Sendable (FrameNumber, _ presumedLostDataShards: Int, _ bestCaseParityShards: Int) -> Void)? = nil,
        onRepairSignal: (@Sendable (VideoRepairSignal, ClientTimestamp) -> Void)? = nil
    ) {
        self.channel = channel
        self.assembler = VideoAssembler(channel: channel, config: config)
        self.asynchronousSampleBuild = asynchronousSampleBuild
        self.nowNanoseconds = nowNanoseconds
        self.sink = sink
        self.onFecImpossible = onFecImpossible
        self.onRepairSignal = onRepairSignal
    }

    /// Starts the stale-group eviction timer. Idempotent.
    public func start(evictionIntervalMilliseconds: Int = 50) {
        lock.lock()
        defer { lock.unlock() }
        guard evictionTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(
            deadline: .now() + .milliseconds(evictionIntervalMilliseconds),
            repeating: .milliseconds(evictionIntervalMilliseconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.tick(now: self.currentTimestamp())
        }
        timer.resume()
        evictionTimer = timer
    }

    public func stop() {
        lock.lock()
        let timer = evictionTimer
        evictionTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    /// Feeds one accepted datagram; other channels pass through untouched.
    public func ingest(envelope: Envelope, payload: [UInt8]) {
        ingest(envelope: envelope, payload: payload, now: currentTimestamp())
    }

    public func ingest(envelope: Envelope, payload: [UInt8], now: ClientTimestamp) {
        guard envelope.channel == channel else { return }
        let lockStarted = nowNanoseconds()
        lock.lock()
        if firstIngest == nil { firstIngest = now }
        let events = assembler.ingest(envelope: envelope, payload: payload, now: now)
        let lockHeld = (nowNanoseconds() &- lockStarted) / 1_000
        let actions = process(events, now: now, assemblyLockHoldMicroseconds: lockHeld)
        lock.unlock()
        dispatch(actions)
    }

    /// Renders a reliable 0x15 idle frame through the same factory, so it
    /// inherits parameter sets and format continuity. Deduplicates
    /// (wrap-aware) against the newest delivered frame: the idle frame
    /// names the number it last rode the datagram path with.
    public func ingestReliableFrame(
        frame: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        annexB: [UInt8]
    ) -> ReliableFrameOutcome {
        let now = currentTimestamp()
        lock.lock()
        if let newest = newestDeliveredFrame,
           Int32(bitPattern: frame.rawValue &- newest.rawValue) <= 0 {
            stats.reliableFramesDeduplicated += 1
            lock.unlock()
            return .deduplicated
        }
        let unit = DecodeUnit(
            frameNumber: frame,
            timestamp: HostTimestamp(
                microseconds: captureTimestampMicroseconds),
            isIDR: AnnexBCheck.containsIrap(annexB),
            annexB: annexB
        )
        lock.unlock()
        var sample: CMSampleBuffer?
        var outcome: ReliableFrameOutcome = .failed
        var buildMicroseconds: UInt64 = 0
        sampleQueue.sync {
            let started = nowNanoseconds()
            do {
                sample = try factory.makeSampleBuffer(from: unit)
                outcome = sample == nil ? .withheld : .rendered
            } catch {
                outcome = .failed
            }
            let elapsed = (nowNanoseconds() &- started) / 1_000
            buildMicroseconds = elapsed
            lock.lock()
            stats.sampleBuildMicroseconds.record(elapsed)
            if sample != nil {
                stats.framesDecoded += 1
                recordQuality(bytes: annexB.count, now: now)
                stats.reliableFramesRendered += 1
                stats.samplesDelivered += 1
                newestDeliveredFrame = frame
            } else if outcome == .withheld {
                stats.samplesWithheld += 1
            } else {
                stats.sampleFailures += 1
            }
            lock.unlock()
        }
        if let sample {
            VideoSampleTiming.attachBuildTelemetry(
                to: sample,
                sampleBuildMicroseconds: buildMicroseconds,
                assemblyLockHoldMicroseconds: 0)
            sink.submit(sample: sample, unit: unit)
        }
        return outcome
    }

    /// Assembler eviction and holdback expiry.
    public func tick(now: ClientTimestamp) {
        lock.lock()
        let events = assembler.evictStale(now: now)
        let actions = process(events, now: now, assemblyLockHoldMicroseconds: 0)
        lock.unlock()
        dispatch(actions)
    }

    public func snapshotStats() -> VideoPipelineStats {
        snapshotStats(now: currentTimestamp())
    }

    public func snapshotStats(now: ClientTimestamp) -> VideoPipelineStats {
        lock.lock()
        defer { lock.unlock() }
        var out = stats
        out.quality = qualityWindow.snapshot(now: now)
        return out
    }

    /// Runs under `lock`.
    private func recordQuality(bytes: Int, now: ClientTimestamp) {
        qualityWindow.record(bytes: bytes, now: now)
    }

    // MARK: - Interior

    private enum Action {
        case buildSample(DecodeUnit, ClientTimestamp, UInt64)
        case fecImpossible(FrameNumber, presumedLostDataShards: Int, bestCaseParityShards: Int)
        case repairSignal(VideoRepairSignal, ClientTimestamp)
    }

    /// Turns assembler events into stats and deferred actions. Runs
    /// under the lock; the actions execute after release.
    private func process(
        _ events: [VideoAssemblerEvent], now: ClientTimestamp,
        assemblyLockHoldMicroseconds: UInt64
    ) -> [Action] {
        var actions: [Action] = []
        for event in events {
            switch event {
            case .decoded(let unit):
                PipelineWitness.record("assemblyCompleted", fields: [
                    "frame": String(unit.frameNumber.rawValue),
                    "captureMicroseconds": String(
                        unit.timestamp.microseconds),
                    "assemblyLockHoldMicroseconds": String(
                        assemblyLockHoldMicroseconds),
                ])
                stats.framesDecoded += 1
                recordQuality(bytes: unit.annexB.count, now: now)
                if let newest = newestDeliveredFrame {
                    if Int32(bitPattern: unit.frameNumber.rawValue
                        &- newest.rawValue) > 0 {
                        newestDeliveredFrame = unit.frameNumber
                    }
                } else {
                    newestDeliveredFrame = unit.frameNumber
                }
                stats.assemblyLockHoldMicroseconds.record(
                    assemblyLockHoldMicroseconds)
                actions.append(.buildSample(
                    unit, now, assemblyLockHoldMicroseconds))
                actions.append(.repairSignal(
                    .frameDecoded(frame: unit.frameNumber), now))
            case .framesSkipped(let from, let through, _):
                stats.framesSkipped += UInt64(through.rawValue &- from.rawValue) + 1
                actions.append(.repairSignal(
                    .framesGone(from: from, through: through), now))
            case .fecImpossible(let frame, let lost, let parity):
                stats.fecImpossibleCount += 1
                actions.append(.fecImpossible(
                    frame, presumedLostDataShards: lost, bestCaseParityShards: parity))
            case .evicted(let frame, _):
                stats.evictions += 1
                actions.append(.repairSignal(
                    .framesGone(from: frame, through: frame), now))
            case .shardDropped(let reason):
                stats.shardsDropped += 1
                // Duplicate-slot and passed-turn drops feed the policy's
                // repair books; the rest are counters only.
                switch reason {
                case .duplicateShard(let frame, let shardIndex):
                    actions.append(.repairSignal(
                        .satisfiedShardDropped(
                            frame: frame, shardIndex: shardIndex),
                        now))
                case .staleFrame(let frame):
                    actions.append(.repairSignal(
                        .staleShardDropped(frame: frame), now))
                default:
                    break
                }
            case .nackCandidates(
                let frame, _, let missingIndices, let parity, let age):
                actions.append(.repairSignal(
                    .nackCandidates(
                        frame: frame,
                        missingShardIndices: missingIndices,
                        parityShards: parity,
                        frameAgeMicroseconds: age),
                    now))
            case .repairShardAccepted(let frame, let index):
                stats.repairShardsAccepted += 1
                actions.append(.repairSignal(
                    .repairShardAccepted(frame: frame, shardIndex: index),
                    now))
            }
        }
        return actions
    }

    private func dispatch(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .buildSample(let unit, let now, let lockHold):
                let work: @Sendable () -> Void = { [self] in
                    buildAndDeliver(
                        unit, now: now,
                        assemblyLockHoldMicroseconds: lockHold)
                }
                if asynchronousSampleBuild {
                    sampleQueue.async(execute: work)
                } else {
                    sampleQueue.sync(execute: work)
                }
            case .fecImpossible(let frame, let lost, let parity):
                onFecImpossible?(frame, lost, parity)
            case .repairSignal(let signal, let now):
                onRepairSignal?(signal, now)
            }
        }
    }

    private func buildAndDeliver(
        _ unit: DecodeUnit,
        now: ClientTimestamp,
        assemblyLockHoldMicroseconds: UInt64
    ) {
        let started = nowNanoseconds()
        PipelineWitness.record("sampleBuildBegin", fields: [
            "frame": String(unit.frameNumber.rawValue),
        ])
        let sample: CMSampleBuffer?
        do {
            sample = try factory.makeSampleBuffer(from: unit)
        } catch {
            let elapsed = (nowNanoseconds() &- started) / 1_000
            lock.lock()
            stats.sampleBuildMicroseconds.record(elapsed)
            stats.sampleFailures += 1
            lock.unlock()
            return
        }
        let elapsed = (nowNanoseconds() &- started) / 1_000
        PipelineWitness.record("sampleBuildCompleted", fields: [
            "frame": String(unit.frameNumber.rawValue),
            "elapsedMicroseconds": String(elapsed),
            "success": String(sample != nil),
        ])
        lock.lock()
        stats.sampleBuildMicroseconds.record(elapsed)
        if sample != nil {
            stats.samplesDelivered += 1
            if stats.firstSampleMicroseconds == nil, let firstIngest {
                stats.firstSampleMicroseconds = now.microseconds(since: firstIngest)
            }
        } else {
            stats.samplesWithheld += 1
        }
        lock.unlock()
        if let sample {
            VideoSampleTiming.attachBuildTelemetry(
                to: sample,
                sampleBuildMicroseconds: elapsed,
                assemblyLockHoldMicroseconds: assemblyLockHoldMicroseconds)
            sink.submit(sample: sample, unit: unit)
        }
    }

    private func currentTimestamp() -> ClientTimestamp {
        ClientTimestamp(microseconds: nowNanoseconds() / 1_000)
    }

}

/// (decode instant, Annex-B bytes) per decoded frame over the last 5 s.
struct VideoQualityWindow {
    static let spanMicroseconds: Int64 = 5_000_000

    private var entries = Deque<(at: ClientTimestamp, bytes: Int)>()

    var liveCount: Int { entries.count }
    var storedCount: Int { entries.retainedCapacity }

    mutating func record(bytes: Int, now: ClientTimestamp) {
        entries.append((at: now, bytes: bytes))
        prune(now: now)
    }

    mutating func prune(now: ClientTimestamp) {
        while let oldest = entries.first,
              now.microseconds(since: oldest.at) > Self.spanMicroseconds {
            entries.removeFirst()
        }
    }

    /// Cadence and bitrate over the frames' actual span (floored at 1 s,
    /// so a young session reads its true short-window rate), percentiles
    /// over their sizes; nil when no frame decoded inside the window.
    mutating func snapshot(now: ClientTimestamp) -> VideoQualitySnapshot? {
        prune(now: now)
        guard let oldest = entries.first else { return nil }
        let sizes = entries.map(\.bytes).sorted()
        func pct(_ q: Double) -> Int {
            sizes[max(Int((q * Double(sizes.count)).rounded(.up)), 1) - 1]
        }
        let span = max(now.microseconds(since: oldest.at), 1_000_000)
        let bytes = sizes.reduce(0, +)
        return VideoQualitySnapshot(
            framesPerSecond: Double(sizes.count) * 1e6 / Double(span),
            bitsPerSecond: Int(Double(bytes) * 8e6 / Double(span)),
            frameBytesP50: pct(0.5),
            frameBytesP95: pct(0.95),
            frameBytesMax: sizes.last!)
    }
}
