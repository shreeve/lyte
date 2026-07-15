import Foundation
import AVFoundation

/// AVAudioEngine + AVAudioSourceNode playback of interleaved Float32 PCM
/// through a lock-protected ring buffer. Underruns are counted (they feed the
/// doctor later — audio chop is the project's origin story).
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let channels: Int

    private let lock = NSLock()
    private var ring: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0

    public private(set) var underruns: UInt64 = 0
    /// Peak |sample| over the most recent enqueue — proves non-silence.
    public private(set) var lastPeak: Float = 0

    /// bufferDepthMs is the target queue depth; the ring holds up to 500 ms.
    init(channels: Int) {
        self.channels = channels
        self.ring = [Float](repeating: 0, count: 48_000 * channels / 2)   // 500 ms
    }

    func start() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: AVAudioChannelCount(channels), interleaved: false)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            self.lock.lock()
            let framesAvailable = self.available / self.channels
            let framesToCopy = min(frames, framesAvailable)
            if framesToCopy < frames { self.underruns += 1 }

            // Deinterleave ring → per-channel buffers; zero-fill shortfall
            for ch in 0..<min(self.channels, abl.count) {
                guard let out = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                var idx = self.readIndex + ch
                for f in 0..<frames {
                    if f < framesToCopy {
                        out[f] = self.ring[idx % self.ring.count]
                        idx += self.channels
                    } else {
                        out[f] = 0
                    }
                }
            }
            self.readIndex = (self.readIndex + framesToCopy * self.channels) % self.ring.count
            self.available -= framesToCopy * self.channels
            self.lock.unlock()
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    func setMuted(_ muted: Bool) {
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    /// Target queue depth (Work-mode policy ~50 ms). Exceeding the slack trims
    /// the oldest audio so we never drift far behind video. Real pacing is M7.
    var targetDepthMs = 50
    private let depthSlackMs = 30
    /// Adaptive growth: reception jitter (AWDL scans, shared-channel airtime)
    /// shows up as underruns without packet loss. Grow the target ~10 ms per
    /// second of continued underruns, up to a ceiling; the doctor (M6) will
    /// own the root cause.
    private let depthCeilingMs = 120
    private let depthFloorMs = 50            // policy base (Work mode)
    private var lastUnderrunCount: UInt64 = 0
    private var enqueuesSinceGrowth = 0
    private var cleanEnqueues = 0

    /// Push interleaved samples; drops the oldest data if the ring is full.
    func enqueue(_ samples: [Float]) {
        lock.lock()
        lastPeak = samples.reduce(into: Float(0)) { $0 = max($0, abs($1)) }
        enqueuesSinceGrowth += 1
        if underruns > lastUnderrunCount {
            if enqueuesSinceGrowth >= 200 {   // grow at most ~once per second
                enqueuesSinceGrowth = 0
                if targetDepthMs < depthCeilingMs { targetDepthMs += 10 }
            }
            lastUnderrunCount = underruns
            cleanEnqueues = 0
        } else {
            // Decay: after ~10 s without a single underrun, step back toward
            // the policy base — past jitter shouldn't tax present latency.
            cleanEnqueues += 1
            if cleanEnqueues >= 2000 {
                cleanEnqueues = 0
                if targetDepthMs > depthFloorMs { targetDepthMs -= 5 }
            }
        }
        let maxSamples = (targetDepthMs + depthSlackMs) * 48 * channels
        if available > maxSamples {
            let trim = available - targetDepthMs * 48 * channels
            readIndex = (readIndex + trim) % ring.count
            available -= trim
        }
        for s in samples {
            ring[writeIndex] = s
            writeIndex = (writeIndex + 1) % ring.count
            if available < ring.count {
                available += 1
            } else {
                readIndex = (readIndex + 1) % ring.count   // overwrite oldest
            }
        }
        lock.unlock()
    }

    /// Queued audio in milliseconds (for A/V sync checks and the ticker).
    public var queuedMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return available / channels * 1000 / 48_000
    }
}
