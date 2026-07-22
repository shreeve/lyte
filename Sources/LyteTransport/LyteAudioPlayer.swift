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
// The 2 ms pump cadence is deliberately faster than the 5 ms packet
// duration: scheduling jitter on the pump shows up as ring-depth
// ripple well inside one packet, and the `urgent` flag turns a
// nearly-dry ring into immediate PLC instead of zeros.

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

    init() {
        let count = Self.capacityFrames * AudioWire.channels
        buffer = .allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
    }

    deinit {
        buffer.deallocate()
    }

    var depthFrames: Int {
        writeCounter.load(ordering: .relaxed)
            - readCounter.load(ordering: .relaxed)
    }

    /// Render-thread side: fills the DEINTERLEAVED channel buffers the
    /// engine hands a standard-format source node (mixer inputs must
    /// be standard — an interleaved connection raises an NSException),
    /// zero-padding a shortfall (counted while the stream flows).
    func render(
        into buffers: UnsafeMutableAudioBufferListPointer, wanted: Int
    ) {
        let read = readCounter.load(ordering: .relaxed)
        let write = writeCounter.load(ordering: .acquiring)
        let available = min(wanted, write - read)
        let channels = AudioWire.channels
        for channel in 0..<min(channels, buffers.count) {
            guard let out = buffers[channel].mData?
                .assumingMemoryBound(to: Float.self)
            else { continue }
            for frame in 0..<available {
                let slot = ((read + frame) % Self.capacityFrames) * channels
                out[frame] = buffer[slot + channel]
            }
            for frame in available..<wanted {
                out[frame] = 0
            }
        }
        if available < wanted {
            let last = lastWriteMicros.load(ordering: .relaxed)
            let now = DispatchTime.now().uptimeNanoseconds / 1_000
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
            DispatchTime.now().uptimeNanoseconds / 1_000,
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

    // Pump-side state (pump thread only).
    private var packetsFed: UInt64 = 0
    private var plcPacketsFed: UInt64 = 0
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
        guard sourceNode == nil else { return }
        // The STANDARD format (float32 deinterleaved) — the only
        // format a mixer input accepts; the ring deinterleaves in the
        // render callback.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(AudioWire.sampleRate),
            channels: AVAudioChannelCount(AudioWire.channels)
        ) else {
            throw OpusStreamDecoderError.createFailed(-1)
        }

        let ring = ring
        let node = AVAudioSourceNode(format: format) {
            _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            ring.render(into: buffers, wanted: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        try engine.start()
        sourceNode = node

        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(2),
                       repeating: .milliseconds(2), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.pumpOnce() }
        timer.resume()
        pump = timer
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        if let node = sourceNode {
            engine.stop()
            engine.detach(node)
            sourceNode = nil
        }
    }

    public func snapshotStats() -> LyteAudioPlayerStats {
        var out = LyteAudioPlayerStats()
        out.underrunFrames = ring.underrunFrames.load(ordering: .relaxed)
        out.framesRendered = ring.framesRendered.load(ordering: .relaxed)
        out.ringDepthFrames = ring.depthFrames
        statsLock.lock()
        out.packetsFed = packetsFed
        out.plcPacketsFed = plcPacketsFed
        out.lastWindowRmsDbfs = lastWindowRmsDbfs
        out.lastWindowZeroCrossingHz = lastWindowZeroCrossingHz
        statsLock.unlock()
        out.decodeFailures = decoder.decodeFailures
        return out
    }

    // MARK: - The pump

    private func pumpOnce() {
        let capacity = AudioPcmRing.capacityFrames
        let packetFrames = AudioWire.samplesPerPacket
        while true {
            let depth = ring.depthFrames
            let target = max(receiver.targetDepthPackets, 1) * packetFrames
            guard depth < target, depth + packetFrames <= capacity else {
                return
            }
            let urgent = depth < packetFrames
            let pipelineMicros = UInt64(depth) * 1_000_000
                / UInt64(AudioWire.sampleRate)
            let now = ClientTimestamp(
                microseconds: DispatchTime.now().uptimeNanoseconds / 1_000)
            let pcm: [Float]
            switch receiver.pull(
                now: now, urgent: urgent,
                renderPipelineMicroseconds: pipelineMicros
            ) {
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
                return
            }
            ring.write(pcm)
            noteSignal(pcm)
        }
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
