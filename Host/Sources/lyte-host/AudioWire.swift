// AudioWire (HS-15): lyte-host's audio leg — the HS-14 capture/encode
// path (CPipeWireAudio monitor capture → exact 5 ms slices → HostAudio's
// Swift hard-CBR encoder) feeding SessionWire.sendAudioPacket, which runs
// the packet through AudioFramer / RS 4+2 / the shared pacer / CNetIO with
// per-packet TOS 0xC0 (CS6 / DSCP 48 — the tos(for:) map already routes
// PacerClass.audio there).
//
// HS-18 routing: the leaf now runs in one of two postures. hostAudible
// (default) captures the DEFAULT sink's monitor — the host's speakers
// keep playing. hostMuted has the C leaf create the "Lyte Audio"
// virtual sink, switch the system default to it, and capture ITS
// monitor — the wire hears everything, the room hears nothing. The
// sink itself is connection-owned (a SIGKILL cannot leak it); the one
// stranded thing a crash can leave is the default-sink metadata, so
// the ORIGINAL value is persisted to a state file the moment the
// switch happens, removed after a clean restore, and swept on the
// next start (`AudioWire.sweepLeftoverRouting`).
//
// Threading: CPipeWireAudio owns its own pw_main_loop, run here on a
// dedicated Thread — the 5 ms cadence cannot ride the video loop's
// ~16.7 ms tick. All slicing/encoding state below is confined to that
// audio loop thread; the only cross-thread touch is sendAudioPacket
// (locked inside SessionWire) and the stop flag. The slicing and
// graph-clock timestamp bookkeeping have one sans-IO HostCore owner shared
// with lyte-audio-check: a packet is stamped by the buffer its FIRST sample
// arrived in, advanced by the sample offset within it — pure graph clock,
// never wall clock (audio-continuity §4.3).

import CPipeWireAudio
import Foundation
import HostAudio
import HostCore
import HostWire
import LyteWire

/// @unchecked Sendable: the run thread's closure crosses a @Sendable
/// boundary on Linux Foundation, but every mutable property is confined
/// to the audio loop thread; the evidence counters are read only after
/// `stop()` joins.
final class AudioWire: @unchecked Sendable {
    /// Where a dirty previous run's original default sink waits for
    /// the sweep. Beside the sacred three, never one of them.
    static let routingStatePath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyte-host/audio_default_sink.prev")
    /// The state-file sentinel for "the key was unset before us".
    private static let unsetSentinel = "<unset>"

    let mode: HostAudioRoutingMode
    private let wire: SessionWire
    private var capture: OpaquePointer?
    private let encoder: HostOpusEncoder
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    private let packetFrames = HostOpus.framesPerPacket
    private let channels = HostOpus.channels
    private let sampleRate = HostOpus.sampleRate

    // Audio-loop-thread state (never touched from outside).
    private let slicer: InterleavedPcmSlicer
    private var packet = [UInt8]()
    /// The postures design's auto-quiet gate (audio-thread confined;
    /// counters read after join). Engages ONLY when the session agreed
    /// key 15 — checked per packet, so a legacy client keeps the
    /// always-on contract and a fresh session re-decides.
    private var tripwire = AudioTripwire()

    // Evidence, read after join.
    private(set) var packetsEncoded = 0
    private(set) var encodeFailures = 0
    private(set) var negotiated: (rate: UInt32, channels: UInt32)?
    private(set) var negotiationError: String?
    private(set) var runError: String?
    /// Tripwire evidence — like the counters above, read after join.
    var tripwireCounters: AudioTripwireCounters { tripwire.counters }

    init(
        wire: SessionWire, bitrate: Int32,
        mode: HostAudioRoutingMode = .hostAudible
    ) throws {
        self.wire = wire
        self.mode = mode
        do {
            encoder = try HostOpusEncoder(bitrate: bitrate)
        } catch {
            throw HostError("opus encoder: \(error)")
        }
        packet = [UInt8](repeating: 0, count: HostOpus.maxPacketBytes)
        slicer = InterleavedPcmSlicer(
            sampleRate: sampleRate,
            channels: channels,
            packetFrames: packetFrames
        )
        var err = [CChar](repeating: 0, count: 256)
        let user = Unmanaged.passUnretained(self).toOpaque()
        // From here on the throw paths free NOTHING: once `encoder` is
        // assigned every stored property is initialized, so a later
        // `throw` runs deinit — an explicit free here would be the
        // first half of a double free (v1-final analysis, finding 3b:
        // a host with no default sink aborted in free() instead of
        // degrading to the video-only session). deinit owns cleanup.
        guard let cap = lyte_pw_audio_new(audioWireTrampoline, user,
                                          mode == .hostMuted ? 1 : 0,
                                          &err, err.count) else {
            throw HostError("pipewire audio setup: \(errString(err))")
        }
        capture = cap
        // The crash ledger: the original default is on disk BEFORE any
        // session traffic — a kill -9 from here on is recoverable by
        // the next start's sweep. (The sink itself dies with the
        // connection; only this metadata value can be stranded.)
        if mode == .hostMuted {
            var saved = [CChar](repeating: 0, count: 512)
            let rc = lyte_pw_audio_saved_default(cap, &saved, saved.count)
            let record = rc == 1 ? errString(saved) : Self.unsetSentinel
            do {
                try Data(record.utf8).write(to: Self.routingStatePath)
            } catch {
                // Refuse the posture rather than run un-restorable: a
                // crash would strand the user's default sink silently.
                // No frees here — deinit restores the routing and
                // frees capture + encoder exactly once (finding 3b).
                throw HostError("cannot persist the original default "
                    + "sink for crash restore (\(error)) — refusing "
                    + "hostMuted")
            }
            print("audio: routing hostMuted — \"Lyte Audio\" sink is the "
                + "default; original "
                + (rc == 1 ? errString(saved) : "(unset)")
                + " recorded for restore")
        }
    }

    deinit {
        // Refuse to free while the audio thread lives (v1-final
        // analysis, finding 3a): if the owner never reached stop() —
        // e.g. a throw between start() and the teardown unwinding
        // main's run() — freeing the pw_main_loop here would hand the
        // trampoline's passUnretained pointer a freed object on the
        // next 5 ms callback. Join first; the C run loop's own
        // `seconds` deadline bounds the wait even if the quit eventfd
        // were lost.
        if thread != nil, let capture {
            lyte_pw_audio_quit(capture)
            finished.wait()
        }
        restoreRouting()
        if let capture { lyte_pw_audio_free(capture) }
    }

    private var routingRestored = false

    /// Puts the original default sink back and clears the crash
    /// ledger. Idempotent; also runs from deinit (the C leaf restores
    /// inside free as its own backstop).
    private func restoreRouting() {
        guard mode == .hostMuted, let capture, !routingRestored else { return }
        routingRestored = true
        var err = [CChar](repeating: 0, count: 256)
        if lyte_pw_audio_restore(capture, &err, err.count) == 0 {
            try? FileManager.default.removeItem(at: Self.routingStatePath)
            print("audio: routing restored — original default sink back")
        } else {
            // The state file deliberately stays: the sweep finishes
            // the job on the next start.
            print("audio: routing restore FAILED (\(errString(err))) — "
                + "state file kept for the next-start sweep")
        }
    }

    /// The next-start sweep: a previous run that died without
    /// restoring (kill -9) left the original default sink recorded
    /// here — put it back before anything else touches audio. The
    /// dead run's sink never survives (connection-owned), so this is
    /// purely the metadata restore. Call once at session start, any
    /// routing mode.
    static func sweepLeftoverRouting() {
        guard let data = try? Data(contentsOf: routingStatePath) else {
            return // clean previous shutdown — nothing recorded
        }
        let record = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var err = [CChar](repeating: 0, count: 256)
        let rc = record == unsetSentinel
            ? lyte_pw_audio_restore_default(nil, &err, err.count)
            : lyte_pw_audio_restore_default(record, &err, err.count)
        if rc == 0 {
            try? FileManager.default.removeItem(at: routingStatePath)
            print("audio: swept a dirty previous run — default sink "
                + "restored to "
                + (record == unsetSentinel ? "(unset)" : record))
        } else {
            print("audio: leftover-routing sweep FAILED "
                + "(\(errString(err))) — state file kept; restore by "
                + "hand with wpctl set-default")
        }
    }

    /// Runs the audio capture loop on its own thread for up to
    /// `seconds` (+ slack; `stop()` is the real exit).
    func start(seconds: Double) {
        guard capture != nil else { return }
        let thread = Thread { [self] in
            // The 5 ms Opus cadence (± 2 ms bound) owns this thread —
            // the tightest deadline in the host, hence the top rung.
            elevateCurrentThread("audio-capture", rtPriority: 12)
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

    /// Quits the audio loop and JOINS the thread — unconditionally
    /// (v1-final analysis, finding 3a: the old 2 s timeout proceeded
    /// regardless, and the eventual free ran under the still-live
    /// audio thread). The wait is bounded even if the quit signal
    /// were ever lost: lyte_pw_audio_run's own `seconds` deadline
    /// exits the loop and signals `finished`. Then restores the
    /// routing promptly (deinit is the backstop, not the plan).
    /// pw_main_loop_quit signals the loop's eventfd — safe from
    /// another thread.
    func stop() {
        guard thread != nil, let capture else { return }
        lyte_pw_audio_quit(capture)
        finished.wait()
        thread = nil
        restoreRouting()
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

        slicer.ingest(
            UnsafeBufferPointer(
                start: samples, count: Int(nFrames) * channels
            ),
            graphStartMicroseconds: graphUS
        ) { pcm, timestamp in
            emitPacket(pcm: pcm, timestamp: timestamp)
        }
    }

    private func emitPacket(
        pcm: UnsafeBufferPointer<Float>, timestamp: UInt64
    ) {
        // The tripwire's ear: RMS over this packet's PCM, taken
        // before the borrowed slice returns. ~480 floats at 200/s —
        // noise next to the Opus encode beside it.
        let sampleCount = packetFrames * channels
        var sumSquares: Float = 0
        for i in 0..<sampleCount {
            sumSquares += pcm[i] * pcm[i]
        }
        let rms = (sumSquares / Float(sampleCount)).squareRoot()

        let n: Int
        do {
            n = try encoder.encode(pcm, into: &packet)
        } catch {
            encodeFailures += 1
            if encodeFailures == 1 {
                print("audio: opus encode failed: \(error)")
            }
            return
        }
        packetsEncoded += 1
        let encoded = Array(packet.prefix(n))

        // Capture never stops — the gate is transmission-side, and it
        // exists at all only under the key-15 agreement (per-packet
        // check: cheap locked read, and a fresh session re-decides).
        guard wire.audioQuietPostureAgreed() else {
            wire.sendAudioPacket(encoded, captureMicros: timestamp)
            return
        }
        switch tripwire.ingest(
            rms: rms, packet: encoded, captureMicroseconds: timestamp
        ) {
        case .transmit:
            wire.sendAudioPacket(encoded, captureMicros: timestamp)
        case .beginQuiet:
            wire.sendAudioTrackState(.quiet)
        case .stayQuiet(let checkIn):
            if checkIn { wire.sendAudioTrackState(.quiet) }
        case .wake(let preRoll):
            // Announce first, then the burst — the ring already ends
            // with this packet, numbering stays contiguous, and the
            // client's parked cursor plays the onset intact.
            wire.sendAudioTrackState(.active)
            for held in preRoll {
                wire.sendAudioPacket(
                    held.bytes, captureMicros: held.captureMicroseconds)
            }
        }
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
