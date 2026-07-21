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
// path headless. Presentation is present-ASAP (Work-mode default, no
// jitter buffer): every sample carries DisplayImmediately, and frame
// order is the assembler's ordered-emission guarantee.
//
// fecImpossible events surface through `onFecImpossible` — the seam
// CL-3's IDR-request feedback hooks into; nothing is implemented behind
// it today. Assembler eviction is driven by `start()`'s timer (or by
// `tick(now:)` directly, which is what tests do).
//
// Threading: `ingest` runs on the endpoint's receive thread, the
// eviction timer on a utility queue; one lock confines the assembler,
// the factory, and the stats. Callbacks fire inside the lock's thread
// but outside the lock itself.

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
    /// fecImpossible verdicts (each also fired the seam callback).
    public var fecImpossibleCount: UInt64 = 0
    /// Groups evicted undecoded (stale or capacity).
    public var evictions: UInt64 = 0
    /// Shards the assembler dropped (duplicates, malformed, stale).
    public var shardsDropped: UInt64 = 0
    /// Client µs from the first ingested video datagram to the first
    /// delivered sample — the render path's bootstrap latency.
    public var firstSampleMicroseconds: Int64?
}

public final class LyteVideoPipeline: @unchecked Sendable {
    public let channel: ChannelId

    private let lock = NSLock()
    private var assembler: VideoAssembler
    private let factory = VideoRenderFactory()
    private var stats = VideoPipelineStats()
    private var firstIngest: ClientTimestamp?

    private let onSample: @Sendable (CMSampleBuffer, DecodeUnit) -> Void
    private let onFecImpossible: (@Sendable (FrameNumber, _ presumedLostDataShards: Int, _ bestCaseParityShards: Int) -> Void)?

    private var evictionTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - onSample: one ready sample per rendered frame, called on the
    ///     ingest thread (enqueue to a display layer's renderer, or
    ///     collect in tests). DisplayImmediately is already attached.
    ///     @Sendable because ingest threads call it — a MainActor-
    ///     inferred closure here traps at runtime (dispatch_assert_queue).
    ///   - onFecImpossible: the CL-3 seam — fired once per frame the
    ///     assembler writes off as unrecoverable from plausible arrivals.
    public init(
        channel: ChannelId = .videoActive,
        config: VideoAssemblerConfig = VideoAssemblerConfig(),
        onSample: @escaping @Sendable (CMSampleBuffer, DecodeUnit) -> Void,
        onFecImpossible: (@Sendable (FrameNumber, _ presumedLostDataShards: Int, _ bestCaseParityShards: Int) -> Void)? = nil
    ) {
        self.channel = channel
        self.assembler = VideoAssembler(channel: channel, config: config)
        self.onSample = onSample
        self.onFecImpossible = onFecImpossible
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
        lock.lock()
        if firstIngest == nil { firstIngest = now }
        let events = assembler.ingest(envelope: envelope, payload: payload, now: now)
        let actions = process(events, now: now)
        lock.unlock()
        dispatch(actions)
    }

    /// Time-only tick: assembler eviction and holdback expiry. The timer
    /// calls this; tests call it directly.
    public func tick(now: ClientTimestamp) {
        lock.lock()
        let events = assembler.evictStale(now: now)
        let actions = process(events, now: now)
        lock.unlock()
        dispatch(actions)
    }

    public func snapshotStats() -> VideoPipelineStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: - Interior

    private enum Action {
        case sample(CMSampleBuffer, DecodeUnit)
        case fecImpossible(FrameNumber, presumedLostDataShards: Int, bestCaseParityShards: Int)
    }

    /// Turns assembler events into stats and deferred callbacks. Runs
    /// under the lock (factory access); callbacks fire after release.
    private func process(
        _ events: [VideoAssemblerEvent], now: ClientTimestamp
    ) -> [Action] {
        var actions: [Action] = []
        for event in events {
            switch event {
            case .decoded(let unit):
                stats.framesDecoded += 1
                do {
                    if let sample = try factory.makeSampleBuffer(from: unit) {
                        stats.samplesDelivered += 1
                        if stats.firstSampleMicroseconds == nil, let firstIngest {
                            stats.firstSampleMicroseconds = now.microseconds(since: firstIngest)
                        }
                        actions.append(.sample(sample, unit))
                    } else {
                        stats.samplesWithheld += 1
                    }
                } catch {
                    stats.sampleFailures += 1
                }
            case .framesSkipped(let from, let through, _):
                stats.framesSkipped += UInt64(through.rawValue &- from.rawValue) + 1
            case .fecImpossible(let frame, let lost, let parity):
                stats.fecImpossibleCount += 1
                actions.append(.fecImpossible(
                    frame, presumedLostDataShards: lost, bestCaseParityShards: parity))
            case .evicted:
                stats.evictions += 1
            case .shardDropped:
                stats.shardsDropped += 1
            case .nackCandidates:
                break   // §4.7: emitted but unconsumed until HS-17.
            }
        }
        return actions
    }

    private func dispatch(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .sample(let buffer, let unit):
                onSample(buffer, unit)
            case .fecImpossible(let frame, let lost, let parity):
                onFecImpossible?(frame, lost, parity)
            }
        }
    }

    static func monotonicNow() -> ClientTimestamp {
        ClientTimestamp(microseconds: DispatchTime.now().uptimeNanoseconds / 1000)
    }
}
