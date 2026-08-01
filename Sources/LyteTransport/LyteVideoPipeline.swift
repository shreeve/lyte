// LyteVideoPipeline: the CL-2 wiring — video-channel datagrams from
// ReceiveDemux in, ready-to-enqueue CMSampleBuffers out. The interesting
// parts live elsewhere by design (build plan §4.3: the core owns the
// assembler; this module owns the seam):
//
//   (envelope, payload) → VideoAssembler → DecodeUnit
//       → VideoRenderFactory → CMSampleBuffer → onSample
//
// The display layer is deliberately absent: the pipeline emits sample
// buffers through a callback so the CLI can point it at an
// AVSampleBufferDisplayLayer's renderer while tests run the identical
// path headless. Presentation timing is assigned by the app's adaptive
// playout controller; frame order is the assembler's guarantee.
//
// fecImpossible events surface through `onFecImpossible` — the seam
// CL-3's IDR-request feedback hooks into; nothing is implemented behind
// it today. Assembler eviction is driven by `start()`'s timer (or by
// `tick(now:)` directly, which is what tests do).
//
// Threading: assembly is lock-confined, but CoreMedia allocation runs on
// a dedicated serial queue in production. Tests may choose synchronous
// construction for deterministic assertions. Callbacks never hold the
// assembler lock.

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
    /// Sample buffers delivered to `onSample`.
    public var samplesDelivered: UInt64 = 0
    /// DecodeUnits withheld pre-bootstrap (P-frame before the first IDR).
    public var samplesWithheld: UInt64 = 0
    /// CMSampleBuffer construction failures (CoreMedia refused).
    public var sampleFailures: UInt64 = 0
    /// CoreMedia sample construction on the receive thread, µs. This is
    /// the boundary between completed assembly and the app delivery hop;
    /// without it a factory stall is falsely blamed on network/assembly.
    public var sampleBuildMicroseconds = LatencyHistogram(capacity: 360)
    /// Time spent holding the assembly/state lock for an ingest that
    /// completed a frame. CoreMedia work is deliberately excluded.
    public var assemblyLockHoldMicroseconds = LatencyHistogram(capacity: 360)
    /// fecImpossible verdicts (each also fired the seam callback).
    public var fecImpossibleCount: UInt64 = 0
    /// Groups evicted undecoded (stale or capacity).
    public var evictions: UInt64 = 0
    /// Shards the assembler dropped (duplicates, malformed, stale).
    public var shardsDropped: UInt64 = 0
    /// Fresh-seq repair shards (HS-17's NACK answers) the assembler
    /// slotted into tracked groups (CL-12).
    public var repairShardsAccepted: UInt64 = 0
    /// Reliable-channel frames (0x15 idle frames) rendered through the
    /// same factory as the datagram path (CL-8).
    public var reliableFramesRendered: UInt64 = 0
    /// Reliable-channel frames deduplicated — the datagram path already
    /// delivered that frame number (or a newer one).
    public var reliableFramesDeduplicated: UInt64 = 0
    /// Client µs from the first ingested video datagram to the first
    /// delivered sample — the render path's bootstrap latency.
    public var firstSampleMicroseconds: Int64?
    /// HS-22: the receive-side quality window — decoded frames over
    /// the last ~5 s, derived entirely from what already arrives (no
    /// wire vocabulary): frame cadence, video bitrate, frame-size
    /// percentiles. Nil until a frame has decoded inside the window.
    public var quality: VideoQualitySnapshot?
}

public struct VideoFrameBuildTelemetry: Sendable, Equatable {
    public var frame: UInt32
    public var assemblyLockHoldMicroseconds: UInt64
    public var sampleBuildMicroseconds: UInt64
}

/// HS-22: what the client can say about incoming video quality from
/// its own books — the overlay/wire-view quality line. Host-side
/// truth (nvenc QP, the encoder's reconfigured posture) lives in the
/// host's per-second `quality:` books; this is the wire-view-side
/// derivation of the same story.
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
    /// Rendered through the shared factory and delivered to `onSample`.
    case rendered
    /// The datagram path already delivered this frame number (or a
    /// newer one) — nothing to do; the screen is current.
    case deduplicated
    /// No format description exists yet (a P-frame idle frame before
    /// any IDR) — withheld like the datagram path withholds.
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
    private var stats = VideoPipelineStats()
    private var firstIngest: ClientTimestamp?
    /// HS-22 quality window: (decode instant, Annex-B byte count) per
    /// decoded frame, pruned to the last `qualityWindowMicroseconds`
    /// on record and on snapshot. Confined by `lock`.
    private var qualityWindow: [(at: ClientTimestamp, bytes: Int)] = []
    private static let qualityWindowMicroseconds: Int64 = 5_000_000
    /// The newest frame number delivered by either path — the reliable
    /// idle frame's dedupe reference (its `frame` field names the
    /// number the converged frame last rode the datagram path with).
    private var newestDeliveredFrame: FrameNumber?
    private var frameBuildTelemetry: [UInt32: VideoFrameBuildTelemetry] = [:]
    private var frameBuildOrder: [UInt32] = []

    private let onSample: @Sendable (CMSampleBuffer, DecodeUnit) -> Void
    private let onFecImpossible: (@Sendable (FrameNumber, _ presumedLostDataShards: Int, _ bestCaseParityShards: Int) -> Void)?
    /// CL-12: the NackPolicy's feed — presumption pictures, accepted
    /// repairs, and frame fates, with the pipeline's clock alongside.
    private let onRepairSignal: (@Sendable (VideoRepairSignal, ClientTimestamp) -> Void)?

    private var evictionTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - onSample: one ready sample per rendered frame, called on the
    ///     ingest thread (enqueue to a display layer's renderer, or
    ///     collect in tests). The owner assigns local presentation time.
    ///     @Sendable because ingest threads call it — a MainActor-
    ///     inferred closure here traps at runtime (dispatch_assert_queue).
    ///   - onFecImpossible: the CL-3 seam — fired once per frame the
    ///     assembler writes off as unrecoverable from plausible arrivals.
    ///   - onRepairSignal: the CL-12 seam — the NackPolicy's event feed.
    public init(
        channel: ChannelId = .videoActive,
        config: VideoAssemblerConfig = VideoAssemblerConfig(),
        asynchronousSampleBuild: Bool = false,
        onSample: @escaping @Sendable (CMSampleBuffer, DecodeUnit) -> Void,
        onFecImpossible: (@Sendable (FrameNumber, _ presumedLostDataShards: Int, _ bestCaseParityShards: Int) -> Void)? = nil,
        onRepairSignal: (@Sendable (VideoRepairSignal, ClientTimestamp) -> Void)? = nil
    ) {
        self.channel = channel
        self.assembler = VideoAssembler(channel: channel, config: config)
        self.asynchronousSampleBuild = asynchronousSampleBuild
        self.onSample = onSample
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
            self?.tick(now: Self.monotonicNow())
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

    /// Feeds one accepted datagram — the endpoint's `onDatagram` hook
    /// calls this with every `.accepted` outcome; other channels pass
    /// through untouched.
    public func ingest(envelope: Envelope, payload: [UInt8]) {
        ingest(envelope: envelope, payload: payload, now: Self.monotonicNow())
    }

    /// Injected-clock variant (tests drive time explicitly).
    public func ingest(envelope: Envelope, payload: [UInt8], now: ClientTimestamp) {
        guard envelope.channel == channel else { return }
        let lockStarted = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if firstIngest == nil { firstIngest = now }
        let events = assembler.ingest(envelope: envelope, payload: payload, now: now)
        let lockHeld = (DispatchTime.now().uptimeNanoseconds &- lockStarted) / 1_000
        let actions = process(events, now: now, assemblyLockHoldMicroseconds: lockHeld)
        lock.unlock()
        dispatch(actions)
    }

    /// Feeds one reliable-channel frame (a 0x15 idle frame the ARQ
    /// delivered) into the same render chain the datagram path uses —
    /// the seam the build plan designed at CL-2 and CL-8 exercises: the
    /// SAME factory, so the idle frame inherits the session's parameter
    /// sets and format-description continuity. Deduplicates against the
    /// newest delivered frame number (wrap-aware): the idle frame names
    /// the number its bytes last rode the datagram path with, so a
    /// clean-path receiver already shows it and re-rendering would be a
    /// visible stutter for nothing.
    public func ingestReliableFrame(
        frame: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        annexB: [UInt8]
    ) -> ReliableFrameOutcome {
        let now = Self.monotonicNow()
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
        let outcome: ReliableFrameOutcome
        lock.unlock()
        var sample: CMSampleBuffer?
        var buildOutcome: ReliableFrameOutcome = .failed
        sampleQueue.sync {
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                sample = try factory.makeSampleBuffer(from: unit)
                buildOutcome = sample == nil ? .withheld : .rendered
            } catch {
                buildOutcome = .failed
            }
            let elapsed = (DispatchTime.now().uptimeNanoseconds &- started) / 1_000
            lock.lock()
            stats.sampleBuildMicroseconds.record(elapsed)
            if sample != nil {
                stats.framesDecoded += 1
                recordQuality(bytes: annexB.count, now: now)
                stats.reliableFramesRendered += 1
                stats.samplesDelivered += 1
                newestDeliveredFrame = frame
            } else if buildOutcome == .withheld {
                stats.samplesWithheld += 1
            } else {
                stats.sampleFailures += 1
            }
            recordFrameBuildTelemetry(
                frame: frame.rawValue, lockHold: 0, sampleBuild: elapsed)
            lock.unlock()
        }
        outcome = buildOutcome
        if let sample {
            let telemetry = frameTelemetry(frame: frame)
            VideoSampleTiming.attachBuildTelemetry(
                to: sample,
                sampleBuildMicroseconds:
                    telemetry?.sampleBuildMicroseconds ?? 0,
                assemblyLockHoldMicroseconds: 0)
            onSample(sample, unit)
        }
        return outcome
    }

    /// Time-only tick: assembler eviction and holdback expiry. The timer
    /// calls this; tests call it directly.
    public func tick(now: ClientTimestamp) {
        lock.lock()
        let events = assembler.evictStale(now: now)
        let actions = process(events, now: now, assemblyLockHoldMicroseconds: 0)
        lock.unlock()
        dispatch(actions)
    }

    public func snapshotStats() -> VideoPipelineStats {
        snapshotStats(now: Self.monotonicNow())
    }

    /// Injected-clock variant (tests drive time explicitly).
    public func snapshotStats(now: ClientTimestamp) -> VideoPipelineStats {
        lock.lock()
        defer { lock.unlock() }
        var out = stats
        pruneQualityWindow(now: now)
        if !qualityWindow.isEmpty {
            let sizes = qualityWindow.map(\.bytes).sorted()
            func pct(_ q: Double) -> Int {
                sizes[max(Int((q * Double(sizes.count)).rounded(.up)), 1) - 1]
            }
            // The span the frames actually cover, floored at 1 s so a
            // young session reads as its true short-window rate rather
            // than dividing by a few ms.
            let span = max(
                now.microseconds(since: qualityWindow.first!.at), 1_000_000
            )
            let bytes = sizes.reduce(0, +)
            out.quality = VideoQualitySnapshot(
                framesPerSecond: Double(sizes.count) * 1e6 / Double(span),
                bitsPerSecond: Int(Double(bytes) * 8e6 / Double(span)),
                frameBytesP50: pct(0.5),
                frameBytesP95: pct(0.95),
                frameBytesMax: sizes.last!
            )
        }
        return out
    }

    public func frameTelemetry(frame: FrameNumber) -> VideoFrameBuildTelemetry? {
        lock.lock()
        defer { lock.unlock() }
        return frameBuildTelemetry[frame.rawValue]
    }

    /// Runs under `lock`.
    private func recordQuality(bytes: Int, now: ClientTimestamp) {
        qualityWindow.append((at: now, bytes: bytes))
        pruneQualityWindow(now: now)
    }

    /// Runs under `lock`.
    private func pruneQualityWindow(now: ClientTimestamp) {
        while let first = qualityWindow.first,
              now.microseconds(since: first.at)
                  > Self.qualityWindowMicroseconds {
            qualityWindow.removeFirst()
        }
    }

    // MARK: - Interior

    private enum Action {
        case buildSample(DecodeUnit, ClientTimestamp, UInt64)
        case fecImpossible(FrameNumber, presumedLostDataShards: Int, bestCaseParityShards: Int)
        case repairSignal(VideoRepairSignal, ClientTimestamp)
    }

    /// Turns assembler events into stats and deferred callbacks. Runs
    /// under the lock (factory access); callbacks fire after release.
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
                // The two reasons a NACK answer can land as (duplicate
                // slot, passed turn) feed the policy's late/duplicate/
                // superseded books; the rest are counters only.
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
                // CL-12: §4.7's consumer exists now — the NackPolicy.
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
        let started = DispatchTime.now().uptimeNanoseconds
        PipelineWitness.record("sampleBuildBegin", fields: [
            "frame": String(unit.frameNumber.rawValue),
        ])
        let sample: CMSampleBuffer?
        do {
            sample = try factory.makeSampleBuffer(from: unit)
        } catch {
            let elapsed = (DispatchTime.now().uptimeNanoseconds &- started) / 1_000
            lock.lock()
            stats.sampleBuildMicroseconds.record(elapsed)
            stats.sampleFailures += 1
            recordFrameBuildTelemetry(
                frame: unit.frameNumber.rawValue,
                lockHold: assemblyLockHoldMicroseconds,
                sampleBuild: elapsed)
            lock.unlock()
            return
        }
        let elapsed = (DispatchTime.now().uptimeNanoseconds &- started) / 1_000
        PipelineWitness.record("sampleBuildCompleted", fields: [
            "frame": String(unit.frameNumber.rawValue),
            "elapsedMicroseconds": String(elapsed),
            "success": String(sample != nil),
        ])
        lock.lock()
        stats.sampleBuildMicroseconds.record(elapsed)
        recordFrameBuildTelemetry(
            frame: unit.frameNumber.rawValue,
            lockHold: assemblyLockHoldMicroseconds,
            sampleBuild: elapsed)
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
            onSample(sample, unit)
        }
    }

    /// Runs under `lock`.
    private func recordFrameBuildTelemetry(
        frame: UInt32, lockHold: UInt64, sampleBuild: UInt64
    ) {
        if frameBuildTelemetry[frame] == nil {
            frameBuildOrder.append(frame)
            if frameBuildOrder.count > 512 {
                frameBuildTelemetry.removeValue(
                    forKey: frameBuildOrder.removeFirst())
            }
        }
        frameBuildTelemetry[frame] = VideoFrameBuildTelemetry(
            frame: frame,
            assemblyLockHoldMicroseconds: lockHold,
            sampleBuildMicroseconds: sampleBuild)
    }

    static func monotonicNow() -> ClientTimestamp {
        ClientTimestamp(microseconds: DispatchTime.now().uptimeNanoseconds / 1000)
    }
}
