// LyteAudioPlayer: AVAudioEngine out of a lock-free SPSC ring, fed by a
// pump that pulls verdicts from AudioReceiver and decodes on its own
// thread, never the render callback.
//
// The render callback consumes at the DAC's rate and the pump refills
// below the receiver's adaptive target, so playout locks to the hardware
// clock. The pump re-arms for the instant the ring could reach one packet,
// clamped to 2–10 ms. When the receiver says the pipe is overfull, decoded
// PCM drains through the WSOLA AudioAccelerator (≤5% fast). An output
// device change stops the engine; the source node is rebuilt on a serial
// queue while the ring survives, so playback resumes where it left off.

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
    /// dBFS and a zero-crossing frequency estimate.
    public var lastWindowRmsDbfs: Double = -Double.infinity
    public var lastWindowZeroCrossingHz: Double = 0
    public var decodeFailures: UInt64 = 0
    public var accelerate = AudioAccelerateStats()
    /// Output-device changes survived and rebuilds the device refused.
    public var routeChangesHandled: UInt64 = 0
    public var routeChangeFailures: UInt64 = 0

    public init() {}
}

/// The lock-free SPSC PCM ring the render callback reads and the pump
/// writes — its own class so the render block captures it, never the
/// player. Counters are monotonically increasing frame counts.
final class AudioPcmRing: @unchecked Sendable {
    static let capacityFrames = 48_000                        // 1 s
    let buffer: UnsafeMutablePointer<Float>
    let readCounter = Atomic<Int>(0)
    let writeCounter = Atomic<Int>(0)
    /// µs uptime of the last write, 0 once the host announces quiet;
    /// underruns count only while the stream is flowing (a blackout's
    /// silence and an announced quiet are not underruns).
    let lastWriteMicros = Atomic<UInt64>(0)
    let underrunFrames = Atomic<UInt64>(0)
    let framesRendered = Atomic<UInt64>(0)

    /// Declick: an underrun decays the boundary sample linearly to zero
    /// over ~2 ms and recovery crossfades back in over the same window, so
    /// output stays continuous. The state below is render-thread-only and
    /// preallocated.
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

    /// Render-thread side: fills the deinterleaved channel buffers of a
    /// standard-format source node (an interleaved mixer input raises an
    /// NSException). Shortfalls are declicked, never hard-cut.
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
        // After an episode the crossfade starts from the tail's current
        // value (zero, or mid-decay if recovery came sooner).
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
                // Decay tail: true zero from `fade` pad frames onward.
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

    /// Pump-thread side: the host announced the stream quiet, so the
    /// silence after the ring's content is contract; the next write
    /// resumes the underrun books.
    func noteAnnouncedQuiet() {
        lastWriteMicros.store(0, ordering: .relaxed)
    }
}

public final class LyteAudioPlayer: @unchecked Sendable {
    private let receiver: AudioReceiver
    private let decoder: OpusStreamDecoder
    private let ring = AudioPcmRing()

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var pump: DispatchSourceTimer?
    /// Serializes engine-graph mutations (start/stop/route rebuild).
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

    private let mutedFlag = Atomic<Bool>(false)
    /// Playback keeps consuming; only the mixer goes quiet. The volume is
    /// applied on the route queue under `engineLock`, so it never races a
    /// start or a route rebuild, and the setter never blocks its caller.
    public var muted: Bool {
        get { mutedFlag.load(ordering: .relaxed) }
        set {
            mutedFlag.store(newValue, ordering: .relaxed)
            routeQueue.async { [weak self] in self?.applyVolume() }
        }
    }

    private func applyVolume() {
        engineLock.lock()
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        engineLock.unlock()
    }

    public init(receiver: AudioReceiver) throws {
        self.receiver = receiver
        self.decoder = try OpusStreamDecoder()
    }

    /// Builds the graph and starts the engine and pump. The caller treats
    /// a refused audio device as non-fatal: video streams regardless.
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

        // A default-output switch stops the engine and posts this.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleOutputConfigurationChange()
        }

        // Adaptive one-shot cadence. A cancelled source never fires again,
        // so checking isCancelled makes a racing stop() safe without a lock.
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

    /// Microseconds until the ring, draining at the DAC rate, could reach
    /// one packet, clamped to [floor, ceiling]. Only the ring counts as
    /// headroom: the accelerator's gather is flushed only by a pump pass.
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

    /// The configuration-change handler; serialized on the route queue and
    /// safe against a racing stop().
    public func handleOutputConfigurationChange() {
        routeQueue.async { [weak self] in self?.rebuildOutput() }
    }

    /// Standard format (float32 deinterleaved); the closure captures the
    /// ring, never self.
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

    /// Rebuilds the graph on the new device; the ring and everything
    /// upstream are untouched.
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
        // Every attempt refused. The node stays attached so the next
        // configuration change retries this path.
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
            // The receiver judges ring + gather.
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
                if decision.announcedQuiet { ring.noteAnnouncedQuiet() }
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

    private func snapshotAccelBooks() {
        statsLock.lock()
        accelSnapshot = accelerator.stats
        statsLock.unlock()
    }

    /// Rolls window RMS (dBFS) and zero-crossing rate on the left channel
    /// once per second of fed audio.
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
