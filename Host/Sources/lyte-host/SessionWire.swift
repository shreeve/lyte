// SessionWire: lyte-host's Lyte-UDP session leg (HS-7's Linux half, thin
// over HostWire.Session — which owns the Noise responder handshake, the
// seal discipline, the 1 Hz beacon, the conn-id TLV, path validation, and
// the shared pacer). This file is only syscalls and scheduling: CNetIO
// bind/connect, recvmmsg → Session.receive with real source tuples,
// Session's paced datagrams → sendmmsg with per-class TOS (HostCore's
// WireTos policy: ctrl/audio/repairs 0xC0 CS6, video 0xA0 CS5 — DSCP 40
// per packet is J-G1's tcpdump check), and the forced-IDR + VBV polls
// the encoder consults before each frame.
//
// Modes (extending HS-5's --wire-out into a real session):
//   • Noise (default): bind, print the host static public key, block
//     until a client's IK message 1 arrives (that datagram's source is
//     the session's initial validated tuple), connect() to it, complete
//     the handshake, then stream. `--wire-listen PORT` binds a fixed
//     port; `--wire-out HOST:PORT` pre-connects and still awaits msg1.
//   • `--insecure` (CP-3 fallback, §4.1): stream to the fixed peer
//     immediately, passthrough seal — same wiring, mandatory re-gate.
//
// Threading honesty, amended at HS-15 and again at the fps-ceiling fix:
// the VIDEO PipeWire loop thread runs capture → encode → sendFrame
// (ingest only) and the idle-floor tick's service pass; audio arrives on
// ITS OWN PipeWire loop thread (CPipeWireAudio owns a separate
// pw_main_loop) at the 5 ms cadence — a cadence the ~16.7 ms video tick
// could never honor, which is exactly why audio cannot funnel through
// the video thread. One NSLock therefore guards the (single-threaded by
// design) Session and the outbox: every service pass holds it, every
// sleep releases it. The hold times are tens of µs (one pacer batch +
// one sendmmsg), so the audio thread's 5 ms cadence never waits
// meaningfully — the in-tree virtual-time gate bounds the pacer's share
// and the live tcpdump gate bounds the whole.
//
// THE FPS-CEILING FIX (Q-1's red row, hunted 2026-07-29): sendFrame
// used to drain the pacer to empty before returning — the capture
// thread paid the frame's full wire serialization time (~8·bytes/rate:
// ~11 ms for a 61 KB motion frame at 50 Mbps) IN SERIES with the ~7 ms
// NVENC encode, so the loop cycled at ~21 ms and the compositor only
// got a buffer back ~48 times a second. The drain now runs on a
// DEDICATED SENDER THREAD (`drainLoop`, parked on a condition variable
// while the pacer is idle): sendFrame ingests, signals, and returns in
// ~1.5 ms, so capture+encode of frame N+1 overlaps the wire time of
// frame N. Backpressure moved with it: the capture loop consults
// `videoBacklogWireTimeNS` pre-encode and SKIPS a capture frame while
// more than the resiliency bound of video wire-time is queued — the
// same frame the old synchronous drain silently starved out of the
// PipeWire buffer pool, now counted and cheap (no encode is spent on
// it). `--no-idle-floor` still stalls beacons between damage frames
// while the pacer is empty (the documented stub limitation).
//
// HS-12 rebind wiring: media re-routing executes .promoted by
// connect()ing to the new tuple, and challenges to unvalidated tuples
// ride lyte_netio_send_to (per-datagram address + TOS on the connected
// socket) — the exact-tuple rule §6 demands. The live G7 roam run is
// still owed when a second client address exists to roam to.

import CNetIO
import Foundation
import HostCore
import HostWire
import LyteWire

func monotonicNS() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

/// Host µs for envelope timestamps and beacon t1/t4: CLOCK_MONOTONIC —
/// the same family capture.c's graph_us chain bottoms out in, so beacon
/// offsets and capture stamps share a domain.
func monotonicMicros() -> UInt64 {
    monotonicNS() / 1_000
}

final class SessionWire {
    private let netio: OpaquePointer
    private var session: Session!
    /// HS-15: serializes Session/outbox access between the video
    /// capture loop thread and the audio capture loop thread (see the
    /// threading note in the header). Held across service passes,
    /// released across sleeps.
    private let lock = NSLock()
    private let insecure: Bool
    private let rateBitsPerSecond: Int
    /// What this host declares in the W7 exchange (HS-18: key 9 rides
    /// here when the audio leg is on).
    private let capabilities: Capabilities
    /// HS-9: non-nil = only these client statics may complete message 1
    /// (the paired set, loaded from the keystore by --require-paired).
    private let allowedClientStatics: [[UInt8]]?
    /// HS-21: the pre-handshake flood throttle + require-cookie dial
    /// config, threaded into every session this shell makes.
    private let handshakeGateConfig: HandshakeGate.Config
    /// HS-9: non-nil = pairing mode. The service consumes the pairing
    /// CTRL types off the reliable stream; replies ride sendReliable.
    private let pairing: PairingResponderService?
    private let onPairingEvent: (PairingResponderService.Event) -> Void

    /// Datagrams handed over by the session's paced sink, flushed as
    /// sendmmsg batches.
    private var outbox: [VideoChannelDatagram] = []

    /// Scratch for one sendmmsg batch: pointers must stay valid for the
    /// duration of the call, so datagrams are staged here.
    private let scratch: UnsafeMutablePointer<UInt8>
    private static let scratchCapacity = Int(LYTE_NETIO_MAX_BATCH) * 1_200

    /// One flat region for recv_batch slots (stable pointers, one slot
    /// stride per batch position).
    private let recvScratch: UnsafeMutablePointer<UInt8>
    private static let recvSlotCapacity = 2_048

    /// HS-13: the injection sink for client input events. Nil = input
    /// disabled (counted loud, never fatal). Set by main after the
    /// backend policy runs.
    var inputInjector: InputInjector?

    /// HS-18: the shell's audio-leaf flipper — stop the leaf, bring it
    /// back in the requested routing, return whether it stuck. Nil =
    /// no flip surface this run (requests answered with the standing
    /// posture). Set by main once audio is up. Called OFF the session
    /// lock: a flip is a PipeWire connect (milliseconds, and it must
    /// not stall the 5 ms audio thread against the lock).
    var audioRoutingHandler: ((HostAudioRoutingMode) -> Bool)?

    /// HS-19: the shell's clipboard-apply sink (the leaf's
    /// SetSelection). Nil = no leaf this run — the session core never
    /// surfaces 0x1A then anyway (key 10 undeclared), so the arm is
    /// defensive. Called OFF the session lock: SetSelection is a
    /// blocking D-Bus round-trip.
    var clipboardApplyHandler: ((String) -> Void)?
    /// P-1: the image half of the same sink (the leaf's SetSelection
    /// with the PNG flavor). Same off-lock discipline.
    var clipboardImageApplyHandler: (([UInt8]) -> Void)?
    /// HS-19: the leaf's off-lock service pass (D-Bus signal drain +
    /// fd transfer pumps), run once per `service()` like the routing
    /// work — never under the lock, never on the audio thread.
    var clipboardServiceHook: (() -> Void)?
    /// 0x1A texts delivered by the session (under the lock), awaiting
    /// the shell's apply outside it (drained by `service()`).
    private var pendingClipboardApplies: [String] = []
    /// P-1: sha-verified images delivered by the session (under the
    /// lock), awaiting the leaf apply outside it.
    private var pendingClipboardImageApplies: [[UInt8]] = []

    /// F-3: the file-drop shell. Nil = the standing consent toggle is
    /// OFF this run — the session core never surfaces bulk messages
    /// then anyway (key 11 undeclared, chan 8 drops loud), so the arm
    /// is defensive. Driven OFF the session lock: every store action
    /// is a pwrite + fsync and the verify is a whole-file hash.
    var bulkShell: BulkReceiveShell?
    /// Chan-8 messages delivered by the session (under the lock),
    /// awaiting the shell's disk work outside it (drained by
    /// `service()`).
    private var pendingBulkMessages: [BulkMessage] = []
    /// The posture the audio leaf is actually running (main seeds it;
    /// applied flips move it). Mutated under `lock`.
    private(set) var currentAudioRouting: HostAudioRoutingMode = .hostAudible
    /// 0x18 requests delivered by the session, awaiting the shell's
    /// flip outside the lock (drained by `service()`).
    private var pendingAudioRouting: [HostAudioRoutingMode] = []
    /// Set at capability agreement when hostAudioRouting survived the
    /// intersection: the client is owed one starting-posture 0x19.
    private var routingAnnounceOwed = false
    /// receive→inject per event, µs (the HS-13 p99 < 2 ms gate edge).
    private(set) var inputLatency = Histogram()
    private(set) var inputInjected = 0
    private(set) var inputInjectFailures = 0
    private var inputNoInjectorWarned = false

    private(set) var framesSent = 0
    /// Stage books for the fps-ceiling hunt (Q-1's red row): the last
    /// sendFrame's packetize+FEC+seal time and its pacer-drain time,
    /// split so the Sink's 5 s stage window can say where the frame
    /// period went. Written and read on the video loop thread only.
    private(set) var lastFrameIngestNanos: UInt64 = 0
    private(set) var lastFrameDrainNanos: UInt64 = 0
    /// HS-15 audio-thread counters (mutated under `lock`).
    private(set) var audioPacketsSent = 0
    private(set) var audioSendFailures = 0
    private(set) var audioPacketsDroppedPreSession = 0
    private(set) var datagramsSent = 0
    private(set) var bytesSent = 0
    private(set) var challengesSentOffPrimary = 0
    private(set) var lastSendError: String?
    /// HS-16 log throttle: the last rate a `rate:` line reported.
    private var lastPrintedRate: Int?
    /// HS-20: the encoder-VBV policy (armed by main once the encoder's
    /// opening posture is known) and its evidence counters. Mutated
    /// under `lock`.
    private var vbvPolicy: EncoderVbvPolicy?
    private(set) var vbvDirectivesIssued = 0
    private(set) var lastVbvDirective: EncoderRateDirective?
    /// HS-27 books: estimator moves the rung ladder absorbed — the
    /// pacer carried them alone, zero encoder resets, zero IDRs.
    var vbvRateMovesAbsorbed: Int {
        lock.lock()
        defer { lock.unlock() }
        return vbvPolicy?.rateMovesAbsorbed ?? 0
    }
    /// ECONNREFUSED evidence (LYTE_NETIO_PEER_GONE): the client's socket
    /// is closed — session-ending, not an I/O failure (HS-11).
    private(set) var peerGone = false

    /// The sender thread (the fps-ceiling fix): parks on `drainCondition`
    /// while the pacer is idle; `signalDrain()` wakes it whenever bytes
    /// were enqueued. It runs the exact drainToIdle loop the capture
    /// thread used to run inline.
    private let drainCondition = NSCondition()
    private var drainWork = false
    private var drainStop = false
    private var drainExited = false
    /// A drain-thread send failure (not peer-gone — that has its own
    /// flag): recorded loud and session-ending, mirroring what a thrown
    /// sendFrame used to do to the capture loop.
    private var drainFailed = false

    /// True once nothing more can usefully happen: the peer's socket is
    /// closed, or the lifecycle machine reached `closed` (teardown either
    /// way, or the 30 s liveness timeout). The capture loop quits on it.
    var sessionEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        if peerGone || session?.lifecycleState == .closed { return true }
        drainCondition.lock()
        defer { drainCondition.unlock() }
        return drainFailed
    }

    var counters: VideoChannelCounters { session.videoCounters }
    var sessionCounters: SessionCounters { session.counters }
    /// P-1: the image lane's books (share/apply/refuse verdicts).
    var clipboardImageCounters: ClipboardImageChannelCounters {
        session.clipboardImageCounters
    }
    /// V-4: the agreed chroma list (nil until the client's declaration
    /// lands — or forever, for a grandfathered pre-W7 peer). The Sink
    /// branches the encoder posture on it at open.
    var agreedChromaModes: [UInt64]? {
        lock.lock()
        defer { lock.unlock() }
        return session?.agreedCapabilities?.chromaModes
    }
    /// HS-21: whether the flood dial currently demands a retry cookie.
    var handshakeCookieMode: Bool { session?.handshakeCookieMode ?? false }
    var clock: SessionClockStats { session.clock }
    var pacerTelemetry: PacerTelemetry { session.pacerTelemetry }
    var lifecycleState: SessionState? { session?.lifecycleState }
    var currentWireMode: SessionWireMode? { session?.wireMode }
    // HS-16 estimator surfaces for the final stats block.
    var estimatorStats: RateEstimatorStats { session.estimatorStats }
    var estimatedRate: Int { session.estimatedRateBitsPerSecond }
    var pacerRate: Int { session.pacerRateBitsPerSecond }
    var deliveryRate: Int? { session.deliveryRateBitsPerSecond }
    var measuredDeliveryRate: Int? { session.measuredDeliveryRateBitsPerSecond }
    var capacityBelief: Int? { session.capacityBeliefBitsPerSecond }
    var queuingDelayMicros: Int64? { session.queuingDelayMicroseconds }
    func frameByteCeiling(fps: Int) -> Int { session.frameByteCeiling(fps: fps) }
    // HS-25 unprotectable-frame guard surfaces: the live drop count
    // (the Sink logs increments) and the worst-case ceiling the shell
    // caps the encoder's opening VBV to.
    var videoFramesUnprotectable: Int {
        session.counters.videoFramesUnprotectable
    }
    var protectableFrameCeiling: Int {
        session.protectableFrameByteCeiling
    }
    var worstCaseProtectableFrameCeiling: Int {
        session.worstCaseProtectableFrameByteCeiling
    }
    // HS-17 repair surfaces for the final stats block.
    var fecRegime: FecRegime { session.fecRegime }
    var srttMicros: Int64? { session.srttMicroseconds }
    var repairStoreBytes: Int { session.repairStoreBytes }

    /// - Parameters:
    ///   - listenPort: bind here and await a connecting client (nil =
    ///     kernel-assigned port, requires `peer`).
    ///   - peer: pre-connected far end (insecure mode's fixed peer; in
    ///     Noise mode message 1 must still arrive from it).
    init(
        listenPort: UInt16?,
        peer: (host: String, port: UInt16)?,
        insecure: Bool,
        rateBitsPerSecond: Int,
        capabilities: Capabilities = .wireDefault,
        allowedClientStatics: [[UInt8]]? = nil,
        handshakeGateConfig: HandshakeGate.Config = HandshakeGate.Config(),
        pairing: PairingResponderService? = nil,
        onPairingEvent: @escaping (PairingResponderService.Event) -> Void
            = { _ in }
    ) throws {
        precondition(listenPort != nil || peer != nil,
                     "a session needs a port to listen on or a peer")
        self.insecure = insecure
        self.rateBitsPerSecond = rateBitsPerSecond
        self.capabilities = capabilities
        self.allowedClientStatics = allowedClientStatics
        self.handshakeGateConfig = handshakeGateConfig
        self.pairing = pairing
        self.onPairingEvent = onPairingEvent

        var err = [CChar](repeating: 0, count: 256)
        guard let n = lyte_netio_new("0.0.0.0", listenPort ?? 0,
                                     &err, err.count) else {
            throw HostError("session socket open failed: \(errString(err))")
        }
        netio = n
        if let peer {
            guard lyte_netio_set_peer(n, peer.host, peer.port,
                                      &err, err.count) == 0 else {
                lyte_netio_free(n)
                throw HostError("connect to \(peer.host):\(peer.port) "
                    + "failed: " + errString(err))
            }
        }
        scratch = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Self.scratchCapacity)
        recvScratch = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Int(LYTE_NETIO_MAX_BATCH) * Self.recvSlotCapacity)

        // The sender thread comes up parked (no work until the first
        // ingest signals it); it holds `self` for its lifetime, so the
        // shell must stop it (shutdown does) before the process lets
        // the SessionWire go. SessionWire is cross-thread by design
        // (video loop, audio loop, sender thread) with `lock` as the
        // discipline — the unsafe capture states that fact to the
        // compiler, exactly like the audio thread's Unmanaged
        // trampoline does implicitly.
        nonisolated(unsafe) let shared = self
        let thread = Thread { shared.drainLoop() }
        thread.name = "lyte-wire-drain"
        thread.start()

        if insecure {
            guard let peer else {
                lyte_netio_free(n)
                scratch.deallocate()
                throw HostError("--insecure streams to a fixed peer; "
                    + "give --wire-out HOST:PORT")
            }
            makeSession(
                crypto: .insecure,
                clientTuple: FourTuple(
                    localAddress: "0.0.0.0",
                    localPort: lyte_netio_local_port(n),
                    remoteAddress: peer.host, remotePort: peer.port
                )
            )
            print("session: INSECURE passthrough (CP-3 fallback — no "
                + "crypto, re-gate when a paired client exists) → "
                + "\(peer.host):\(peer.port)")
        }
    }

    deinit {
        scratch.deallocate()
        recvScratch.deallocate()
        lyte_netio_free(netio)
    }

    private func makeSession(crypto: SessionCryptoMode, clientTuple: FourTuple) {
        session = Session(
            config: SessionConfig(
                crypto: crypto,
                rateBitsPerSecond: rateBitsPerSecond,
                allowedClientStaticPublicKeys: allowedClientStatics,
                handshakeGate: handshakeGateConfig,
                capabilities: capabilities
            ),
            clientTuple: clientTuple,
            now: monotonicNS()
        ) { [weak self] datagram in
            self?.outbox.append(datagram)
        }
    }

    /// Noise mode: block until a client completes message 1 (the session
    /// establishes inside `receive`), up to `timeoutSeconds`. Prints the
    /// static public key the client must hold. Call before capture opens
    /// so no video is encoded for nobody.
    func awaitClient(hostStatic: NoiseKeyPair, timeoutSeconds: Double) throws {
        print("noise: host static public key "
            + HostStaticKey.hex(hostStatic.publicKey))
        print("noise: awaiting client handshake on port "
            + "\(lyte_netio_local_port(netio)) …")

        let deadline = monotonicNS() + UInt64(timeoutSeconds * 1e9)
        while monotonicNS() < deadline {
            var established = false
            lock.lock()
            do {
                try receiveAll { [weak self] datagram, tuple in
                    guard let self else { return }
                    if self.session == nil {
                        // Only a plausible handshake initiation may pick
                        // the tuple the socket and session pin to. A host
                        // relaunched under a live client (the F-5 restart
                        // rung) binds while the client's dead session is
                        // still spraying sealed feedback from its OLD
                        // source port — latching onto that first arrival
                        // connect()s the socket to a tuple that will never
                        // handshake, and the kernel then filters the real
                        // re-dial (fresh ephemeral port) forever. Shape
                        // check, not trust: the gate still authenticates.
                        guard Self.looksLikeHandshakeInitiation(datagram)
                        else { return }
                        // Its source is the session's initial tuple;
                        // connect() so the send path has a peer.
                        var err = [CChar](repeating: 0, count: 256)
                        guard lyte_netio_set_peer(
                            self.netio, tuple.remoteAddress, tuple.remotePort,
                            &err, err.count) == 0 else {
                            print("session: connect to \(tuple.remoteAddress):"
                                + "\(tuple.remotePort) failed: \(errString(err))")
                            return
                        }
                        self.makeSession(
                            crypto: .noise(hostStatic: hostStatic),
                            clientTuple: tuple
                        )
                    }
                    let events = self.session.receive(
                        datagram, from: tuple,
                        now: monotonicNS(), hostMicroseconds: monotonicMicros()
                    )
                    for event in events {
                        self.log(event)
                        if case .handshakeCompleted = event { established = true }
                    }
                }
                // A pre-establishment pump is what lets HS-21's 0x13
                // RetryChallenge (enqueued into the pacer by
                // Session.receive under flood) actually leave the box:
                // msg 2 escapes later via the streaming service loop's
                // pump, but a challenge answers a flood that never
                // establishes, so awaitClient must drain the pacer here.
                if session != nil { session.pump(now: monotonicNS()) }
                try flushOutbox() // challenges, message 2, session-start beacon
            } catch {
                lock.unlock()
                throw error
            }
            let done = established && session?.phase == .established
            lock.unlock()
            if done {
                try drainToIdle()
                return
            }
            usleep(2_000)
        }
        throw HostError("no client handshake within \(Int(timeoutSeconds))s "
            + "— is lyte-cli wire-view pointed at this host and holding "
            + "the printed static key?")
    }

    /// True when `datagram` is shaped like a client handshake initiation:
    /// a bare CTRL carriage whose payload is typed 0x05 (Noise message 1)
    /// or 0x14 (the W8 cookie resubmission). This is a pre-latch shape
    /// check only — admission, cookies, and Noise still judge the bytes.
    static func looksLikeHandshakeInitiation(_ datagram: [UInt8]) -> Bool {
        guard let (envelope, payload) = try? Envelope.decode(datagram),
              envelope.channel == .ctrl
        else { return false }
        return payload.first == CtrlMessageType.noiseHandshake1
            || payload.first == CtrlMessageType.retryHandshake1
    }

    /// The encoder-loop poll (HS-12 promotion, a client 0x10, or the
    /// lifecycle machine's WAKE/RECOVERY demand): consult before each
    /// encode; a non-empty demand forces the next frame to IDR, and
    /// carries WHY (the IDR books' cause tags).
    func takeForcedIdrDemand() -> FreshKeyframeDemand {
        lock.lock()
        defer { lock.unlock() }
        return session?.takeFreshKeyframeDemand() ?? []
    }

    /// HS-20: arm the encoder-VBV policy once the encoder's opening
    /// rate-control posture is known (main calls this right after the
    /// session comes up; the policy's baseline mirrors what
    /// lyte_hevc_enc_new configured).
    func armEncoderVbv(_ config: EncoderVbvConfig) {
        lock.lock()
        defer { lock.unlock() }
        vbvPolicy = EncoderVbvPolicy(config: config)
    }

    /// HS-20: the encoder-loop's second poll (with takeForcedIdr, once
    /// per encode): the estimator's LIVE frameByteCeiling into the
    /// policy; a non-nil directive must reach the encoder leaf before
    /// this frame is sent.
    func takeEncoderRateDirective() -> EncoderRateDirective? {
        lock.lock()
        defer { lock.unlock() }
        guard let vbvPolicy, let session, session.phase == .established
        else { return nil }
        guard let directive = vbvPolicy.note(
            frameByteCeiling: session.frameByteCeiling(
                fps: vbvPolicy.config.fps),
            now: monotonicNS()
        ) else { return nil }
        vbvDirectivesIssued += 1
        lastVbvDirective = directive
        return directive
    }

    /// HS-11: a FRESH damage frame arrived from capture (never the
    /// idle-floor repeats). In IDLE this is the WAKE — mode=active on
    /// the reliable stream, the damage frame owed as an IDR; in ACTIVE
    /// it aborts a pending idle flip.
    func noteDamage() {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        for event in session.noteDamage(
            now: monotonicNS(), hostMicroseconds: monotonicMicros()
        ) {
            log(event)
        }
    }

    /// HS-11: the ratchet converged (the all-skip stop). The final
    /// converged frame rides a reliable one-shot; its acknowledgment
    /// flips the wire mode to IDLE and datagram video stops. HS-22:
    /// the session holds the handoff until damage has been quiet for
    /// its idle-flip holdoff (3 s) — a desktop metronome (1 Hz clock,
    /// blinking cursor) stays ACTIVE on small P-frames instead of
    /// paying a full-frame WAKE IDR every beat — so the one-shot may
    /// leave on a later service pass, not necessarily this one.
    func noteRatchetConverged(finalFrame: [UInt8], captureMicros: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        for event in session.noteRatchetConverged(
            finalFrame: finalFrame,
            captureTimestampMicroseconds: captureMicros,
            now: monotonicNS(), hostMicroseconds: monotonicMicros()
        ) {
            log(event)
        }
        // The one-shot leaves now, not at the next tick.
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
    }

    /// HS-11: the orderly close — SessionTeardown 0x0A on the reliable
    /// stream, then a bounded linger so the segment can be delivered and
    /// acknowledged before the process exits (the graceful-exit half of
    /// the ECONNREFUSED fix: the client learns the session ended instead
    /// of inferring it from silence).
    func shutdown(reason: SessionTeardownReason, lingerSeconds: Double = 0.5) {
        // The sender thread goes first: teardown owns the send path
        // from here (and the thread holds `self` — this is also its
        // lifetime end).
        stopDrain()
        lock.lock()
        guard let session, session.phase == .established,
              session.lifecycleState != .closed, !peerGone else {
            lock.unlock()
            return
        }
        for event in session.beginTeardown(
            reason: reason,
            now: monotonicNS(), hostMicroseconds: monotonicMicros()
        ) {
            log(event)
        }
        lock.unlock()
        let deadline = monotonicNS() + UInt64(lingerSeconds * 1e9)
        while monotonicNS() < deadline {
            lock.lock()
            if session.arqIsQuiescent || peerGone {
                lock.unlock()
                break
            }
            do {
                try serviceOnce()
                try flushOutbox()
            } catch {
                lastSendError = String(describing: error)
                lock.unlock()
                break
            }
            lock.unlock()
            usleep(2_000)
        }
        print(session.arqIsQuiescent
            ? "session: teardown acknowledged — clean close"
            : "session: teardown sent, unacknowledged after "
                + "\(Int(lingerSeconds * 1000)) ms — closing anyway")
    }

    /// One encoded Annex-B packet → sealed shards on the wire. Runs on
    /// the PipeWire loop thread; returns once the pacer fully drained.
    func sendFrame(
        data: UnsafePointer<UInt8>, size: Int, isKeyframe: Bool,
        captureMicros: UInt64
    ) throws {
        let ingestStart = monotonicNS()
        let frame = Array(UnsafeBufferPointer(start: data, count: size))
        lock.lock()
        guard let session else {
            lock.unlock()
            throw HostError("sendFrame before the session exists")
        }
        do {
            try session.ingestVideoFrame(
                frame,
                captureTimestampMicroseconds: captureMicros,
                isKeyframe: isKeyframe,
                now: monotonicNS()
            )
        } catch {
            lock.unlock()
            throw error
        }
        framesSent += 1
        // First quantum leaves on this stack (the bucket is credited
        // while idle, so this is one batch + one sendmmsg, tens of µs);
        // the sender thread paces out the rest while the capture loop
        // returns to the compositor.
        session.pump(now: monotonicNS())
        do {
            try flushOutbox()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        lastFrameIngestNanos = monotonicNS() - ingestStart
        lastFrameDrainNanos = 0 // the capture thread no longer waits
        signalDrain()
    }

    /// The capture loop's backpressure gate (the fps-ceiling fix):
    /// video-class bytes still queued in the pacer, as wire time at the
    /// live pacer rate. Above the resiliency drain bound, encoding
    /// another capture frame only deepens the queue — the caller skips
    /// the frame pre-encode instead.
    var videoBacklogWireTimeNS: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return 0 }
        let bytes = session.queuedVideoBytes
        guard bytes > 0 else { return 0 }
        let rate = max(session.pacerRateBitsPerSecond, 1)
        return UInt64(Double(bytes) * 8e9 / Double(rate))
    }

    /// HS-15: one encoded 5 ms Opus packet from the AUDIO capture
    /// thread → the sealed chan-1 shards → the shared pacer → the
    /// wire, now. Never throws and never kills anything — a dead
    /// session just drops packets quietly (counted): the audio loop
    /// outliving the session by a beat is normal shutdown order.
    /// Audio deliberately flows in IDLE and FROZEN (the 5 ms path
    /// probe — Session's ruling; only `closed` suppresses).
    func sendAudioPacket(_ packet: [UInt8], captureMicros: UInt64) {
        lock.lock()
        guard let session, session.phase == .established, !peerGone else {
            audioPacketsDroppedPreSession += 1
            lock.unlock()
            return
        }
        do {
            _ = try session.ingestAudioPacket(
                packet,
                captureTimestampMicroseconds: captureMicros,
                now: monotonicNS()
            )
            session.pump(now: monotonicNS())
            try flushOutbox()
            audioPacketsSent += 1
        } catch {
            audioSendFailures += 1
            lastSendError = String(describing: error)
            let leftover = session.queuedAudioDatagramCount > 0 && !peerGone
            lock.unlock()
            if leftover { signalDrain() }
            return
        }
        // A concurrent video drain can hold the bucket in deficit for
        // ≤ one 1 ms quantum; if nothing else is pumping (true idle),
        // bounded second passes make sure the shard leaves anyway.
        var passes = 0
        while session.queuedAudioDatagramCount > 0, !peerGone, passes < 4 {
            let now = monotonicNS()
            let wake = session.nextWake(now: now)
            lock.unlock()
            if let wake, wake > now {
                usleep(UInt32(min((wake - now) / 1_000 + 1, 1_000)))
            }
            lock.lock()
            session.pump(now: monotonicNS())
            try? flushOutbox()
            passes += 1
        }
        // HS-31 fix 2: the retry loop is bounded — if the datagram
        // outlived it (a deficit deeper than ~4 ms, a busy wire), the
        // SENDER THREAD owns it. It used to stay parked until the next
        // video ingest's signalDrain: up to +16 ms of hold for a shard
        // whose whole budget is 5 ms.
        let leftover = session.queuedAudioDatagramCount > 0 && !peerGone
        lock.unlock()
        if leftover { signalDrain() }
    }

    /// The between-frames service hook (idle-floor tick cadence):
    /// inbound datagrams, session timers (beacons), pacer leftovers,
    /// and the HS-18 routing work that must run OFF the lock.
    func service() {
        lock.lock()
        guard session != nil else {
            lock.unlock()
            return
        }
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
        // Anything this pass enqueued but could not emit inside one
        // quantum (repair retransmits from a NACK, a burst of ARQ
        // segments) belongs to the sender thread, not the next tick.
        let leftovers = !(session?.isIdle ?? true)
        let requests = pendingAudioRouting
        pendingAudioRouting.removeAll()
        let announce = routingAnnounceOwed
        routingAnnounceOwed = false
        let standing = currentAudioRouting
        let applies = pendingClipboardApplies
        pendingClipboardApplies.removeAll()
        let imageApplies = pendingClipboardImageApplies
        pendingClipboardImageApplies.removeAll()
        let bulk = pendingBulkMessages
        pendingBulkMessages.removeAll()
        lock.unlock()
        if leftovers { signalDrain() }

        // The starting-posture 0x19 (capabilities just agreed) and any
        // client flips — both re-take the lock per send, neither holds
        // it across the PipeWire work.
        if announce {
            noteAudioRoutingApplied(standing)
        }
        for mode in requests {
            applyAudioRouting(mode)
        }
        // HS-19: apply client sets to the OS clipboard and give the
        // leaf its signal/fd pass — both off the lock (D-Bus
        // round-trips; the leaf's onLocalChange re-enters through
        // noteHostClipboardChanged, which takes the lock itself).
        for text in applies {
            clipboardApplyHandler?(text)
        }
        // P-1: sha-verified client images the same way.
        for data in imageApplies {
            clipboardImageApplyHandler?(data)
        }
        clipboardServiceHook?()
        // F-3: drive the file-drop shell (disk writes, fsync, the
        // verify hash) off the lock; its replies re-take it per send.
        driveBulkShell(bulk)
    }

    /// F-3: buffered chan-8 messages through the BulkReceiveShell —
    /// every disk action answered synchronously — then the shell's
    /// replies (accept/ack/complete/abort) back onto chan 8's ordered
    /// stream under the lock.
    private func driveBulkShell(_ messages: [BulkMessage]) {
        guard let shell = bulkShell, !messages.isEmpty else { return }
        var replies: [BulkMessage] = []
        for message in messages {
            for event in shell.ingest(message) {
                switch event {
                case .send(let reply):
                    replies.append(reply)
                case .offerAccepted(let id, let name, let bytes, let resuming):
                    print("files: offer \(String(id, radix: 16)) accepted — "
                        + "\"\(BulkFileNaming.sanitized(name))\" "
                        + "(\(bytes) B\(resuming ? ", RESUMING" : ""))")
                case .offerRefusedBusy(let id):
                    print("files: offer \(String(id, radix: 16)) refused — "
                        + "busy (one transfer at a time in v1)")
                case .insufficientDiskSpace(let needed, let free):
                    print("files: offer refused — needs \(needed) B, "
                        + "\(free) B free")
                case .fileCompleted(let name, let path, let bytes):
                    print("files: COMPLETE — \"\(name)\" (\(bytes) B, "
                        + "sha-verified) → \(path)")
                case .transferAborted(let reason, let byRemote):
                    print("files: transfer aborted (\(reason), "
                        + (byRemote ? "remote" : "local") + ")")
                case .storageFailure(let detail):
                    print("files: STORAGE FAILURE — \(detail)")
                case .violated(let violation):
                    print("files: protocol violation — \(violation)")
                }
            }
        }
        guard !replies.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        for reply in replies {
            do {
                try session.sendBulk(
                    reply.encode(),
                    now: monotonicNS(), hostMicroseconds: monotonicMicros()
                )
            } catch {
                lastSendError = String(describing: error)
                print("files: bulk send failed: \(error)")
            }
        }
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
    }

    /// HS-19: the leaf's report that the OS clipboard changed —
    /// genuine host copies AND the echoes of our own applies; the
    /// session's sync book tells them apart. The 0x1B (or the
    /// suppression verdict) happens inside the core; a no-key-10
    /// session stays silent (the rule-3 gate).
    func noteHostClipboardChanged(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        for event in session.noteHostClipboardChanged(
            text, now: monotonicNS(), hostMicroseconds: monotonicMicros()
        ) {
            log(event)
        }
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
    }

    /// P-1: the leaf's report that the OS clipboard now holds an
    /// image (whole PNG bytes) — genuine host copies AND the echoes
    /// of our own applies; the session's shared book tells them
    /// apart. Cargo (or the suppression verdict) happens inside the
    /// core; an ungated session stays silent (the keys-10∧12 gate).
    func noteHostClipboardImageChanged(_ data: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        for event in session.noteHostClipboardImageChanged(
            data, now: monotonicNS(), hostMicroseconds: monotonicMicros()
        ) {
            log(event)
        }
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
    }

    /// HS-18: main's seed — what posture the audio leaf came up in.
    func setInitialAudioRouting(_ mode: HostAudioRoutingMode) {
        lock.lock()
        defer { lock.unlock() }
        currentAudioRouting = mode
    }

    /// One 0x18 answered: flip the leaf via the shell's handler, then
    /// report the posture that actually stands (the client's control
    /// strip renders truth — a failed flip reports the OLD posture).
    private func applyAudioRouting(_ mode: HostAudioRoutingMode) {
        lock.lock()
        let standing = currentAudioRouting
        lock.unlock()
        if mode == standing {
            noteAudioRoutingApplied(standing) // re-affirm, truthfully
            return
        }
        guard let handler = audioRoutingHandler else {
            print("audio-routing: \(mode) requested but no flip surface "
                + "is active this run — posture stays \(standing)")
            noteAudioRoutingApplied(standing)
            return
        }
        if handler(mode) {
            lock.lock()
            currentAudioRouting = mode
            lock.unlock()
            print("audio-routing: flipped to \(mode)")
            noteAudioRoutingApplied(mode)
        } else {
            print("audio-routing: flip to \(mode) FAILED — posture "
                + "stays \(standing)")
            noteAudioRoutingApplied(standing)
        }
    }

    /// The applied-posture 0x19 onto the reliable stream (a no-op at
    /// the session layer unless hostAudioRouting was negotiated).
    func noteAudioRoutingApplied(_ mode: HostAudioRoutingMode) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        for event in session.noteAudioRoutingApplied(
            mode, now: monotonicNS(), hostMicroseconds: monotonicMicros()
        ) {
            log(event)
        }
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
    }

    /// Pumps the pacer at its own wake instants until empty, servicing
    /// inbound + timers at each pass and flushing each pump's datagrams
    /// as sendmmsg batches. The sleep is capped: while the pacer holds
    /// bytes its wake is ≤ one quantum away, and the session's other
    /// timers (a beacon up to 1 s out) must never stall the encoder.
    /// ECONNREFUSED evidence, once: the client's socket is closed. The
    /// peer that would read a teardown is gone, so nothing is sent
    /// (W4b's liveness rule); the loop just ends cleanly.
    private func notePeerGone() {
        guard !peerGone else { return }
        peerGone = true
        print("session: client unreachable (ICMP port closed — it exited) "
            + "— closing cleanly")
    }

    /// Wakes the sender thread: bytes were enqueued (or leftovers were
    /// observed) and the pacer needs pumping at its own wake instants.
    /// Never call while holding `lock` — the lock order is
    /// `lock` → `drainCondition` (sessionEnded) and must stay acyclic.
    private func signalDrain() {
        drainCondition.lock()
        drainWork = true
        drainCondition.signal()
        drainCondition.unlock()
    }

    /// Stops the sender thread and waits for it to exit (it holds
    /// `self` and shares the send scratch, so teardown must not race
    /// it). Idempotent; a parked thread exits within one signal, a
    /// draining thread within its current drain.
    private func stopDrain() {
        drainCondition.lock()
        drainStop = true
        drainCondition.signal()
        while !drainExited { drainCondition.wait() }
        drainCondition.unlock()
    }

    /// The sender thread's whole life: park until signaled, drain the
    /// pacer to idle at its own wake instants, park again. A send
    /// failure is recorded and ends the session (mirroring what a
    /// thrown sendFrame used to do to the capture loop) — the thread
    /// itself parks and stays stoppable.
    private func drainLoop() {
        while true {
            drainCondition.lock()
            while !drainWork && !drainStop { drainCondition.wait() }
            if drainStop {
                drainExited = true
                drainCondition.broadcast()
                drainCondition.unlock()
                return
            }
            drainWork = false
            drainCondition.unlock()
            do {
                try drainToIdle()
            } catch {
                lock.lock()
                lastSendError = String(describing: error)
                lock.unlock()
                drainCondition.lock()
                let firstFailure = !drainFailed
                drainFailed = true
                drainCondition.unlock()
                if firstFailure {
                    print("session: wire drain failed (\(error)) — "
                        + "closing")
                }
            }
        }
    }

    /// Callers must NOT hold `lock`: each pass takes it for the service
    /// work and releases it across the sleep, so the audio thread's
    /// 5 ms sends interleave with a long video drain (the structural
    /// half of the 5 ms ± 2 ms bound; the pacer's class order is the
    /// other half).
    private func drainToIdle() throws {
        while true {
            lock.lock()
            guard session != nil else {
                lock.unlock()
                return
            }
            do {
                try serviceOnce()
                try flushOutbox()
            } catch {
                lock.unlock()
                throw error
            }
            let done = peerGone || session.isIdle
            let now = monotonicNS()
            let wake = session.nextWake(now: now)
            lock.unlock()
            if done { return }
            if let wake, wake > now {
                usleep(UInt32(min((wake - now) / 1_000 + 1, 2_000)))
            }
        }
    }

    private func serviceOnce() throws {
        try receiveAll { [weak self] datagram, tuple in
            guard let self, let session = self.session else { return }
            for event in session.receive(
                datagram, from: tuple,
                now: monotonicNS(), hostMicroseconds: monotonicMicros()
            ) {
                self.log(event)
            }
        }
        for event in session.advance(
            now: monotonicNS(), hostMicroseconds: monotonicMicros()
        ) {
            log(event)
        }
        session.pump(now: monotonicNS())
    }

    private func receiveAll(
        _ handle: ([UInt8], FourTuple) -> Void
    ) throws {
        var err = [CChar](repeating: 0, count: 256)
        let batchSize = Int(LYTE_NETIO_MAX_BATCH)
        while true {
            var slots = (0..<batchSize).map { i -> lyte_netio_slot in
                var slot = lyte_netio_slot()
                slot.data = recvScratch.advanced(by: i * Self.recvSlotCapacity)
                slot.cap = Self.recvSlotCapacity
                return slot
            }
            let got = slots.withUnsafeMutableBufferPointer { s in
                lyte_netio_recv_batch(netio, s.baseAddress, Int32(s.count),
                                      &err, err.count)
            }
            if got == LYTE_NETIO_PEER_GONE {
                notePeerGone()
                return
            }
            if got < 0 {
                throw HostError("recv failed: \(errString(err))")
            }
            if got == 0 { return }
            let localPort = lyte_netio_local_port(netio)
            for i in 0..<Int(got) {
                let slot = slots[i]
                let datagram = Array(UnsafeBufferPointer(
                    start: recvScratch.advanced(by: i * Self.recvSlotCapacity),
                    count: slot.len
                ))
                var ip = slot.src_ip
                let source = withUnsafeBytes(of: &ip) { raw -> String in
                    String(decoding: raw.prefix(while: { $0 != 0 }),
                           as: UTF8.self)
                }
                handle(datagram, FourTuple(
                    localAddress: "0.0.0.0", localPort: localPort,
                    remoteAddress: source, remotePort: slot.src_port
                ))
            }
            if got < Int32(batchSize) { return }
        }
    }

    private func log(_ event: SessionEvent) {
        switch event {
        case .handshakeCompleted(let remote):
            print("noise: handshake complete — client static "
                + HostStaticKey.hex(remote))
            // HS-9: the pairing run binds to THIS session's transcript
            // and statics; a re-handshake rebinds (and keeps the guess
            // budget — reconnecting never refills it).
            if let pairing, let hash = session.handshakeHash {
                pairing.sessionEstablished(
                    clientStaticPublicKey: remote,
                    noiseHandshakeHash: hash
                )
            }
        case .beaconSent:
            break // 1 Hz; the final stats line carries the count
        case .beaconEchoAccepted(let seq, let offset, let rtt):
            if seq % 10 == 0 {
                print("beacon: echo \(seq) offset \(offset) µs rtt \(rtt) µs")
            }
        case .reliableCtrl(let group, let message):
            // The pairing service claims its four CTRL types; nil means
            // the message is some other consumer's (none exist yet —
            // capabilities land with W7).
            if let pairing,
               let output = pairing.handleReliableCtrl(
                   message, now: monotonicNS()
               ) {
                for reply in output.replies {
                    do {
                        try session.sendReliable(
                            reply, now: monotonicNS(),
                            hostMicroseconds: monotonicMicros()
                        )
                    } catch {
                        print("pairing: reply send failed: \(error)")
                    }
                }
                for pairingEvent in output.events {
                    onPairingEvent(pairingEvent)
                }
                return
            }
            print("ctrl-arq: message group \(group.rawValue) "
                + "(\(message.count) B, type "
                + "0x\(String(message.first ?? 0, radix: 16)))")
        case .reliableOneShotAcknowledged(let group):
            print("ctrl-arq: one-shot group \(group.rawValue) acknowledged")
        case .arqIgnored(let reason):
            print("ctrl-arq: ignored \(reason)")
        case .idrRequested(let request):
            print("ctrl: IDR request seq \(request.requestSeq) "
                + "(frame \(request.frame.rawValue), "
                + "coalesced \(request.coalescedCount))")
        case .path(let pathEvent):
            print("path: \(pathEvent)")
            if case .promoted(let primary, _) = pathEvent {
                // Execute the rebind: media now targets the new tuple.
                var err = [CChar](repeating: 0, count: 256)
                if lyte_netio_set_peer(
                    netio, primary.tuple.remoteAddress,
                    primary.tuple.remotePort, &err, err.count) != 0 {
                    print("path: rebind connect failed: \(errString(err))")
                }
            }
        case .handshakeCookieModeChanged(let requireCookie):
            // HS-21: the observable dial. Loud on purpose — this is the
            // live evidence the flip happened and cleared.
            print(requireCookie
                ? "handshake: FLOOD — require-cookie mode ENGAGED "
                    + "(msg1 rate crossed the enter threshold; "
                    + "un-cookied msg1s now answered with 0x13, no Noise)"
                : "handshake: pressure cleared — require-cookie mode "
                    + "DISENGAGED (back to the token-bucket posture)")
        case .handshakeChallenged:
            // A flood would print per datagram; the final stats line
            // carries the handshakeChallengesMinted count instead.
            break
        case .dropped(.handshakeThrottled):
            // A flood would print per datagram; the final stats line
            // carries the handshakesThrottled count instead.
            break
        case .dropped(.handshakeCookieInvalid):
            break // counted; the final stats line carries the tally
        case .dropped(let reason):
            print("drop: \(reason)")
        case .sendFailed(let what):
            print("send-failed: \(what)")
        case .capabilitiesAgreed(let agreed):
            print("capabilities: agreed — wire minor \(agreed.wireMinor), "
                + "codecs \(agreed.videoCodecs), chroma \(agreed.chromaModes), "
                + "idle-silence \(agreed.idleSilence), "
                + "host-audio-routing \(agreed.hostAudioRouting), "
                + "max datagram \(agreed.maxDatagramBytes) B")
            // HS-18: both ends declared key 9 — the client is owed one
            // starting-posture 0x19 (its control strip renders it).
            // Buffered; the next service pass sends it off this stack.
            if agreed.hostAudioRouting {
                routingAnnounceOwed = true
            }
        case .capabilitiesFailed(let why):
            print("capabilities: NO WORKABLE INTERSECTION (\(why)) — "
                + "typed teardown follows")
        case .capabilityUpdateAcknowledged(let accepted):
            print("capabilities: update "
                + (accepted ? "accepted" : "rejected") + " by the client")
        case .modeTransitionSent(let mode):
            print("mode: → \(mode == .idle ? "IDLE" : "ACTIVE") "
                + "(0x09 on the reliable stream)")
        case .finalFrameSent(let group):
            print("mode: converged frame riding one-shot group "
                + "\(group.rawValue) — its ack is the idle flip")
        case .teardownSent(let reason):
            print("session: teardown 0x0A queued (\(reason))")
        case .lifecycleChanged(let state):
            switch state {
            case .frozen:
                print("lifecycle: FROZEN — 350 ms of media-path silence; "
                    + "datagram video suspended, CTRL stays alive")
            case .recovery:
                print("lifecycle: RECOVERY — evidence returned; fresh IDR "
                    + "at the half-stale rate, sends resume")
            case .active, .idle:
                print("lifecycle: \(state)")
            case .closed:
                break // .sessionClosed carries the reason
            }
        case .sessionClosed(let reason):
            print("session: CLOSED (\(reason))")
        case .inputReceived(let event, let rxMicros):
            injectInput(event, receivedAtMicroseconds: rxMicros)
        case .rateChanged(let bps, let reason):
            // HS-16: downshifts and pacing policies always print (the
            // live gate's evidence); the ≤10%/s evidence climb prints
            // only on ≥5% moves so a clean recovery reads as a handful
            // of lines, not a 25 Hz stream.
            let significant = lastPrintedRate.map {
                Double(abs(bps - $0)) / Double($0) >= 0.05
            } ?? true
            switch reason {
            case .evidence:
                guard significant else { break }
                lastPrintedRate = bps
                print("rate: ↑ \(bps / 1_000) kbps (evidence climb)")
            case .overuse:
                lastPrintedRate = bps
                // The ramp hunt's forensics: the evidence at fall time,
                // so a post-mortem can say why neither the
                // self-reference gate nor the stall gate held it.
                var forensics = ""
                if let f = session?.lastOveruseFallForensics {
                    let train = f.lastFullTrainBitsPerSecond.map {
                        "\($0 / 1_000) kbps "
                            + "\((f.lastFullTrainAgeNS ?? 0) / 1_000_000) ms ago"
                    } ?? "none"
                    forensics = " [anchor \(f.anchorBitsPerSecond / 1_000)"
                        + " kbps from \(f.rateBeforeBitsPerSecond / 1_000)"
                        + " kbps; belief "
                        + (f.capacityBeliefBitsPerSecond.map {
                            "\($0 / 1_000)"
                        } ?? "—")
                        + " kbps, honest "
                        + (f.honestAnchorBitsPerSecond.map {
                            "\($0 / 1_000) kbps"
                        } ?? "none")
                        + ", streak age "
                        + "\((f.streakAgeNS ?? 0) / 1_000_000) ms; streak "
                        + "\(f.streakStartMicroseconds.map(String.init) ?? "—")"
                        + "→\(f.queuingDelayMicroseconds.map(String.init) ?? "—")"
                        + " µs, peak "
                        + "\(f.streakPeakMicroseconds.map(String.init) ?? "—")"
                        + " µs; backlog \(f.pacerBacklogBytes) B; "
                        + "full-train \(train); loss "
                        + String(format: "%.3f", f.lossFraction)
                        + "/\(String(format: "%.3f", f.postFecLossFraction))"
                        + " post-FEC]"
                }
                print("rate: ↓ \(bps / 1_000) kbps (queuing-delay overuse)"
                    + forensics)
            case .loss:
                lastPrintedRate = bps
                print("rate: ↓ \(bps / 1_000) kbps (loss over threshold)")
            case .idrPacing(let pacing):
                lastPrintedRate = bps
                print("rate: → \(bps / 1_000) kbps (IDR pacing \(pacing))")
            case .postFecLoss:
                lastPrintedRate = bps
                print("rate: ↓ \(bps / 1_000) kbps (post-FEC loss — "
                    + "rung 3)")
            }
        case .repairEnqueued(let frame, let shards):
            print("repair: frame \(frame.rawValue) — \(shards) shard(s) "
                + "retransmitted (fresh seqs, videoTail)")
        case .nackJudgedStale(let frame, let reason):
            print("repair: NACK frame \(frame.rawValue) judged stale "
                + "(\(reason))")
        case .fecRegimeChanged(let regime):
            print("fec: regime → \(regime.rawValue) "
                + "(§5.2 \(regime == .lossy ? "lossy" : "clean") column)")
        case .audioRoutingRequested(let mode):
            // Delivered under the lock mid-iteration: buffer only. The
            // flip (a PipeWire connect) runs off-lock in service().
            print("audio-routing: client requested \(mode) (0x18)")
            pendingAudioRouting.append(mode)
        case .audioRoutingStatusSent(let mode):
            print("audio-routing: status \(mode) sent (0x19)")
        case .clipboardSetReceived(let text):
            // CL-15/HS-19: the session's gate + book already ran (the
            // book is pre-armed against this apply's echo). Delivered
            // under the lock mid-iteration: buffer only — the apply
            // (a blocking D-Bus SetSelection) runs off-lock in
            // service(). Never logs the payload.
            if clipboardApplyHandler != nil {
                print("clipboard: 0x1A set received "
                    + "(\(text.utf8.count) B) — applying to the host "
                    + "clipboard")
                pendingClipboardApplies.append(text)
            } else {
                // Defensive: a leafless shell never declares key 10,
                // so the core's rule-3 gate makes this unreachable.
                print("clipboard: 0x1A set received "
                    + "(\(text.utf8.count) B) — no clipboard leaf, "
                    + "ignored")
            }
        case .clipboardAnnounceSent(let byteCount):
            print("clipboard: announce sent (\(byteCount) B, 0x1B)")
        case .clipboardAnnounceSuppressed(let reason):
            print("clipboard: announce suppressed (\(reason))")
        case .bulkMessageReceived(let message):
            // Buffered for the off-lock shell pass (disk IO must not
            // ride the session lock). Chunks arrive by the hundred —
            // silent here; the shell's events narrate the transfer.
            pendingBulkMessages.append(message)
        case .clipboardImageReceived(let data, let mime):
            // P-1: sha-verified — buffer for the off-lock leaf apply
            // (a blocking D-Bus SetSelection). Never logs the payload.
            if clipboardImageApplyHandler != nil {
                print("clipboard: image received (\(data.count) B, "
                    + "\(mime)) — applying to the host clipboard")
                pendingClipboardImageApplies.append(data)
            } else {
                // Defensive: an imageless shell never declares key
                // 12, so the core's gate makes this unreachable.
                print("clipboard: image received (\(data.count) B) — "
                    + "no image leaf, ignored")
            }
        case .clipboardImageShareStarted(let byteCount):
            print("clipboard: image share started (\(byteCount) B "
                + "as chan-8 cargo)")
        case .clipboardImageShareCompleted(let byteCount):
            print("clipboard: image share completed (\(byteCount) B, "
                + "sha-verified by the client)")
        case .clipboardImageShareAborted(let reason, let byRemote):
            print("clipboard: image share aborted (\(reason), "
                + "\(byRemote ? "remote" : "local"))")
        case .clipboardImageReceiveAborted(let reason, let byRemote):
            print("clipboard: image receive aborted (\(reason), "
                + "\(byRemote ? "remote" : "local"))")
        case .clipboardImageSuppressed(let reason):
            print("clipboard: image suppressed (\(reason))")
        case .clipboardImageRefused(let reason):
            print("clipboard: image refused (\(reason))")
        case .clipboardImageViolation(let violation):
            print("clipboard: image lane protocol violation "
                + "(\(violation)) — aborted")
        }
    }

    /// One delivered input event → the injector → the session's echo
    /// buffer (flushed as 0x17 on the next service pass). Failures are
    /// counted and loud, never fatal — a stuck injector must not kill
    /// the stream carrying the user's screen.
    private func injectInput(
        _ event: InputEvent, receivedAtMicroseconds rxMicros: UInt64
    ) {
        guard let injector = inputInjector else {
            if !inputNoInjectorWarned {
                inputNoInjectorWarned = true
                print("input: event seq \(event.seq) arrived but no "
                    + "injection backend is active — input is OFF this run")
            }
            inputInjectFailures += 1
            return
        }
        do {
            try injector.inject(event)
        } catch {
            inputInjectFailures += 1
            print("input: inject seq \(event.seq) failed: \(error)")
            return
        }
        let injectMicros = monotonicMicros()
        inputInjected += 1
        inputLatency.record(injectMicros &- rxMicros)
        session.noteInputInjected(
            seq: event.seq,
            receivedAtMicroseconds: rxMicros,
            injectedAtMicroseconds: injectMicros
        )
    }

    /// Capture negotiation → the injector's absolute-coordinate scaling
    /// (the uinput tablet needs the monitor size; Mutter ignores it).
    func noteMonitorExtent(width: UInt32, height: UInt32) {
        inputInjector?.noteMonitorExtent(width: width, height: height)
    }

    private func flushOutbox() throws {
        guard !outbox.isEmpty else { return }
        if peerGone {
            outbox.removeAll(keepingCapacity: true)
            return
        }
        defer { outbox.removeAll(keepingCapacity: true) }
        var err = [CChar](repeating: 0, count: 256)

        // Challenges to unvalidated tuples ride sendmsg-with-address on
        // the connected socket (lyte_netio_send_to): the challenge MUST
        // travel on the exact probed tuple — that is what it proves.
        let deliverable = outbox.filter { datagram in
            guard let destination = datagram.destination,
                  destination != session.validator.primary.tuple
            else { return true }
            let rc = datagram.bytes.withUnsafeBufferPointer { buf -> Int32 in
                var pkt = lyte_netio_pkt(
                    data: buf.baseAddress, len: buf.count,
                    tos: WireTos.byte(for: datagram.pacerClass))
                return lyte_netio_send_to(
                    netio, &pkt,
                    destination.remoteAddress, destination.remotePort,
                    &err, err.count)
            }
            if rc == 1 {
                challengesSentOffPrimary += 1
                datagramsSent += 1
                bytesSent += datagram.bytes.count
                print("path: challenge sent to \(destination.remoteAddress):"
                    + "\(destination.remotePort) (off-primary sendto)")
            } else if rc == LYTE_NETIO_PEER_GONE {
                notePeerGone()
            } else {
                lastSendError = errString(err)
                print("path: challenge to \(destination.remoteAddress):"
                    + "\(destination.remotePort) failed: \(errString(err))")
            }
            return false
        }

        var staged = 0
        while staged < deliverable.count {
            let batch = deliverable[staged..<min(
                staged + Int(LYTE_NETIO_MAX_BATCH), deliverable.count)]
            var pkts: [lyte_netio_pkt] = []
            pkts.reserveCapacity(batch.count)
            var offset = 0
            for d in batch {
                precondition(offset + d.bytes.count <= Self.scratchCapacity)
                d.bytes.withUnsafeBufferPointer { src in
                    scratch.advanced(by: offset)
                        .update(from: src.baseAddress!, count: src.count)
                }
                pkts.append(lyte_netio_pkt(
                    data: scratch.advanced(by: offset),
                    len: d.bytes.count,
                    tos: WireTos.byte(for: d.pacerClass)
                ))
                offset += d.bytes.count
            }

            var sentTotal = 0
            while sentTotal < pkts.count {
                let sent = pkts[sentTotal...].withUnsafeBufferPointer { buf in
                    lyte_netio_send_batch(netio, buf.baseAddress,
                                          Int32(buf.count), nil,
                                          &err, err.count)
                }
                if sent == LYTE_NETIO_PEER_GONE {
                    notePeerGone()
                    return
                }
                if sent < 0 {
                    lastSendError = errString(err)
                    throw HostError("session send failed: \(errString(err))")
                }
                if sent == 0 { usleep(200); continue }
                sentTotal += Int(sent)
            }
            for d in batch {
                datagramsSent += 1
                bytesSent += d.bytes.count
            }
            staged += batch.count
        }
    }
}
