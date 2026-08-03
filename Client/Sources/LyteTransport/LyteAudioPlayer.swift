// LyteAudioPlayer (CL-11): the production audio shell — AVAudioEngine
// out of a lock-free SPSC ring, fed by a pump that pulls verdicts from
// the sans-IO AudioReceiver and decodes on ITS thread, never the
// render callback (the audio-continuity doc's render-thread rule §5.1,
// honored from the first commit here rather than retrofitted).
//
// Pacing doctrine: the render callback consumes at exactly the DAC's
// rate; the pump refills whenever the ring sits below the receiver's
// adaptive target. Playout therefore locks to the hardware clock —
// no timer beats against the 5 ms arrivals, and sender/receiver clock
// skew expresses as slow target drift the jitter buffer absorbs.
//
// The pump cadence is adaptive one-shot (item 18): the render side
// drains the ring at exactly the DAC rate, so after each pass the
// next instant the ring could approach the urgent threshold (one
// packet) is computable — the timer re-arms for that instant, clamped
// to a 2 ms floor (the dry-ring reflex: scheduling jitter shows up as
// ring-depth ripple well inside one packet, and the `urgent` flag
// turns a nearly-dry ring into immediate PLC instead of zeros) and a
// 10 ms ceiling (bounds the cost of any wrong guess to two packets).
// A healthy ring rides the ceiling — 100 wakeups/s instead of the old
// fixed 2 ms cadence's 500 — while a shallow or draining ring walks
// the floor exactly as before.
//
// CL-17 grows the pump two ways. (1) Decoded PCM rides through the
// WSOLA AudioAccelerator whenever the receiver's pull decision says
// the pipe is overfull — backlog drains by pitch-preserving time
// compression (≤5% fast) instead of parking as latency or dying in a
// content skip; a nearly-dry ring flushes the accelerator's gather
// first (zeros are strictly worse than 20 ms of uncompressed audio).
// (2) An output-device change (AirPods in/out, default-device switch)
// posts AVAudioEngineConfigurationChange and STOPS the engine — the
// handler rebuilds the source node and restarts on a serial queue
// while the ring (and everything upstream) survives untouched, so
// playback resumes where the old device left it; counted.

import LyteIO
import AVFoundation
import Dispatch
import Foundation
import LyteWire
import Synchronization

public struct LyteAudioPlayerStats: Sendable {
    /// Frames the render callback wanted and the ring could not give
    /// while the stream was actively flowing (zeros went out).
    public var underrunFrames: UInt64 = 0
    /// Frames rendered from real ring content.
    public var framesRendered: UInt64 = 0
    /// Packets decoded and written (wire + PLC both).
    public var packetsFed: UInt64 = 0
    public var plcPacketsFed: UInt64 = 0
    /// Ring depth in frames at the last pump pass.
    public var ringDepthFrames: Int = 0
    /// Decoded-signal evidence over the last full 1 s window: RMS in
    /// dBFS and a zero-crossing frequency estimate (objective proof a
    /// generated tone crossed — the HS-15 tone-verification pattern).
    public var lastWindowRmsDbfs: Double = -Double.infinity
    public var lastWindowZeroCrossingHz: Double = 0
    public var decodeFailures: UInt64 = 0
    /// CL-17: the WSOLA accelerate books (ops, frames excised, ms
    /// drained).
    public var accelerate = AudioAccelerateStats()
    /// CL-17: output-device changes survived (engine rebuilt, ring
    /// kept) and rebuilds that never came back (device refused).
    public var routeChangesHandled: UInt64 = 0
    public var routeChangeFailures: UInt64 = 0

    public init() {}
}

/// The lock-free SPSC PCM ring the render callback reads and the pump
/// writes — its own class so the render block captures IT, never the
/// player (no lock, no allocation, no self-cycle on the render thread).
/// Counters are monotonically increasing frame counts, masked in.
final class AudioPcmRing: @unchecked Sendable {
    static let capacityFrames = 48_000                        // 1 s
    let buffer: UnsafeMutablePointer<Float>
    let readCounter = Atomic<Int>(0)
    let writeCounter = Atomic<Int>(0)
    /// µs uptime of the last write — the render callback counts
    /// underruns only while the stream is actively flowing (a FROZEN
    /// blackout's silence is the machine's business, not an underrun).
    let lastWriteMicros = Atomic<UInt64>(0)
    let underrunFrames = Atomic<UInt64>(0)
    let framesRendered = Atomic<UInt64>(0)

    /// HS-31 declick: a ring underrun used to hard-cut to zeros, and
    /// every edge was an audible crack (worst live leg: 1.58 s of
    /// zero-fill = hundreds of them). Instead, the pad now DECAYS the
    /// boundary sample linearly to true zero over ~2 ms — continuous
    /// by construction no matter where inside a callback the shortfall
    /// lands — and recovery CROSSFADES from the tail's current value
    /// into the real samples over the same window. All state below is
    /// render-thread-only (the callback is the sole toucher) and
    /// preallocated: no locks, no allocation, no runtime calls join
    /// the hot path.
    static let declickFrames = 96                    // 2 ms at 48 kHz
    private let tailBase: UnsafeMutablePointer<Float>    // per channel
    private let resumeBase: UnsafeMutablePointer<Float>  // per channel
    private let lastOut: UnsafeMutablePointer<Float>     // per channel
    private var tailDone = 0        // decay frames emitted this episode
    private var fadeInLeft = 0      // crossfade-in frames still owed
    private var inStarvation = false

    init() {
        let count = Self.capacityFrames * AudioWire.channels
        buffer = .allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        tailBase = .allocate(capacity: AudioWire.channels)
        tailBase.initialize(repeating: 0, count: AudioWire.channels)
        resumeBase = .allocate(capacity: AudioWire.channels)
        resumeBase.initialize(repeating: 0, count: AudioWire.channels)
        lastOut = .allocate(capacity: AudioWire.channels)
        lastOut.initialize(repeating: 0, count: AudioWire.channels)
    }

    deinit {
        buffer.deallocate()
        tailBase.deallocate()
        resumeBase.deallocate()
        lastOut.deallocate()
    }

    var depthFrames: Int {
        writeCounter.load(ordering: .relaxed)
            - readCounter.load(ordering: .relaxed)
    }

    /// Render-thread side: fills the DEINTERLEAVED channel buffers the
    /// engine hands a standard-format source node (mixer inputs must
    /// be standard — an interleaved connection raises an NSException).
    /// A shortfall is declicked (HS-31), never hard-cut: the pad
    /// decays the boundary sample to zero over ~2 ms and recovery
    /// crossfades back in; underruns are counted while the stream
    /// flows, exactly as before.
    func render(
        into buffers: UnsafeMutableAudioBufferListPointer, wanted: Int
    ) {
        let read = readCounter.load(ordering: .relaxed)
        let write = writeCounter.load(ordering: .acquiring)
        let available = min(wanted, write - read)
        let channels = AudioWire.channels
        let fade = Self.declickFrames
        let invFade = 1 / Float(fade)
        let starving = available < wanted
        let episodeStart = starving && !inStarvation
        let tailStart = episodeStart ? 0 : tailDone
        // First callback after an episode: the crossfade-in starts
        // from the tail's CURRENT value — zero once the decay ran its
        // 2 ms (the common case: underruns last ≥ one 5 ms packet),
        // mid-decay if recovery came sooner. Either way, continuous.
        if !starving, inStarvation {
            let level = Float(max(0, fade - tailDone)) * invFade
            for channel in 0..<channels {
                resumeBase[channel] = tailBase[channel] * level
            }
        }
        let fadeInStart = fadeInLeft
        for channel in 0..<min(channels, buffers.count) {
            guard let out = buffers[channel].mData?
                .assumingMemoryBound(to: Float.self)
            else { continue }
            for frame in 0..<available {
                let slot = ((read + frame) % Self.capacityFrames) * channels
                var sample = buffer[slot + channel]
                if frame < fadeInStart {
                    // Linear crossfade: real ramps in, the held tail
                    // value ramps out; the gains sum to one.
                    let k = Float(fade - fadeInStart + frame)
                    sample = sample * (k + 1) * invFade
                        + resumeBase[channel] * (Float(fade) - k - 1)
                        * invFade
                }
                out[frame] = sample
            }
            if starving {
                if episodeStart {
                    tailBase[channel] = available > 0
                        ? out[available - 1] : lastOut[channel]
                }
                // The decay tail: continuous with the boundary sample
                // wherever the shortfall lands, true zero from `fade`
                // pad frames onward.
                let base = tailBase[channel]
                for frame in available..<wanted {
                    let index = tailStart + (frame - available)
                    out[frame] = index < fade
                        ? base * Float(fade - 1 - index) * invFade
                        : 0
                }
            }
            if wanted > 0 { lastOut[channel] = out[wanted - 1] }
        }
        if starving {
            tailDone = tailStart + (wanted - available)
            inStarvation = true
            fadeInLeft = fade
        } else {
            fadeInLeft = max(0, fadeInStart - available)
            inStarvation = false
        }
        if available < wanted {
            let last = lastWriteMicros.load(ordering: .relaxed)
            let now = SystemMonotonicClock.nowMicroseconds
            if last != 0, now &- last < 200_000 {
                _ = underrunFrames.add(
                    UInt64(wanted - available), ordering: .relaxed)
            }
        }
        _ = framesRendered.add(UInt64(available), ordering: .relaxed)
        readCounter.store(read + available, ordering: .releasing)
    }

    /// Pump-thread side: appends interleaved frames.
    func write(_ pcm: [Float]) {
        let channels = AudioWire.channels
        let write = writeCounter.load(ordering: .relaxed)
        let frames = pcm.count / channels
        for frame in 0..<frames {
            let slot = ((write + frame) % Self.capacityFrames) * channels
            for channel in 0..<channels {
                buffer[slot + channel] = pcm[frame * channels + channel]
            }
        }
        writeCounter.store(write + frames, ordering: .releasing)
        lastWriteMicros.store(
            SystemMonotonicClock.nowMicroseconds,
            ordering: .relaxed)
    }
}

public final class LyteAudioPlayer: @unchecked Sendable {
    private let receiver: AudioReceiver
    private let decoder: OpusStreamDecoder
    private let ring = AudioPcmRing()

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var pump: DispatchSourceTimer?
    /// Engine-graph mutations (start/stop/route rebuild) exclude each
    /// other here — the session's audio queue and the route queue both
    /// arrive at the same engine.
    private let engineLock = NSLock()
    private let routeQueue = DispatchQueue(
        label: "lyte.audio.route", qos: .userInitiated)
    private var configChangeObserver: (any NSObjectProtocol)?
    private let routeChangesHandled = Atomic<UInt64>(0)
    private let routeChangeFailures = Atomic<UInt64>(0)

    // Pump-side state (pump thread only).
    private let accelerator = AudioAccelerator()
    private var packetsFed: UInt64 = 0
    private var plcPacketsFed: UInt64 = 0
    private var accelSnapshot = AudioAccelerateStats()
    private var windowSumSquares: Double = 0
    private var windowFrames = 0
    private var windowCrossings = 0
    private var windowLastSample: Float = 0
    private var lastWindowRmsDbfs: Double = -Double.infinity
    private var lastWindowZeroCrossingHz: Double = 0
    private let statsLock = NSLock()

    public var muted: Bool = false {
        didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 1 }
    }

    public init(receiver: AudioReceiver) throws {
        self.receiver = receiver
        self.decoder = try OpusStreamDecoder()
    }

    /// Builds the graph and starts the engine + pump. Throws what the
    /// engine throws — the caller treats a refused audio device as
    /// weather (video must stream even when audio cannot; the host's
    /// rule, mirrored).
    public func start() throws {
        engineLock.lock()
        do {
            guard sourceNode == nil else {
                engineLock.unlock()
                return
            }
            let node = try makeSourceNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode,
                           format: node.outputFormat(forBus: 0))
            engine.mainMixerNode.outputVolume = muted ? 0 : 1
            try engine.start()
            sourceNode = node
        } catch {
            engineLock.unlock()
            throw error
        }
        engineLock.unlock()

        // The route seam (CL-17): a default-output switch stops the
        // engine and posts this — rebuild off the notification thread.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleOutputConfigurationChange()
        }

        // Adaptive one-shot cadence: each pass re-arms the timer for
        // the next instant the ring could matter (see the header
        // doctrine). The handler captures the timer weakly and checks
        // isCancelled before re-arming — a cancelled source never
        // fires again, so a racing stop() needs no lock here.
        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(2),
                       leeway: .microseconds(500))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            self.pumpOnce()
            guard let timer, !timer.isCancelled else { return }
            let delay = Self.nextPumpDelayMicros(
                ringDepthFrames: self.ring.depthFrames)
            timer.schedule(deadline: .now() + .microseconds(delay),
                           leeway: .microseconds(500))
        }
        timer.resume()
        pump = timer
    }

    /// The adaptive pump schedule (item 18), pure so the gate can pin
    /// it: microseconds until the ring — draining at exactly the DAC
    /// rate — could reach the urgent threshold (one packet), clamped
    /// to [`pumpFloorMicros`, `pumpCeilingMicros`]. Only the ring
    /// counts as headroom: the accelerator's gather can rescue a dry
    /// ring, but only a pump pass flushes it, so it must not stretch
    /// the sleep that would run that pass.
    static let pumpFloorMicros = 2_000
    static let pumpCeilingMicros = 10_000
    static func nextPumpDelayMicros(ringDepthFrames: Int) -> Int {
        let headroom = ringDepthFrames - AudioWire.samplesPerPacket
        let drainMicros = headroom * 1_000_000 / AudioWire.sampleRate
        return min(max(drainMicros, pumpFloorMicros), pumpCeilingMicros)
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        engineLock.lock()
        if let node = sourceNode {
            engine.stop()
            engine.detach(node)
            sourceNode = nil
        }
        engineLock.unlock()
    }

    /// The notification target, public so a diagnostic (or the gate)
    /// can drive the exact production path. Serialized on the route
    /// queue; safe against a racing stop().
    public func handleOutputConfigurationChange() {
        routeQueue.async { [weak self] in self?.rebuildOutput() }
    }

    /// The standard format (float32 deinterleaved) — the only format
    /// a mixer input accepts; the ring deinterleaves in the render
    /// callback. The closure captures the RING, never self.
    private func makeSourceNode() throws -> AVAudioSourceNode {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(AudioWire.sampleRate),
            channels: AVAudioChannelCount(AudioWire.channels)
        ) else {
            throw OpusStreamDecoderError.createFailed(-1)
        }
        let ring = ring
        return AVAudioSourceNode(format: format) {
            _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            ring.render(into: buffers, wanted: Int(frameCount))
            return noErr
        }
    }

    /// The route-change recovery: tear the graph down to the ring and
    /// put it back on the NEW device. The ring is never touched —
    /// whatever was queued toward the old speaker plays on the new
    /// one; upstream (jitter buffer, accelerator, pump) never notices.
    private func rebuildOutput() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard let old = sourceNode else { return }   // stopped already
        engine.stop()
        engine.detach(old)
        sourceNode = nil
        guard let node = try? makeSourceNode() else {
            _ = routeChangeFailures.add(1, ordering: .relaxed)
            return
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode,
                       format: node.outputFormat(forBus: 0))
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        for attempt in 0..<5 {
            do {
                try engine.start()
                sourceNode = node
                _ = routeChangesHandled.add(1, ordering: .relaxed)
                return
            } catch {
                if attempt < 4 { usleep(100_000) }   // HAL settles
            }
        }
        // The new device refused every attempt; counted loudly. The
        // node stays attached so the NEXT configuration change (or a
        // fresh device) walks this same path again.
        sourceNode = node
        _ = routeChangeFailures.add(1, ordering: .relaxed)
    }

    public func snapshotStats() -> LyteAudioPlayerStats {
        var out = LyteAudioPlayerStats()
        out.underrunFrames = ring.underrunFrames.load(ordering: .relaxed)
        out.framesRendered = ring.framesRendered.load(ordering: .relaxed)
        out.ringDepthFrames = ring.depthFrames
        statsLock.lock()
        out.packetsFed = packetsFed
        out.plcPacketsFed = plcPacketsFed
        out.accelerate = accelSnapshot
        out.lastWindowRmsDbfs = lastWindowRmsDbfs
        out.lastWindowZeroCrossingHz = lastWindowZeroCrossingHz
        statsLock.unlock()
        out.decodeFailures = decoder.decodeFailures
        out.routeChangesHandled =
            routeChangesHandled.load(ordering: .relaxed)
        out.routeChangeFailures =
            routeChangeFailures.load(ordering: .relaxed)
        return out
    }

    // MARK: - The pump

    private func pumpOnce() {
        let capacity = AudioPcmRing.capacityFrames
        let packetFrames = AudioWire.samplesPerPacket
        while true {
            var ringDepth = ring.depthFrames
            // A nearly-dry ring outranks the accelerator's gather:
            // 20 ms of uncompressed audio beats any amount of zeros.
            if ringDepth < packetFrames, accelerator.pendingFrames > 0 {
                let flushed = accelerator.flush()
                if !flushed.isEmpty {
                    ring.write(flushed)
                    noteSignal(flushed)
                }
                ringDepth = ring.depthFrames
            }
            let target = max(receiver.targetDepthPackets, 1) * packetFrames
            guard ringDepth < target,
                  ringDepth + packetFrames <= capacity else {
                snapshotAccelBooks()
                return
            }
            let urgent = ringDepth < packetFrames
            // The pipe the receiver judges: ring + the gather — both
            // sit between the jitter buffer and the speaker.
            let heldFrames = ringDepth + accelerator.pendingFrames
            let pipelineMicros = UInt64(heldFrames) * 1_000_000
                / UInt64(AudioWire.sampleRate)
            let now = ClientTimestamp(
                microseconds: SystemMonotonicClock.nowMicroseconds)
            let decision = receiver.pullDecision(
                now: now, urgent: urgent,
                renderPipelineMicroseconds: pipelineMicros)
            let pcm: [Float]
            switch decision.verdict {
            case .packet(let packet):
                pcm = decoder.decode(packet.bytes)
                statsLock.lock()
                packetsFed += 1
                statsLock.unlock()
            case .conceal:
                pcm = decoder.decode(nil)
                statsLock.lock()
                packetsFed += 1
                plcPacketsFed += 1
                statsLock.unlock()
            case .starved:
                snapshotAccelBooks()
                return
            }
            let out = accelerator.process(
                pcm, accelerate: decision.accelerate)
            if !out.isEmpty {
                ring.write(out)
                noteSignal(out)
            }
        }
    }

    /// The accelerator is pump-thread-only; its books cross to
    /// snapshotStats through the stats lock.
    private func snapshotAccelBooks() {
        statsLock.lock()
        accelSnapshot = accelerator.stats
        statsLock.unlock()
    }

    /// Decoded-signal evidence, rolled once per second of fed audio:
    /// window RMS (dBFS) + zero-crossing rate on the left channel —
    /// the objective half of the live gate's tone verification.
    private func noteSignal(_ pcm: [Float]) {
        let channels = AudioWire.channels
        var index = 0
        while index < pcm.count {
            let sample = pcm[index]            // left channel
            windowSumSquares += Double(sample) * Double(sample)
            if (sample > 0 && windowLastSample <= 0)
                || (sample < 0 && windowLastSample >= 0) {
                windowCrossings += 1
            }
            if sample != 0 { windowLastSample = sample }
            windowFrames += 1
            index += channels
        }
        guard windowFrames >= AudioWire.sampleRate else { return }
        let seconds = Double(windowFrames) / Double(AudioWire.sampleRate)
        let rms = (windowSumSquares / Double(windowFrames)).squareRoot()
        statsLock.lock()
        lastWindowRmsDbfs = rms > 0 ? 20 * log10(rms) : -Double.infinity
        lastWindowZeroCrossingHz = Double(windowCrossings) / 2 / seconds
        statsLock.unlock()
        windowSumSquares = 0
        windowFrames = 0
        windowCrossings = 0
    }
}
