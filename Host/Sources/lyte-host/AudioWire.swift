// AudioWire: lyte-host's audio leg — PipeWire monitor capture → exact
// 5 ms slices → HostAudio's hard-CBR Opus encoder →
// SessionWire.sendAudioPacket (AudioFramer, RS 4+2, the shared pacer,
// TOS 0xC0 / DSCP 48).
//
// Routing postures: hostAudible (default) captures the DEFAULT sink's
// monitor, so the host's speakers keep playing. hostMuted has the C leaf
// create the "Lyte Audio" virtual sink, make it the default and capture
// ITS monitor. The sink is connection-owned (a SIGKILL cannot leak it);
// only the default-sink metadata can be stranded, so the ORIGINAL value is
// persisted to a state file at the switch, removed after a clean restore,
// and swept on the next start (`AudioWire.sweepLeftoverRouting`).
//
// Threading: CPipeWireAudio's pw_main_loop runs on a dedicated thread (the
// 5 ms cadence cannot ride the video tick). All slicing/encoding state is
// confined to it; the only cross-thread touches are the SessionWire audio
// mailbox and the stop flag. Packets are stamped on the graph clock, never
// the wall clock (InterleavedPcmSlicer).

import CPipeWireAudio
import Foundation
import HostAudio
import HostCore
import HostIO
import HostWire
import LyteWire

/// @unchecked Sendable: the run thread's closure crosses a @Sendable
/// boundary on Linux Foundation, but every mutable property is confined
/// to the audio loop thread; the evidence counters are read only after
/// `stop()` joins.
final class AudioWire: @unchecked Sendable {
    /// Where a dirty previous run's original default sink waits for
    /// the sweep: host state, never beside the identity files.
    static let routingStateName = "audio_default_sink.prev"
    static func routingStatePath() throws -> String {
        try HostPaths.current().state(routingStateName)
    }
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
    /// The auto-quiet gate. Engages ONLY when the session agreed key 15,
    /// checked per packet.
    private var tripwire = AudioTripwire()

    // Evidence, read after join.
    private(set) var packetsEncoded = 0
    private(set) var encodeFailures = 0
    private(set) var negotiated: (rate: UInt32, channels: UInt32)?
    private(set) var negotiationError: String?
    private(set) var runError: String?
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
        // From here on the throw paths free NOTHING: every stored
        // property is initialized, so a `throw` runs deinit, which owns
        // cleanup (an explicit free would be a double free).
        guard let cap = lyte_pw_audio_new(audioWireTrampoline, user,
                                          mode == .hostMuted ? 1 : 0,
                                          &err, err.count) else {
            throw HostError("pipewire audio setup: \(errString(err))")
        }
        capture = cap
        // The crash ledger: the original default is on disk BEFORE any
        // session traffic, so a kill -9 is recoverable by the next sweep.
        if mode == .hostMuted {
            var saved = [CChar](repeating: 0, count: 512)
            let rc = lyte_pw_audio_saved_default(cap, &saved, saved.count)
            let record = rc == 1 ? errString(saved) : Self.unsetSentinel
            do {
                let paths = try HostPaths.current()
                try SecretFile.write(
                    Array(record.utf8), to: paths.state(Self.routingStateName))
            } catch {
                // Refuse the posture rather than run un-restorable.
                // No frees here — deinit owns them.
                throw HostError("""
                    cannot persist the original default \
                    sink for crash restore (\(error)) — refusing \
                    hostMuted
                    """)
            }
            print("""
                audio: routing hostMuted — \"Lyte Audio\" sink is the \
                default; original \
                \(rc == 1 ? errString(saved) : "(unset)")\
                 recorded for restore
                """)
        }
    }

    deinit {
        // Never free while the audio thread lives (stop() may not have
        // run): the trampoline's unretained pointer would dangle. Join
        // first; the run loop's `seconds` deadline bounds the wait.
        if thread != nil, let capture {
            lyte_pw_audio_quit(capture)
            finished.wait()
        }
        restoreRouting()
        if let capture { lyte_pw_audio_free(capture) }
    }

    private var routingRestored = false

    /// Puts the original default sink back and clears the crash
    /// ledger. Idempotent (the C leaf also restores inside free).
    private func restoreRouting() {
        guard mode == .hostMuted, let capture, !routingRestored else { return }
        routingRestored = true
        var err = [CChar](repeating: 0, count: 256)
        if lyte_pw_audio_restore(capture, &err, err.count) == 0 {
            if let path = try? Self.routingStatePath() { unlink(path) }
            print("audio: routing restored — original default sink back")
        } else {
            // The state file stays for the next-start sweep.
            print("""
                audio: routing restore FAILED (\(errString(err))) — \
                state file kept for the next-start sweep
                """)
        }
    }

    /// The next-start sweep: restores the default sink a previous run
    /// died without restoring, before anything else touches audio. Call
    /// once at session start, any routing mode. A pre-XDG ledger in
    /// ~/.config/lyte-host is honored and consumed the same way.
    static func sweepLeftoverRouting() {
        guard let paths = try? HostPaths.current() else { return }
        var ledger: (path: String, bytes: [UInt8])?
        for path in [
            paths.state(routingStateName),
            paths.legacyConfig(routingStateName),
        ] {
            if let bytes = try? SecretFile.read(path) {
                ledger = (path, bytes)
                break
            }
        }
        guard let ledger else {
            return // clean previous shutdown — nothing recorded
        }
        let record = String(decoding: ledger.bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var err = [CChar](repeating: 0, count: 256)
        let rc = record == unsetSentinel
            ? lyte_pw_audio_restore_default(nil, &err, err.count)
            : lyte_pw_audio_restore_default(record, &err, err.count)
        if rc == 0 {
            unlink(ledger.path)
            print("""
                audio: swept a dirty previous run — default sink \
                restored to \
                \(record == unsetSentinel ? "(unset)" : record)
                """)
        } else {
            print("""
                audio: leftover-routing sweep FAILED \
                (\(errString(err))) — state file kept; restore by \
                hand with wpctl set-default
                """)
        }
    }

    /// Runs the audio capture loop on its own thread for up to
    /// `seconds` (+ slack; `stop()` is the real exit).
    func start(seconds: Double) {
        guard capture != nil else { return }
        let thread = Thread { [self] in
            // The 5 ms Opus cadence is the host's tightest deadline.
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

    /// Quits the audio loop (thread-safe eventfd), JOINS the thread
    /// unconditionally — lyte_pw_audio_run's `seconds` deadline bounds
    /// the wait — then restores the routing.
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
                    """
                        negotiated \(rate) Hz \(chans)ch, need \
                        \(sampleRate)/\(channels)
                        """
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
        // The tripwire's RMS, taken before the borrowed slice returns.
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

        // Capture never stops: the gate is transmission-side, and only
        // under the key-15 agreement (read under the config lock).
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
            // Announce first, then the pre-roll (which ends with this
            // packet), so numbering stays contiguous and the onset plays.
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
