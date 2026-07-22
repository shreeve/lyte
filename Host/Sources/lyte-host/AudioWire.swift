// AudioWire (HS-15): lyte-host's audio leg — the HS-14 capture/encode
// path (CPipeWireAudio monitor capture → exact 5 ms slices → COpusEncode
// hard CBR) feeding SessionWire.sendAudioPacket, which runs the packet
// through AudioFramer / RS 4+2 / the shared pacer / CNetIO with per-
// packet TOS 0xC0 (CS6 / DSCP 48 — the tos(for:) map already routes
// PacerClass.audio there).
//
// Threading: CPipeWireAudio owns its own pw_main_loop, run here on a
// dedicated Thread — the 5 ms cadence cannot ride the video loop's
// ~16.7 ms tick. All slicing/encoding state below is confined to that
// audio loop thread; the only cross-thread touch is sendAudioPacket
// (locked inside SessionWire) and the stop flag. The slicing and
// graph-clock timestamp bookkeeping are lyte-audio-check's, verbatim in
// spirit: a packet is stamped by the buffer its FIRST sample arrived
// in, advanced by the sample offset within it — pure graph clock,
// never wall clock (audio-continuity §4.3).

import COpusEncode
import CPipeWireAudio
import Foundation

/// @unchecked Sendable: the run thread's closure crosses a @Sendable
/// boundary on Linux Foundation, but every mutable property is confined
/// to the audio loop thread; the evidence counters are read only after
/// `stop()` joins.
final class AudioWire: @unchecked Sendable {
    private let wire: SessionWire
    private var capture: OpaquePointer?
    private let encoder: OpaquePointer
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    private let packetFrames = Int(LYTE_OPUS_FRAME) // 240 = 5 ms
    private let channels = Int(LYTE_OPUS_CHANNELS)
    private let sampleRate = Int(LYTE_OPUS_RATE)

    // Audio-loop-thread state (never touched from outside).
    private var pending: [Float] = []
    private var pendingStartFrame = 0
    private var marks: [(startFrame: Int, us: UInt64)] = []
    private var framesSeen = 0
    private var packet = [UInt8]()

    // Evidence, read after join.
    private(set) var packetsEncoded = 0
    private(set) var encodeFailures = 0
    private(set) var negotiated: (rate: UInt32, channels: UInt32)?
    private(set) var negotiationError: String?
    private(set) var runError: String?

    init(wire: SessionWire, bitrate: Int32) throws {
        self.wire = wire
        var err = [CChar](repeating: 0, count: 256)
        guard let enc = lyte_opus_enc_new(bitrate, 0, &err, err.count) else {
            throw HostError("opus encoder: \(errString(err))")
        }
        encoder = enc
        packet = [UInt8](repeating: 0, count: Int(LYTE_OPUS_MAX_PACKET))
        pending.reserveCapacity(8_192)
        let user = Unmanaged.passUnretained(self).toOpaque()
        guard let cap = lyte_pw_audio_new(audioWireTrampoline, user,
                                          &err, err.count) else {
            lyte_opus_enc_free(enc)
            throw HostError("pipewire audio setup: \(errString(err))")
        }
        capture = cap
    }

    deinit {
        if let capture { lyte_pw_audio_free(capture) }
        lyte_opus_enc_free(encoder)
    }

    /// Runs the audio capture loop on its own thread for up to
    /// `seconds` (+ slack; `stop()` is the real exit).
    func start(seconds: Double) {
        guard capture != nil else { return }
        let thread = Thread { [self] in
            var err = [CChar](repeating: 0, count: 256)
            let rc = lyte_pw_audio_run(self.capture, seconds,
                                       &err, err.count)
            if rc < 0 { self.runError = errString(err) }
            self.finished.signal()
        }
        thread.name = "lyte-audio"
        self.thread = thread
        thread.start()
    }

    /// Quits the audio loop and waits for the thread. pw_main_loop_quit
    /// signals the loop's eventfd — safe from another thread.
    func stop() {
        guard thread != nil, let capture else { return }
        lyte_pw_audio_quit(capture)
        _ = finished.wait(timeout: .now() + 2)
        thread = nil
    }

    /// The capture callback (audio loop thread): buffer in, zero or
    /// more exact 5 ms packets out through the session.
    fileprivate func onAudio(
        samples: UnsafePointer<Float>, nFrames: UInt32,
        chans: UInt32, rate: UInt32, graphUS: UInt64
    ) {
        if negotiated == nil {
            negotiated = (rate, chans)
            if rate != UInt32(sampleRate) || chans != UInt32(channels) {
                negotiationError =
                    "negotiated \(rate) Hz \(chans)ch, need "
                    + "\(sampleRate)/\(channels)"
                if let capture { lyte_pw_audio_quit(capture) }
                return
            }
        }
        guard negotiationError == nil else { return }

        marks.append((startFrame: framesSeen, us: graphUS))
        framesSeen += Int(nFrames)
        pending.append(contentsOf: UnsafeBufferPointer(
            start: samples, count: Int(nFrames) * channels))

        while pending.count >= packetFrames * channels {
            emitPacket()
        }
    }

    private func emitPacket() {
        // Timestamp: the mark of the buffer containing this packet's
        // first sample, advanced by the sample offset within it.
        let startFrame = pendingStartFrame
        var ts: UInt64 = 0
        while marks.count > 1, marks[1].startFrame <= startFrame {
            marks.removeFirst()
        }
        if let m = marks.first {
            ts = m.us + UInt64(startFrame - m.startFrame)
                * 1_000_000 / UInt64(sampleRate)
        }

        var err = [CChar](repeating: 0, count: 256)
        let n = pending.withUnsafeBufferPointer { pcm in
            lyte_opus_enc_encode(encoder, pcm.baseAddress, &packet,
                                 Int32(packet.count), &err, err.count)
        }
        pending.removeFirst(packetFrames * channels)
        pendingStartFrame += packetFrames

        guard n > 0 else {
            encodeFailures += 1
            if encodeFailures == 1 {
                print("audio: opus encode failed: \(errString(err))")
            }
            return
        }
        packetsEncoded += 1
        wire.sendAudioPacket(Array(packet.prefix(Int(n))), captureMicros: ts)
    }
}

private func audioWireTrampoline(
    user: UnsafeMutableRawPointer?, samples: UnsafePointer<Float>?,
    nFrames: UInt32, chans: UInt32, rate: UInt32, graphUS: UInt64
) {
    guard let user, let samples else { return }
    let audio = Unmanaged<AudioWire>.fromOpaque(user).takeUnretainedValue()
    audio.onAudio(samples: samples, nFrames: nFrames, chans: chans,
                  rate: rate, graphUS: graphUS)
}
