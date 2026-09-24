// SessionWire: lyte-host's Lyte-UDP session shell over HostWire.Session,
// which owns the protocol. This file is syscalls, threads and scheduling:
// recvmmsg into Session.receive with real source tuples, and Session's
// paced datagrams through SocketOutbox into sendmmsg with per-class TOS.
//
// Sockets: the HostListener's socket is bound to the session port, never
// connected, and outlives each session. After a handshake a video socket
// (SO_PRIORITY 4) and a latency socket (control and audio, 6) join the
// port via SO_REUSEPORT and connect to the client; they close with the
// session (`release`), so they never share the port with the next one.
//
// Threads: the capture thread calls sendFrame and takeLegSnapshot; the
// audio thread publishes into a narrow mailbox and only tries the session
// lock; the janitor runs service() every 10 ms for shell work off the
// lock; the SCHED_RR sender thread ppolls its wake eventfd, the sockets
// and the session's next timer, then services and flushes. One NSLock
// guards the Session and the outbox, so seq allocation, sealing, pacer
// insertion and flush keep one order; console lines are printed after it
// is released. Agreed capability flags live under a separate config lock.

import LyteIO
import LyteCore
import CNetIO
import Foundation
import HostCore
import HostSession
import HostWire
import LyteWire

/// Best-effort realtime elevation for a latency-owning thread, degrading
/// SCHED_RR → per-thread nice −10 → default CFS (said once). Unprivileged
/// runs need an rtprio rlimit; the host must run fine without one.
func elevateCurrentThread(_ label: String, rtPriority: Int32) {
    #if os(Linux)
    var param = sched_param()
    param.sched_priority = rtPriority
    if pthread_setschedparam(pthread_self(), Int32(SCHED_RR), &param) == 0 {
        print("sched: \(label) thread SCHED_RR \(rtPriority)")
        return
    }
    // On Linux, who == 0 with PRIO_PROCESS is the calling task —
    // per-thread nice.
    if setpriority(__priority_which_t(PRIO_PROCESS.rawValue), 0, -10) == 0 {
        print("""
            sched: \(label) thread nice -10 (no rtprio rlimit — \
            SCHED_RR refused; see Host/README to grant it)
            """)
        return
    }
    print("""
        sched: \(label) thread NOT elevated (unprivileged, no \
        RLIMIT_NICE) — running at default CFS priority
        """)
    #endif
}

/// The listening service's socket, bound once and never connected, so a
/// client that dials between sessions is heard by the next one.
final class HostListener {
    let netio: OpaquePointer
    /// Message 1s any session of this process answered; a replay or stale
    /// retransmit is dropped unread. Touched only by `awaitClient` under
    /// the waiting wire's lock (one session waits at a time).
    var answeredHandshakes = AnsweredHandshakeMemory()

    init(port: UInt16) throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let n = lyte_netio_new("0.0.0.0", port, &err, err.count) else {
            throw HostError("session socket open failed: \(errString(err))")
        }
        guard lyte_netio_set_priority(n, 6) == 0 else {
            lyte_netio_free(n)
            throw HostError("listening socket SO_PRIORITY failed")
        }
        netio = n
    }

    deinit { lyte_netio_free(netio) }
}

final class SessionWire {
    enum ClientAwaitOutcome: Equatable {
        case established
        case terminationRequested
    }

    /// Never connected: receives every tuple no connected socket claims
    /// (message 1, a migrated client's new path) and carries every
    /// explicitly addressed datagram.
    private let listenNetio: OpaquePointer
    /// The listening socket's owner: the service's shared listener, or a
    /// private one on a kernel-assigned port for a wire-out run.
    private let listener: HostListener
    /// The media sockets (SO_REUSEPORT members of the listening port,
    /// connected to the client's primary tuple; nil until it is known):
    /// video at SO_PRIORITY 4, control and audio at 6.
    private var videoNetio: OpaquePointer?
    private var latencyNetio: OpaquePointer?
    /// wire-out mode: only this peer may complete a handshake.
    private let requiredPeer: (host: String, port: UInt16)?
    private let handshakeWitness: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment[
            "LYTE_HANDSHAKE_WITNESS_JSONL"] else { return nil }
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private var awaitPrimaryDatagrams = 0
    /// Unconfirmed handshakes a newer authenticated message 1 replaced.
    private(set) var handshakesSuperseded = 0
    private var session: Session!
    /// Guards the Session and the outbox (see the header). Held across
    /// service passes, released across sleeps.
    private let lock = NSLock()
    private let rateBitsPerSecond: Int
    /// What this host declares in the capability exchange.
    private let capabilities: Capabilities
    /// Non-nil = only these client statics may complete message 1.
    private let allowedClientStatics: [[UInt8]]?
    private let handshakeGateConfig: HandshakeGate.Config
    /// Non-nil = pairing mode: the service consumes the pairing CTRL
    /// types off the reliable stream; replies ride sendReliable.
    private let pairing: PairingResponderService?
    private let onPairingEvent: (PairingResponderService.Event) -> Void

    private var outbox = SocketOutbox()

    /// Staging for one sendmmsg batch: pointers must outlive the call.
    private let scratch: UnsafeMutablePointer<UInt8>
    private static let scratchCapacity = Int(LYTE_NETIO_MAX_BATCH) * 1_200
    private var sendPackets: [lyte_netio_pkt] = []
    private var sendError = [CChar](repeating: 0, count: 256)

    /// One flat region for recv_batch slots, one stride per position.
    private let recvScratch: UnsafeMutablePointer<UInt8>
    private static let recvSlotCapacity = 2_048
    /// Reused by every receive drain; all receive paths hold `lock`, and
    /// the pointers stay fixed on `recvScratch`.
    private var recvSlots: [lyte_netio_slot]
    private var recvError = [CChar](repeating: 0, count: 256)

    /// The surfaces below are published by main after the drain thread
    /// is live. Every access snapshots under this lock — never the
    /// session `lock` — and it is never held across a callback.
    private let configLock = NSLock()
    private func withConfigLock<T>(_ body: () -> T) -> T {
        configLock.lock()
        defer { configLock.unlock() }
        return body()
    }

    /// Nil = input disabled (counted loud, never fatal).
    private var _inputInjector: InputInjector?
    var inputInjector: InputInjector? {
        get { withConfigLock { _inputInjector } }
        set { withConfigLock { _inputInjector = newValue } }
    }

    /// Restarts the audio leaf in the requested routing and returns
    /// whether it stuck; nil = requests get the standing posture. Called
    /// off the session lock: a flip is a PipeWire connect (milliseconds).
    private var _audioRoutingHandler: ((HostAudioRoutingMode) -> Bool)?
    var audioRoutingHandler: ((HostAudioRoutingMode) -> Bool)? {
        get { withConfigLock { _audioRoutingHandler } }
        set { withConfigLock { _audioRoutingHandler = newValue } }
    }

    /// The clipboard leaf's SetSelection; nil = no leaf this run. Called
    /// off the session lock: SetSelection is a blocking D-Bus round-trip.
    private var _clipboardApplyHandler: ((String) -> Void)?
    var clipboardApplyHandler: ((String) -> Void)? {
        get { withConfigLock { _clipboardApplyHandler } }
        set { withConfigLock { _clipboardApplyHandler = newValue } }
    }
    /// The PNG half of the same sink, same off-lock discipline.
    private var _clipboardImageApplyHandler: (([UInt8]) -> Void)?
    var clipboardImageApplyHandler: (([UInt8]) -> Void)? {
        get { withConfigLock { _clipboardImageApplyHandler } }
        set { withConfigLock { _clipboardImageApplyHandler = newValue } }
    }
    /// The host organs' service pass (clipboard D-Bus pumps, Avahi
    /// watch), run once per `service()`, never under the lock.
    private var _shellServiceHook: (() -> Void)?
    var shellServiceHook: (() -> Void)? {
        get { withConfigLock { _shellServiceHook } }
        set { withConfigLock { _shellServiceHook = newValue } }
    }
    // The pending queues below are filled under the lock and drained
    // outside it by `service()`.
    private var pendingClipboardApplies: [String] = []
    private var pendingClipboardImageApplies: [[UInt8]] = []

    /// The file-drop shell; nil = consent is off this run. Driven off the
    /// session lock: store actions are pwrite + fsync and the verify is a
    /// whole-file hash.
    private var _bulkShell: BulkReceiveShell?
    var bulkShell: BulkReceiveShell? {
        get { withConfigLock { _bulkShell } }
        set { withConfigLock { _bulkShell = newValue } }
    }
    private var pendingBulkMessages: [BulkMessage] = []
    /// The posture the audio leaf is actually running. Mutated under
    /// `lock`.
    private(set) var currentAudioRouting: HostAudioRoutingMode = .hostAudible
    private var pendingPairingEvents: [PairingResponderService.Event] = []
    private var pendingAudioRouting: [HostAudioRoutingMode] = []
    /// hostAudioRouting was agreed: the client is owed one 0x19.
    private var routingAnnounceOwed = false
    /// receive→inject per event, µs, over the most recent
    /// `inputLatencyWindow` events so the summary describes the end.
    static let inputLatencyWindow = 16_384
    private(set) var inputLatency = Histogram<UInt64>(
        capacity: inputLatencyWindow, retention: .rolling
    )
    private(set) var inputInjected = 0
    private(set) var inputInjectFailures = 0
    private var inputNoInjectorWarned = false
    /// Only pointer motion owes an embedded-cursor damage frame; other
    /// input may draw nothing, so it is no capture-liveness witness.
    private var lastPointerMotionInjectedAt: UInt64 = 0
    /// The last absolute pointer injected (monitor device pixels): the
    /// cursor watcher's hotspot anchor (hotspot = injected position −
    /// cursor plane CRTC position; i915 exposes no HOTSPOT_X/Y).
    private var lastAbsolutePointer: (x: Double, y: Double)?
    /// Re-offered at agreement so a mid-run client wears the current
    /// cursor, not a default.
    private var standingCursorShape: CursorShape?
    /// Key 13 was agreed: the next service pass sends the standing shape.
    private var cursorAnnounceOwed = false

    /// Most recent admitted frame, for the encoder callback's telemetry.
    private var lastFrameForTelemetry: FrameNumber?
    /// The audio thread's publications, in capture order.
    private enum AudioMailboxEntry {
        case packet(bytes: [UInt8], captureMicros: UInt64, offeredAtNS: UInt64)
        case trackState(AudioTrackState.State)
    }
    /// The audio thread takes only this lock; the Session owner swaps the
    /// whole FIFO out before sealing, so capture never waits for video.
    private let audioMailboxLock = NSLock()
    private var audioMailbox: [AudioMailboxEntry] = []
    private static let audioMailboxCapacity = 64
    private(set) var audioMailboxMaxDepth = 0
    private(set) var audioMailboxOverflows = 0
    private(set) var audioMailboxMaxDwellNS: UInt64 = 0
    /// Mailbox dwell per 5 ms packet over the last 60 s (12,000 packets).
    static let audioMailboxDwellWindow = 12_000
    private(set) var audioMailboxDwell = Histogram<UInt64>(
        capacity: audioMailboxDwellWindow, retention: .rolling
    )
    /// Split video path timing: prepare (Annex-B + RS-FEC) is off-lock;
    /// commit (seq allocation, sealing, pacer insertion) is under it.
    private(set) var videoPrepareMaxNS: UInt64 = 0
    private(set) var videoCommitLockWaitMaxNS: UInt64 = 0
    private(set) var videoCommitLockHoldMaxNS: UInt64 = 0
    private(set) var serviceOnceMaxNS: UInt64 = 0
    private(set) var receiveAllMaxNS: UInt64 = 0
    /// Mutated under `lock` (the mailbox counters above use
    /// `audioMailboxLock`).
    private(set) var audioSendFailures = 0
    private(set) var audioPacketsDroppedPreSession = 0
    /// Read after shutdown.
    var outboxCounters: SocketOutboxCounters { outbox.counters }
    private(set) var socketSendBufferBytes = 0
    private(set) var latencySocketSendBufferBytes = 0
    private(set) var latencySocketOutqMaxBytes = 0
    private(set) var socketOutqMaxBytes = 0
    private(set) var socketOutqQueryFailures = 0
    private(set) var receiveTransientErrors = 0
    private var currentVideoSocketOutqBytes = 0
    private var currentLatencySocketOutqBytes = 0
    private var kernelPressureGovernor = KernelPressureGovernor()
    private var kernelPressureDecision: KernelPressureDecision?
    private(set) var sendErrors = 0
    /// Agreed capability flags, published once at agreement. Under
    /// `configLock`, never the session lock, so the audio and capture
    /// polls never wait behind a video commit.
    private struct AgreedMediaPosture {
        var audioQuiet = false
        var videoQuiet = false
        var chromaModes: [UInt64]?
    }
    private var _agreedPosture = AgreedMediaPosture()
    /// Log throttle: the last rate a `rate:` line reported.
    private var lastPrintedRate: Int?
    /// Armed by main once the encoder's opening posture is known.
    /// Mutated under `lock`.
    private var vbvPolicy: EncoderVbvPolicy?
    private(set) var vbvDirectivesIssued = 0
    private(set) var lastVbvDirective: EncoderRateDirective?
    /// Estimator moves the rung ladder absorbed: the pacer carried them
    /// alone, with no encoder reset or IDR.
    var vbvRateMovesAbsorbed: Int {
        lock.lock()
        defer { lock.unlock() }
        return vbvPolicy?.rateMovesAbsorbed ?? 0
    }
    /// ECONNREFUSED (LYTE_NETIO_PEER_GONE): the client's socket is
    /// closed — session-ending, not an I/O failure.
    private(set) var peerGone = false

    /// The sender thread's wake eventfd, signaled when bytes are enqueued.
    private var wakeFd: Int32
    /// `release()` ran: the media sockets and the wake eventfd are closed.
    private var released = false
    /// Guards the sender thread's lifecycle flags below. Lock order:
    /// `lock` → `drainCondition` (takeLegSnapshot), never the reverse.
    private let drainCondition = NSCondition()
    private var drainStop = false
    private var drainExited = false
    /// The last flush ended on a full socket buffer (the lane to wait on
    /// for POLLOUT) or on ENOBUFS (a short back-off). Under `lock`.
    private var blockedLane: SocketLane?
    private var noBufferBackoff = false
    /// A drain-thread send failure other than peer-gone: loud and
    /// session-ending.
    private var drainFailed = false

    /// Everything the capture loop consults per poll, in one session-lock
    /// acquisition. Taking it consumes the pending IDR demand and rate
    /// directive.
    struct LegSnapshot {
        /// The peer is gone, the lifecycle closed, or the drain thread
        /// failed: the capture loop quits.
        var ended: Bool
        var agreedChromaModes: [UInt64]?
        var videoQuietPostureAgreed: Bool
        /// Monotonic ns of the last client input (the video posture's wake).
        var lastInputActivityNS: UInt64
        /// A rate-control move the encoder must apply before its next frame.
        var directive: EncoderRateDirective?
        /// A forced IDR owed on the next encode, with its causes.
        var demand: FreshKeyframeDemand
    }

    func takeLegSnapshot() -> LegSnapshot {
        let (posture, inputNS) = withConfigLock {
            (_agreedPosture, _lastInputActivityNS)
        }
        lock.lock()
        defer { lock.unlock() }
        var ended = peerGone || session?.lifecycleState == .closed
        if !ended {
            drainCondition.lock()
            ended = drainFailed
            drainCondition.unlock()
        }
        return LegSnapshot(
            ended: ended,
            agreedChromaModes: posture.chromaModes,
            videoQuietPostureAgreed: posture.videoQuiet,
            lastInputActivityNS: inputNS,
            directive: takeEncoderRateDirectiveLocked(),
            demand: session?.takeFreshKeyframeDemand() ?? [])
    }

    var counters: VideoChannelCounters { session.videoCounters }
    var sessionCounters: SessionCounters { session.counters }
    var freshKeyframeDemandCounts: FreshKeyframeDemandCounts {
        session.freshKeyframeDemandCounts
    }
    var clipboardImageCounters: ClipboardImageChannelCounters {
        session.clipboardImageCounters
    }
    /// Nil until the client's declaration lands. The Sink branches the
    /// encoder posture on it at open.
    var agreedChromaModes: [UInt64]? {
        withConfigLock { _agreedPosture.chromaModes }
    }
    /// Whether the flood dial currently demands a retry cookie.
    var handshakeCookieMode: Bool { session?.handshakeCookieMode ?? false }
    var clock: SessionClockStats { session.clock }
    var pacerTelemetry: PacerTelemetry { session.pacerTelemetry }
    var lifecycleState: SessionState? { session?.lifecycleState }
    var currentWireMode: SessionWireMode? { session?.wireMode }
    var estimatorStats: RateEstimatorStats { session.estimatorStats }
    var estimatedRate: Int { session.estimatedRateBitsPerSecond }
    var pacerRate: Int { session.pacerRateBitsPerSecond }
    var deliveryRate: Int? { session.deliveryRateBitsPerSecond }
    var measuredDeliveryRate: Int? { session.measuredDeliveryRateBitsPerSecond }
    var capacityBelief: Int? { session.capacityBeliefBitsPerSecond }
    var queuingDelayMicros: Int64? { session.queuingDelayMicroseconds }
    var kernelPressureState: KernelPressureState {
        kernelPressureDecision?.state ?? .calm
    }
    var kernelVideoServiceDebtNS: UInt64 {
        kernelPressureDecision?.totalVideoServiceDebtNS ?? 0
    }
    func frameByteCeiling(fps: Int) -> Int { session.frameByteCeiling(fps: fps) }
    // Unprotectable-frame guard: the live drop count and the worst-case
    // ceiling the shell caps the encoder's opening VBV to.
    var videoFramesUnprotectable: Int {
        session.counters.videoFramesUnprotectable
    }
    var protectableFrameCeiling: Int {
        session.protectableFrameByteCeiling
    }
    var worstCaseProtectableFrameCeiling: Int {
        session.worstCaseProtectableFrameByteCeiling
    }
    var fecRegime: FecRegime { session.fecRegime }
    var srttMicros: Int64? { session.srttMicroseconds }
    var repairStoreBytes: Int { session.repairStoreBytes }
    /// Bytes that entered through the borrowed (zero-copy) callback seam.
    private(set) var borrowedFrameBytesIngested: UInt64 = 0
    /// The derived freeze budget in force (ms).
    var repairBudgetMS: UInt64 { session.repairFreezeBudgetNS / 1_000_000 }

    /// - Parameters:
    ///   - listener: the service's listening socket (nil = open one on a
    ///     kernel-assigned port, requires `peer`).
    ///   - peer: optional pre-connected far end; Noise message 1 must
    ///     still arrive from it before the session is established.
    init(
        listener: HostListener?,
        peer: (host: String, port: UInt16)?,
        rateBitsPerSecond: Int,
        capabilities: Capabilities = .wireDefault,
        allowedClientStatics: [[UInt8]]? = nil,
        handshakeGateConfig: HandshakeGate.Config = HandshakeGate.Config(),
        pairing: PairingResponderService? = nil,
        onPairingEvent: @escaping (PairingResponderService.Event) -> Void
            = { _ in }
    ) throws {
        precondition(listener != nil || peer != nil,
                     "a session needs a port to listen on or a peer")
        // Nothing may throw past thread.start() below: the drain thread
        // would be left holding a deinit'd `self`.
        self.rateBitsPerSecond = rateBitsPerSecond
        self.capabilities = capabilities
        self.allowedClientStatics = allowedClientStatics
        self.handshakeGateConfig = handshakeGateConfig
        self.pairing = pairing
        self.onPairingEvent = onPairingEvent

        self.requiredPeer = peer
        let listening = try listener ?? HostListener(port: 0)
        self.listener = listening
        listenNetio = listening.netio
        wakeFd = lyte_netio_wake_new()
        guard wakeFd >= 0 else {
            throw HostError("sender wake eventfd failed (errno \(errno))")
        }
        scratch = UnsafeMutablePointer<UInt8>.allocate(
            capacity: Self.scratchCapacity)
        sendPackets.reserveCapacity(Int(LYTE_NETIO_MAX_BATCH))
        let recvBatchSize = Int(LYTE_NETIO_MAX_BATCH)
        let recvSlotCapacity = Self.recvSlotCapacity
        let recvBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: recvBatchSize * recvSlotCapacity)
        recvScratch = recvBuffer
        var slots: [lyte_netio_slot] = []
        slots.reserveCapacity(recvBatchSize)
        for i in 0..<recvBatchSize {
            var slot = lyte_netio_slot()
            slot.data = recvBuffer.advanced(by: i * recvSlotCapacity)
            slot.cap = recvSlotCapacity
            slots.append(slot)
        }
        recvSlots = slots
        if let peer {
            try connectMedia(host: peer.host, port: peer.port)
        }

        // The sender thread comes up parked and holds `self` until
        // stopped (shutdown does). SessionWire is cross-thread by design
        // with `lock` as the discipline; the unsafe capture says so.
        nonisolated(unsafe) let shared = self
        let thread = Thread {
            // Audio (12) outranks the drain: its cadence bound is tighter.
            elevateCurrentThread("wire-drain", rtPriority: 10)
            shared.drainLoop()
        }
        thread.name = "lyte-wire-drain"
        thread.start()
    }

    deinit {
        closeSessionDescriptors()
        scratch.deallocate()
        recvScratch.deallocate()
    }

    /// Stops the sender thread, closes the media sockets and wake eventfd,
    /// and drops the shell hooks (the audio-routing handler retains this
    /// wire). The listening socket stays with its HostListener. Call after
    /// `shutdown`, once every calling thread has stopped. Idempotent.
    func release() {
        stopDrain()
        inputInjector = nil
        audioRoutingHandler = nil
        clipboardApplyHandler = nil
        clipboardImageApplyHandler = nil
        shellServiceHook = nil
        bulkShell = nil
        lock.lock()
        closeSessionDescriptors()
        lock.unlock()
        try? handshakeWitness?.close()
    }

    private func closeSessionDescriptors() {
        guard !released else { return }
        released = true
        if let latencyNetio {
            lyte_netio_free(latencyNetio)
            self.latencyNetio = nil
        }
        if let videoNetio {
            lyte_netio_free(videoNetio)
            self.videoNetio = nil
        }
        close(wakeFd)
        wakeFd = -1
    }

    private func traceHandshake(
        _ event: String, fields: [String: String] = [:]
    ) {
        guard let handshakeWitness else { return }
        var object = fields
        object["event"] = event
        object["monotonicNanoseconds"] = String(SystemMonotonicClock.nowNanoseconds)
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        else { return }
        handshakeWitness.write(data)
        handshakeWitness.write(Data([0x0A]))
    }

    /// Opens the media sockets on first use, else re-connects them.
    private func connectMedia(host: String, port: UInt16) throws {
        var err = [CChar](repeating: 0, count: 256)
        func open(priority: Int32, _ what: String) throws -> OpaquePointer {
            guard let socket = lyte_netio_new(
                "0.0.0.0", lyte_netio_local_port(listenNetio), &err, err.count
            ) else {
                throw HostError("\(what) socket open failed: \(errString(err))")
            }
            guard lyte_netio_set_priority(socket, priority) == 0 else {
                lyte_netio_free(socket)
                throw HostError("\(what) socket SO_PRIORITY failed")
            }
            return socket
        }
        if videoNetio == nil {
            let video = try open(priority: 4, "video")
            videoNetio = video
            socketSendBufferBytes = max(
                Int(lyte_netio_send_buffer_bytes(video)), 0)
        }
        if latencyNetio == nil {
            let latency = try open(priority: 6, "latency")
            latencyNetio = latency
            latencySocketSendBufferBytes = max(
                Int(lyte_netio_send_buffer_bytes(latency)), 0)
        }
        for (socket, what) in [(videoNetio!, "video"), (latencyNetio!, "latency")] {
            guard lyte_netio_set_peer(socket, host, port, &err, err.count) == 0
            else {
                throw HostError(
                    "\(what) connect to \(host):\(port) failed: \(errString(err))")
            }
        }
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
            now: SystemMonotonicClock.nowNanoseconds,
            rng: SystemRandomNumberGenerator(),
            sendAccounting: .socketConfirmed
        ) { [weak self] datagram in
            self?.outbox.enqueue(
                datagram, now: SystemMonotonicClock.nowNanoseconds)
        }
    }

    @discardableResult
    private func observeKernelPressure(
        _ session: Session, now: UInt64
    ) -> KernelPressureDecision {
        let videoOutq = Int(lyte_netio_outq_bytes(videoNetio ?? listenNetio))
        if videoOutq >= 0 {
            currentVideoSocketOutqBytes = videoOutq
            socketOutqMaxBytes = max(socketOutqMaxBytes, videoOutq)
        } else {
            socketOutqQueryFailures += 1
        }
        if let latencyNetio {
            let latencyOutq = Int(lyte_netio_outq_bytes(latencyNetio))
            if latencyOutq >= 0 {
                currentLatencySocketOutqBytes = latencyOutq
                latencySocketOutqMaxBytes = max(
                    latencySocketOutqMaxBytes, latencyOutq)
            } else {
                socketOutqQueryFailures += 1
            }
        }
        let decision = kernelPressureGovernor.observe(
            KernelPressureSample(
                nowNS: now,
                userspaceVideoBytes: session.queuedVideoBytes,
                videoKernelBytes: currentVideoSocketOutqBytes,
                latencyKernelBytes: currentLatencySocketOutqBytes,
                videoSendBufferBytes: socketSendBufferBytes,
                latencySendBufferBytes: latencySocketSendBufferBytes,
                videoWouldBlockCount: outbox.counters.videoWouldBlockCount,
                latencyWouldBlockCount: outbox.counters.latencyWouldBlockCount,
                videoENOBUFSCount: outbox.counters.videoNoBufferCount,
                latencyENOBUFSCount: outbox.counters.latencyNoBufferCount,
                pacerRateBitsPerSecond: session.pacerRateBitsPerSecond,
                videoQueueBudgetNS: session.videoQueueBudgetNS,
                frameBudgetBytes: session.frameByteCeiling(fps: 60)))
        kernelPressureDecision = decision
        return decision
    }

    private func pumpForSocketState(_ session: Session) {
        let now = SystemMonotonicClock.nowNanoseconds
        let pressure = observeKernelPressure(session, now: now)
        if pressure.state == .latencyOnly {
            outbox.shedOldestStaleFreshVideo(
                ledger: session, now: now,
                budgetNS: session.videoQueueBudgetNS)
        }
        if outbox.isEmpty, pressure.allowVideoPump {
            session.pump(now: now)
        } else {
            session.pumpLatency(now: now)
        }
    }

    /// Blocks until a client completes the handshake and proves it holds
    /// the session keys (its first authenticated datagram), for up to
    /// `timeoutSeconds` (nil = forever). Call before capture opens.
    ///
    /// Answering commits nothing — Noise IK message 1 carries no
    /// freshness. A message 1 this process already answered is dropped
    /// unread; a newer one that authenticates replaces an unconfirmed
    /// session; an unconfirmed session whose lifecycle closes is
    /// discarded. So no replayed, spoofed or abandoned message 1 can lock
    /// out the next client. A wire-out host accepts only its peer.
    ///
    /// `idle` runs off the lock once per wait pass (~2 ms).
    func awaitClient(
        hostStatic: NoiseKeyPair,
        timeoutSeconds: Double?,
        stopRequested: () -> Bool = { false },
        idle: () -> Void = {}
    ) throws -> ClientAwaitOutcome {
        print("""
            noise: host static public key \
            \(Hex.string(hostStatic.publicKey))
            """)
        print("""
            noise: awaiting client handshake on port \
            \(lyte_netio_local_port(listenNetio)) …
            """)
        traceHandshake("awaitClientBegin", fields: [
            "pid": String(getpid()),
            "primaryLocalPort": String(lyte_netio_local_port(listenNetio)),
        ])

        let deadline = timeoutSeconds.map {
            SystemMonotonicClock.nowNanoseconds + UInt64($0 * 1e9)
        }
        while deadline.map({ SystemMonotonicClock.nowNanoseconds < $0 }) ?? true {
            if stopRequested() {
                return .terminationRequested
            }
            lock.lock()
            do {
                try receiveFromAll { [weak self] datagram, tuple in
                    self?.awaitDatagram(datagram, from: tuple, hostStatic: hostStatic)
                }
                if let session, session.phase == .established {
                    // The answered session's timers run here until it is
                    // confirmed; the sender thread takes over after.
                    for event in session.advance(
                        now: SystemMonotonicClock.nowNanoseconds,
                        hostMicroseconds: SystemMonotonicClock.nowMicroseconds
                    ) {
                        execute(event)
                    }
                    if session.lifecycleState == .closed {
                        emit("""
                            noise: answered handshake never confirmed \
                            — discarded, awaiting a client
                            """)
                        discardUnconfirmedSession()
                    }
                }
                // Pre-establishment pump: carries 0x13 RetryChallenges
                // under flood, message 2 and the opening words.
                if let session {
                    pumpForSocketState(session)
                }
                try flushOutbox()
            } catch {
                lock.unlock()
                flushLogLines()
                throw error
            }
            let done = session?.isPeerConfirmed == true
            lock.unlock()
            flushLogLines()
            if done {
                signalDrain()
                return .established
            }
            idle()
            usleep(2_000)
        }
        if stopRequested() {
            return .terminationRequested
        }
        throw HostError("""
            no client handshake within \(Int(timeoutSeconds ?? 0))s \
            — is lyte-cli wire-view pointed at this host and holding \
            the printed static key?
            """)
    }

    /// Requires `lock`. One datagram while awaiting a confirmed client.
    private func awaitDatagram(
        _ datagram: [UInt8], from tuple: FourTuple, hostStatic: NoiseKeyPair
    ) {
        let message1 = Session.handshakeMessage1(in: datagram)
        guard message1 != nil || session?.phase == .established else {
            // Before an answer only an initiation matters: a relaunched
            // host also hears the old session's feedback.
            traceAwaitDatagram(datagram, from: tuple, accepted: false)
            return
        }
        if let message1 {
            // Shape check, not trust: the gate still authenticates.
            let plausible = admitsPeer(tuple)
                && (message1 == session?.answeredMessage1
                    || !listener.answeredHandshakes.contains(message1: message1))
            traceAwaitDatagram(datagram, from: tuple, accepted: plausible)
            guard plausible else { return }
        }
        if session == nil {
            makeSession(crypto: .noise(hostStatic: hostStatic), clientTuple: tuple)
        }
        let wasConfirmed = session.isPeerConfirmed
        for event in session.receive(
            datagram, from: tuple,
            now: SystemMonotonicClock.nowNanoseconds,
            hostMicroseconds: SystemMonotonicClock.nowMicroseconds
        ) {
            execute(event)
        }
        if let superseding = session.takeSupersedingHandshake() {
            handshakesSuperseded += 1
            emit("""
                noise: a newer handshake from \
                \(superseding.clientTuple.remoteAddress):\
                \(superseding.clientTuple.remotePort) replaces the \
                unconfirmed one
                """)
            discardUnconfirmedSession()
            makeSession(
                crypto: .noise(hostStatic: hostStatic),
                clientTuple: superseding.clientTuple)
            for event in session.completeSupersedingHandshake(
                superseding,
                now: SystemMonotonicClock.nowNanoseconds,
                hostMicroseconds: SystemMonotonicClock.nowMicroseconds
            ) {
                execute(event)
            }
        }
        if let answered = session.answeredMessage1 {
            listener.answeredHandshakes.record(message1: answered)
        }
        if !wasConfirmed, session.isPeerConfirmed {
            emit("noise: client confirmed — it holds the session keys")
        }
    }

    private func traceAwaitDatagram(
        _ datagram: [UInt8], from tuple: FourTuple, accepted: Bool
    ) {
        awaitPrimaryDatagrams += 1
        guard handshakeWitness != nil else { return }
        let payloadType: UInt8? = (try? Envelope.decode(datagram[...]))?.1.first
        traceHandshake("primaryDatagram", fields: [
            "ordinal": String(awaitPrimaryDatagrams),
            "bytes": String(datagram.count),
            "remoteAddress": tuple.remoteAddress,
            "remotePort": String(tuple.remotePort),
            "shapeAccepted": String(accepted),
            "payloadType": payloadType.map(String.init) ?? "",
        ])
    }

    /// Requires `lock`. Drops an unconfirmed session and its queue; the
    /// media sockets stay open for the next handshake.
    private func discardUnconfirmedSession() {
        outbox.dropAll()
        blockedLane = nil
        noBufferBackoff = false
        peerGone = false
        session = nil
    }

    /// The session port (the kernel's pick when bound to port 0).
    var localPort: UInt16 { lyte_netio_local_port(listenNetio) }

    /// wire-out mode admits only its configured peer.
    private func admitsPeer(_ tuple: FourTuple) -> Bool {
        guard let requiredPeer else { return true }
        return tuple.remoteAddress == requiredPeer.host
            && tuple.remotePort == requiredPeer.port
    }

    /// One receive batch from every socket. A closed session leaves the
    /// listening socket alone: what arrives there belongs to the next
    /// session.
    private func receiveFromAll(
        _ handle: ([UInt8], FourTuple) -> Void
    ) throws {
        if session?.lifecycleState != .closed {
            try receiveAll(from: listenNetio, handle)
        }
        if let videoNetio { try receiveAll(from: videoNetio, handle) }
        if let latencyNetio { try receiveAll(from: latencyNetio, handle) }
    }

    /// Requires `lock`. One datagram into an established session.
    private func receiveEstablished(_ datagram: [UInt8], from tuple: FourTuple) {
        guard let session else { return }
        for event in session.receive(
            datagram, from: tuple,
            now: SystemMonotonicClock.nowNanoseconds,
            hostMicroseconds: SystemMonotonicClock.nowMicroseconds
        ) {
            execute(event)
        }
        // A long recvmmsg burst must not consume an audio period.
        drainAudioMailboxLocked()
    }

    /// Arms the encoder-VBV policy once the encoder's opening posture is
    /// known.
    func armEncoderVbv(_ config: EncoderVbvConfig) {
        lock.lock()
        defer { lock.unlock() }
        vbvPolicy = EncoderVbvPolicy(config: config)
    }

    /// Requires `lock`. A non-nil directive must reach the encoder before
    /// the next frame is sent.
    private func takeEncoderRateDirectiveLocked() -> EncoderRateDirective? {
        guard let vbvPolicy, let session, session.phase == .established
        else { return nil }
        guard let directive = vbvPolicy.note(
            frameByteCeiling: session.frameByteCeiling(
                fps: vbvPolicy.config.fps),
            now: SystemMonotonicClock.nowNanoseconds
        ) else { return nil }
        vbvDirectivesIssued += 1
        lastVbvDirective = directive
        return directive
    }

    /// The orderly close: SessionTeardown 0x0A on the reliable stream,
    /// then a bounded linger so it can be acknowledged before exit.
    func shutdown(reason: SessionTeardownReason, lingerSeconds: Double = 0.5) {
        // Flush audio's final quantum while the session still exists.
        lock.lock()
        drainAudioMailboxLocked()
        lock.unlock()
        // Teardown owns the send path from here.
        stopDrain()
        runPendingPairingEvents()
        lock.lock()
        // An unconfirmed peer may be a replay's phantom: no teardown.
        guard let session, session.isPeerConfirmed,
              session.lifecycleState != .closed, !peerGone else {
            lock.unlock()
            return
        }
        for event in session.beginTeardown(
            reason: reason,
            now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
        ) {
            execute(event)
        }
        lock.unlock()
        let deadline = SystemMonotonicClock.nowNanoseconds + UInt64(lingerSeconds * 1e9)
        while SystemMonotonicClock.nowNanoseconds < deadline {
            lock.lock()
            if session.arqIsQuiescent || peerGone {
                lock.unlock()
                break
            }
            do {
                try serviceOnce()
                try flushOutbox()
            } catch {
                noteSendError(error)
                lock.unlock()
                break
            }
            lock.unlock()
            usleep(2_000)
        }
        flushLogLines()
        runPendingPairingEvents()
        print(session.arqIsQuiescent
            ? "session: teardown acknowledged — clean close"
            : """
                session: teardown sent, unacknowledged after \
                \(Int(lingerSeconds * 1000)) ms — closing anyway
                """)
    }

    /// One encoded Annex-B packet → sealed shards, on the capture thread.
    /// Validation and RS-FEC run off the session lock (they can starve
    /// audio); sealing and pacer insertion run under it.
    func sendFrame(
        data: UnsafePointer<UInt8>, size: Int, isKeyframe: Bool,
        captureMicros: UInt64
    ) throws {
        let frame = UnsafeBufferPointer(start: data, count: size)
        borrowedFrameBytesIngested &+= UInt64(size)

        lock.lock()
        guard let session else {
            lock.unlock()
            throw HostError("sendFrame before the session exists")
        }
        drainAudioMailboxLocked()
        let context: SessionVideoFramePreparationContext?
        do {
            context = try session.beginVideoFramePreparation(
                encodedByteCount: size
            )
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        let prepared: PreparedVideoFrame?
        if let context {
            let prepareStart = SystemMonotonicClock.nowNanoseconds
            prepared = try Session.prepareVideoFrame(
                frame, isKeyframe: isKeyframe, context: context
            )
            videoPrepareMaxNS = max(
                videoPrepareMaxNS, SystemMonotonicClock.nowNanoseconds - prepareStart
            )
        } else {
            prepared = nil
        }

        let commitWaitStart = SystemMonotonicClock.nowNanoseconds
        lock.lock()
        videoCommitLockWaitMaxNS = max(
            videoCommitLockWaitMaxNS, SystemMonotonicClock.nowNanoseconds - commitWaitStart
        )
        let commitHoldStart = SystemMonotonicClock.nowNanoseconds
        drainAudioMailboxLocked()
        do {
            if let context, let prepared {
                let shards = try session.commitPreparedVideoFrame(
                    prepared,
                    context: context,
                    captureTimestampMicroseconds: captureMicros,
                    interleave: { [unowned self] in
                        self.drainAudioMailboxLocked()
                    },
                    now: SystemMonotonicClock.nowNanoseconds,
                    isBorrowed: true
                )
                lastFrameForTelemetry = shards > 0
                    ? session.lastAdmittedVideoFrameNumber : nil
            } else {
                lastFrameForTelemetry = nil
            }
        } catch {
            lock.unlock()
            throw error
        }
        // First quantum leaves on this stack (one batch, tens of µs).
        pumpForSocketState(session)
        do {
            try flushOutbox()
        } catch {
            lock.unlock()
            throw error
        }
        videoCommitLockHoldMaxNS = max(
            videoCommitLockHoldMaxNS, SystemMonotonicClock.nowNanoseconds - commitHoldStart
        )
        lock.unlock()
        signalDrain()
    }

    func annotateLastVideoFrame(
        averageQP: Int?, idrCauses: [String]
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let frame = lastFrameForTelemetry else { return }
        session.annotateVideoFrameTelemetry(
            frame: frame, averageQP: averageQP, idrCauses: idrCauses
        )
    }

    /// VideoAdmissionGate's inputs — queued video wire time and the
    /// budget in force — from one locked snapshot so they cannot mix eras.
    var videoAdmissionPosture: (backlogWireTimeNS: UInt64, budgetNS: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return (0, UInt64.max) }
        let pressure = observeKernelPressure(
            session, now: SystemMonotonicClock.nowNanoseconds)
        return (pressure.totalVideoServiceDebtNS, pressure.admissionBudgetNS)
    }

    /// One encoded 5 ms Opus packet from the audio thread. Audio flows in
    /// idle and frozen too; only `closed` suppresses it.
    func sendAudioPacket(_ packet: [UInt8], captureMicros: UInt64) {
        publishAudio(.packet(
            bytes: packet, captureMicros: captureMicros,
            offeredAtNS: SystemMonotonicClock.nowNanoseconds))
    }

    /// One 0x25 track-state announcement (a no-op unless key 15 was
    /// agreed). It rides the audio mailbox, ordered with the packets.
    func sendAudioTrackState(_ state: AudioTrackState.State) {
        publishAudio(.trackState(state))
    }

    /// The audio thread's only entry into the session: it takes the
    /// mailbox lock and never waits behind video or session service.
    private func publishAudio(_ entry: AudioMailboxEntry) {
        audioMailboxLock.lock()
        if case .trackState = entry {
            // Rare and stateful: an announcement is never dropped.
            audioMailbox.append(entry)
        } else if audioMailbox.count < Self.audioMailboxCapacity {
            audioMailbox.append(entry)
            audioMailboxMaxDepth = max(audioMailboxMaxDepth, audioMailbox.count)
        } else {
            audioMailboxOverflows += 1
        }
        audioMailboxLock.unlock()

        // Use this wake directly when the lock is free, so audio does not
        // depend solely on the sender being scheduled. try() never
        // blocks, and the audio thread never does console I/O.
        if lock.try() {
            drainAudioMailboxLocked()
            if let session, session.phase == .established, !peerGone {
                pumpForSocketState(session)
                do {
                    try flushOutbox()
                } catch {
                    audioSendFailures += 1
                    noteSendError(error)
                }
            }
            lock.unlock()
        }
        signalDrain()
    }

    /// Requires `lock`. The mailbox lock is held only to swap the FIFO.
    private func drainAudioMailboxLocked() {
        audioMailboxLock.lock()
        var pending: [AudioMailboxEntry] = []
        swap(&pending, &audioMailbox)
        audioMailboxLock.unlock()
        guard !pending.isEmpty else { return }

        for entry in pending {
            guard let session, session.phase == .established, !peerGone else {
                if case .packet = entry { audioPacketsDroppedPreSession += 1 }
                continue
            }
            let now = SystemMonotonicClock.nowNanoseconds
            switch entry {
            case .packet(let bytes, let captureMicros, let offeredAtNS):
                let dwell = now &- offeredAtNS
                audioMailboxMaxDwellNS = max(audioMailboxMaxDwellNS, dwell)
                audioMailboxDwell.record(dwell)
                do {
                    _ = try session.ingestAudioPacket(
                        bytes,
                        captureTimestampMicroseconds: captureMicros,
                        now: now
                    )
                    pumpForSocketState(session)
                    try flushOutbox()
                } catch {
                    audioSendFailures += 1
                    noteSendError(error)
                }
            case .trackState(let state):
                for event in session.noteAudioTrackState(
                    state, now: now,
                    hostMicroseconds: SystemMonotonicClock.nowMicroseconds
                ) {
                    execute(event)
                }
                pumpForSocketState(session)
                do {
                    try flushOutbox()
                } catch {
                    noteSendError(error)
                }
            }
        }
    }

    /// The janitor's pass: inbound datagrams, session timers, pacer
    /// leftovers, then the shell work that must run off the lock.
    func service() {
        lock.lock()
        guard session != nil else {
            lock.unlock()
            return
        }
        serviceAndFlushLocked()
        // What this pass could not emit belongs to the sender thread.
        let leftovers = !(session?.isIdle ?? true) || !outbox.isEmpty
        let requests = pendingAudioRouting
        pendingAudioRouting.removeAll()
        let announce = routingAnnounceOwed
        routingAnnounceOwed = false
        let standing = currentAudioRouting
        let cursorOwed = cursorAnnounceOwed
        cursorAnnounceOwed = false
        let standingCursor = standingCursorShape
        let applies = pendingClipboardApplies
        pendingClipboardApplies.removeAll()
        let imageApplies = pendingClipboardImageApplies
        pendingClipboardImageApplies.removeAll()
        let bulk = pendingBulkMessages
        pendingBulkMessages.removeAll()
        let pairingEvents = pendingPairingEvents
        pendingPairingEvents.removeAll()
        lock.unlock()
        flushLogLines()
        if leftovers { signalDrain() }
        for event in pairingEvents {
            onPairingEvent(event)
        }

        // Each of these re-takes the lock per send and never holds it
        // across PipeWire, D-Bus or disk work (the clipboard leaf
        // re-enters through noteHostClipboardChanged).
        if announce {
            noteAudioRoutingApplied(standing)
        }
        if cursorOwed, let shape = standingCursor {
            noteCursorShape(shape)
        }
        for mode in requests {
            applyAudioRouting(mode)
        }
        for text in applies {
            clipboardApplyHandler?(text)
        }
        for data in imageApplies {
            clipboardImageApplyHandler?(data)
        }
        shellServiceHook?()
        driveBulkShell(bulk)
    }

    /// Buffered chan-8 messages through the BulkReceiveShell, then its
    /// replies back onto chan 8's ordered stream under the lock.
    private func driveBulkShell(_ messages: [BulkMessage]) {
        guard let shell = bulkShell, !messages.isEmpty else { return }
        var replies: [BulkMessage] = []
        for message in messages {
            for event in shell.ingest(message) {
                switch event {
                case .send(let reply):
                    replies.append(reply)
                case .offerAccepted(let id, let name, let bytes, let resuming):
                    print("""
                        files: offer \(Hex.string(id)) accepted — \
                        \"\(BulkFileNaming.sanitized(name))\" \
                        (\(bytes) B\(resuming ? ", RESUMING" : ""))
                        """)
                case .offerRefusedBusy(let id):
                    print("""
                        files: offer \(Hex.string(id)) refused — \
                        busy (one transfer at a time in v1)
                        """)
                case .insufficientDiskSpace(let needed, let free):
                    print("""
                        files: offer refused — needs \(needed) B, \
                        \(free) B free
                        """)
                case .fileCompleted(let name, let path, let bytes):
                    print("""
                        files: COMPLETE — \"\(name)\" (\(bytes) B, \
                        sha-verified) → \(path)
                        """)
                case .transferAborted(let reason, let byRemote):
                    print("""
                        files: transfer aborted (\(reason), \
                        \(byRemote ? "remote" : "local"))
                        """)
                case .storageFailure(let detail):
                    print("files: STORAGE FAILURE — \(detail)")
                case .violated(let violation):
                    print("files: protocol violation — \(violation)")
                }
            }
        }
        guard !replies.isEmpty else { return }
        withEstablishedSession { session, now, hostMicroseconds in
            for reply in replies {
                do {
                    try session.sendBulk(
                        reply.encode(), now: now,
                        hostMicroseconds: hostMicroseconds)
                } catch {
                    emit("files: bulk send failed: \(error)")
                }
            }
            return []
        }
        flushLogLines()
    }

    /// The hardware cursor plane changed (a cropped shape or hidden).
    /// Remembered as the standing shape; the core decides the 0x24 and
    /// a session without key 13 stays silent.
    func noteCursorShape(_ shape: CursorShape) {
        withEstablishedSession(before: { standingCursorShape = shape }) {
            $0.noteCursorShapeChanged(shape, now: $1, hostMicroseconds: $2)
        }
    }

    /// The last absolute pointer injected and when, for the cursor
    /// watcher's hotspot derivation.
    func lastAbsolutePointerInjection(
    ) -> (x: Double, y: Double, atMicros: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = lastAbsolutePointer else { return nil }
        return (p.x, p.y, lastPointerMotionInjectedAt)
    }

    /// The OS clipboard changed — host copies and echoes of our own
    /// applies alike; the core's sync book tells them apart and a
    /// session without key 10 stays silent.
    func noteHostClipboardChanged(_ text: String) {
        withEstablishedSession {
            $0.noteHostClipboardChanged(text, now: $1, hostMicroseconds: $2)
        }
    }

    /// The OS clipboard now holds an image (whole PNG bytes); same
    /// echo handling, gated on keys 10 and 12.
    ///
    /// Three phases: the digest-free gates under the lock, the digest
    /// outside it (tens of MiB must not stall receive and pacing), then
    /// the judgment under the lock again. A refused image is never
    /// hashed.
    func noteHostClipboardImageChanged(_ data: [UInt8]) {
        var needsDigest = false
        withEstablishedSession { session, now, _ in
            guard let settled = session.prejudgeHostClipboardImage(
                byteCount: data.count, now: now)
            else {
                needsDigest = true
                return []
            }
            return settled
        }
        guard needsDigest else { return }
        let digest = Sha256.digest(data)
        withEstablishedSession {
            $0.noteHostClipboardImageChanged(
                data, sha256: { digest }, now: $1, hostMicroseconds: $2)
        }
    }

    /// The posture the audio leaf came up in.
    func setInitialAudioRouting(_ mode: HostAudioRoutingMode) {
        lock.lock()
        defer { lock.unlock() }
        currentAudioRouting = mode
    }

    /// A pairing that completed in the final service window still gets
    /// its keystore write.
    private func runPendingPairingEvents() {
        lock.lock()
        let events = pendingPairingEvents
        pendingPairingEvents.removeAll()
        lock.unlock()
        for event in events { onPairingEvent(event) }
    }

    /// One 0x18 answered: flip the leaf, then report the posture that
    /// actually stands (a failed flip reports the old one).
    private func applyAudioRouting(_ mode: HostAudioRoutingMode) {
        lock.lock()
        let standing = currentAudioRouting
        lock.unlock()
        if mode == standing {
            noteAudioRoutingApplied(standing) // re-affirm, truthfully
            return
        }
        guard let handler = audioRoutingHandler else {
            print("""
                audio-routing: \(mode) requested but no flip surface \
                is active this run — posture stays \(standing)
                """)
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
            print("""
                audio-routing: flip to \(mode) FAILED — posture \
                stays \(standing)
                """)
            noteAudioRoutingApplied(standing)
        }
    }

    /// The applied-posture 0x19 (a no-op unless hostAudioRouting was
    /// agreed).
    func noteAudioRoutingApplied(_ mode: HostAudioRoutingMode) {
        withEstablishedSession {
            $0.noteAudioRoutingApplied(mode, now: $1, hostMicroseconds: $2)
        }
    }

    /// Whether this session agreed key 15; without it audio is always
    /// on, silence included.
    func audioQuietPostureAgreed() -> Bool {
        withConfigLock { _agreedPosture.audioQuiet }
    }

    /// One 0x26 announcement (a no-op unless key 16 was agreed).
    func sendVideoPostureState(quiet: Bool, keepaliveSeconds: UInt8) {
        let state = VideoPostureState(
            posture: quiet ? .quiet : .active,
            keepaliveSeconds: keepaliveSeconds)
        withEstablishedSession {
            $0.noteVideoPostureState(state, now: $1, hostMicroseconds: $2)
        }
    }

    /// The video posture's wake: stamped per injected input event and
    /// read by the video leg each poll. Monotonic ns under configLock.
    private var _lastInputActivityNS: UInt64 = 0
    private var lastInputActivityNS: UInt64 {
        get { withConfigLock { _lastInputActivityNS } }
        set { withConfigLock { _lastInputActivityNS = newValue } }
    }

    /// One session note from a shell thread, under `lock`, skipped
    /// unless established; a service pass and flush follow so its sends
    /// leave now. `before` runs under the lock either way.
    private func withEstablishedSession(
        before: () -> Void = {},
        _ note: (Session, _ now: UInt64, _ hostMicroseconds: UInt64)
            -> [SessionEvent]
    ) {
        lock.lock()
        defer { lock.unlock() }
        before()
        guard let session, session.phase == .established else { return }
        for event in note(
            session, SystemMonotonicClock.nowNanoseconds,
            SystemMonotonicClock.nowMicroseconds
        ) {
            execute(event)
        }
        serviceAndFlushLocked()
    }

    /// Requires `lock`. A failure is recorded and printed; the drain
    /// thread's own pass decides whether it ends the session.
    private func serviceAndFlushLocked() {
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            noteSendError(error)
        }
    }

    /// Requires `lock`.
    private func noteSendError(_ error: Error) {
        sendErrors += 1
        if sendErrors <= 3 {
            emit("session: send path error (\(sendErrors)): \(error)")
        }
    }

    /// ECONNREFUSED, once: the client's socket is closed, so no teardown
    /// is sent; the session just ends cleanly.
    private func notePeerGone() {
        guard !peerGone else { return }
        peerGone = true
        emit("""
            session: client unreachable (ICMP port closed — it exited) \
            — closing cleanly
            """)
    }

    private func signalDrain() {
        guard wakeFd >= 0 else { return } // released
        lyte_netio_wake_signal(wakeFd)
    }

    /// Stops the sender thread and waits for it to exit (it shares the
    /// send scratch, so teardown must not race it). Idempotent.
    private func stopDrain() {
        drainCondition.lock()
        drainStop = true
        drainCondition.unlock()
        signalDrain()
        drainCondition.lock()
        while !drainExited { drainCondition.wait() }
        drainCondition.unlock()
    }

    /// What the sender thread waits for between passes.
    private struct DrainWait {
        /// Nil = until signaled (no established session, or it ended).
        var timeoutNS: Int64?
        /// Sockets whose readability (`pollIn`) or, for the one whose
        /// buffer was full, writability (`pollOut`) ends the wait.
        var sockets: [(fd: Int32, pollIn: Bool, pollOut: Bool)] = []
    }

    /// The sender thread: a service pass, then a wait on its wake
    /// eventfd, socket readability, POLLOUT on a full socket, or the
    /// session's next timer. A send failure ends the session; the thread
    /// stays stoppable.
    private func drainLoop() {
        while true {
            drainCondition.lock()
            let stop = drainStop
            if stop {
                drainExited = true
                drainCondition.broadcast()
            }
            drainCondition.unlock()
            if stop { return }
            let wait: DrainWait
            do {
                wait = try drainPass()
            } catch {
                drainCondition.lock()
                let firstFailure = !drainFailed
                drainFailed = true
                drainCondition.unlock()
                if firstFailure {
                    print("session: wire drain failed (\(error)) — closing")
                }
                wait = DrainWait()
            }
            block(until: wait)
        }
    }

    /// Callers must not hold `lock`: the wait happens outside it, so
    /// audio's 5 ms sends interleave with a long video drain.
    private func drainPass() throws -> DrainWait {
        lock.lock()
        guard let session, session.isPeerConfirmed, !peerGone else {
            lock.unlock()
            flushLogLines()
            return DrainWait()
        }
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lock.unlock()
            flushLogLines()
            throw error
        }
        let now = SystemMonotonicClock.nowNanoseconds
        let blocked = outbox.isEmpty ? nil : blockedLane
        // As in pumpForSocketState: while only latency classes are
        // released, due video must not set the wait.
        let hold: SenderWait.Hold =
            !outbox.isEmpty && noBufferBackoff ? .noBuffer
            : blocked != nil ? .socketFull
            : kernelPressureDecision?.allowVideoPump == false ? .pressure
            : .none
        let timeoutNS = SenderWait.timeoutNS(
            nowNS: now,
            latencyWakeNS: session.nextWake(now: now, upThrough: .audio),
            allWakeNS: session.nextWake(now: now),
            hold: hold)
        // A lane with no connected socket writes through the listening
        // socket, so poll that for POLLOUT. A closed session does not
        // read the listening socket, so its readability must not end the
        // wait (that would spin on the next client's message 1).
        var sockets: [(fd: Int32, pollIn: Bool, pollOut: Bool)] = [(
            lyte_netio_fd(listenNetio),
            session.lifecycleState != .closed,
            blocked.map { socket(for: $0) == nil } ?? false)]
        if let videoNetio {
            sockets.append((lyte_netio_fd(videoNetio), true, blocked == .video))
        }
        if let latencyNetio {
            sockets.append((lyte_netio_fd(latencyNetio), true, blocked == .latency))
        }
        lock.unlock()
        flushLogLines()

        return DrainWait(timeoutNS: timeoutNS, sockets: sockets)
    }

    private func block(until wait: DrainWait) {
        var fds: [Int32] = [wakeFd]
        var events: [Int16] = [Int16(POLLIN)]
        for socket in wait.sockets where socket.pollIn || socket.pollOut {
            fds.append(socket.fd)
            events.append(Int16(
                (socket.pollIn ? POLLIN : 0) | (socket.pollOut ? POLLOUT : 0)))
        }
        var revents = [Int16](repeating: 0, count: fds.count)
        _ = lyte_netio_wait(
            fds, events, &revents, Int32(fds.count), wait.timeoutNS ?? -1)
        if revents[0] != 0 {
            lyte_netio_wake_drain(wakeFd)
        }
    }

    private func serviceOnce() throws {
        let serviceStart = SystemMonotonicClock.nowNanoseconds
        defer {
            serviceOnceMaxNS = max(
                serviceOnceMaxNS, SystemMonotonicClock.nowNanoseconds - serviceStart
            )
        }
        // Audio first, before receive and timer work.
        drainAudioMailboxLocked()
        try receiveFromAll { [weak self] datagram, tuple in
            self?.receiveEstablished(datagram, from: tuple)
        }
        for event in session.advance(
            now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
        ) {
            execute(event)
        }
        // A nonempty outbox means the last write hit EAGAIN; pumping more
        // video would turn kernel backpressure into an unbounded queue,
        // so only latency classes are released until it drains.
        pumpForSocketState(session)
    }

    private func receiveAll(
        from socket: OpaquePointer,
        _ handle: ([UInt8], FourTuple) -> Void
    ) throws {
        let receiveStart = SystemMonotonicClock.nowNanoseconds
        defer {
            receiveAllMaxNS = max(
                receiveAllMaxNS, SystemMonotonicClock.nowNanoseconds - receiveStart
            )
        }
        // One recvmmsg batch per call: a continuously full socket must not
        // hold the session lock unboundedly.
        let got = recvSlots.withUnsafeMutableBufferPointer { slots in
            lyte_netio_recv_batch(socket, slots.baseAddress,
                                  Int32(slots.count),
                                  &recvError, recvError.count)
        }
        if got == LYTE_NETIO_PEER_GONE {
            notePeerGone()
            return
        }
        if got == LYTE_NETIO_TRANSIENT {
            // A consumed ICMP soft error: loss, not session death.
            receiveTransientErrors += 1
            return
        }
        if got < 0 {
            throw HostError("recv failed: \(errString(recvError))")
        }
        let localPort = lyte_netio_local_port(socket)
        for i in 0..<Int(got) {
            let slot = recvSlots[i]
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
    }

    /// Lines formatted under `lock`, printed only after it releases: a
    /// stalled stdout reader must never block a write inside the lock
    /// and freeze audio, pacing and capture. Guarded by `lock`.
    private var pendingLogLines: [String] = []

    private func emit(_ line: String) { pendingLogLines.append(line) }

    /// Callers must not hold `lock`.
    private func flushLogLines() {
        lock.lock()
        let lines = pendingLogLines
        pendingLogLines.removeAll(keepingCapacity: true)
        lock.unlock()
        for line in lines { print(line) }
    }

    /// Executes one session event under `lock`; prints go through `emit`
    /// and slow shell work is only buffered.
    private func execute(_ event: SessionEvent) {
        switch event {
        case .handshakeCompleted(let remote):
            emit("""
                noise: handshake complete — client static \
                \(Hex.string(remote))
                """)
            // The media sockets connect before message 2 is flushed; on
            // failure sends leave addressed through the listening socket.
            let client = session.validator.primary.tuple
            do {
                try connectMedia(host: client.remoteAddress, port: client.remotePort)
                traceHandshake("mediaSocketsConnected", fields: [
                    "remoteAddress": client.remoteAddress,
                    "remotePort": String(client.remotePort),
                ])
            } catch {
                emit("""
                    session: \(error) — sending addressed from the \
                    listening socket
                    """)
            }
            // Pairing binds to this session's transcript and statics; a
            // re-handshake rebinds but never refills the guess budget.
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
                emit("beacon: echo \(seq) offset \(offset) µs rtt \(rtt) µs")
            }
        case .reliableCtrl(let group, let message):
            // The pairing service claims its four CTRL types; anything
            // else is logged.
            if let pairing,
               let output = pairing.handleReliableCtrl(
                   message, now: SystemMonotonicClock.nowNanoseconds
               ) {
                for reply in output.replies {
                    do {
                        try session.sendReliable(
                            reply, now: SystemMonotonicClock.nowNanoseconds,
                            hostMicroseconds: SystemMonotonicClock.nowMicroseconds
                        )
                    } catch {
                        emit("pairing: reply send failed: \(error)")
                    }
                }
                // The keystore write runs off the lock in service().
                pendingPairingEvents.append(contentsOf: output.events)
                return
            }
            emit("""
                ctrl-arq: message group \(group.rawValue) \
                (\(message.count) B, type \
                \(Hex.string(message.first ?? 0, prefix: true)))
                """)
        case .reliableOneShotAcknowledged(let group):
            emit("ctrl-arq: one-shot group \(group.rawValue) acknowledged")
        case .arqIgnored(let reason):
            emit("ctrl-arq: ignored \(reason)")
        case .idrRequested(let request):
            emit("""
                ctrl: IDR request seq \(request.requestSeq) \
                (frame \(request.frame.rawValue), \
                coalesced \(request.coalescedCount))
                """)
        case .path(let pathEvent):
            emit("path: \(pathEvent)")
            if case .promoted(let primary, _) = pathEvent {
                do {
                    try connectMedia(
                        host: primary.tuple.remoteAddress,
                        port: primary.tuple.remotePort)
                } catch {
                    emit("path: rebind failed: \(error)")
                }
            }
        case .handshakeCookieModeChanged(let requireCookie):
            emit(requireCookie
                ? """
                    handshake: FLOOD — require-cookie mode ENGAGED \
                    (msg1 rate crossed the enter threshold; \
                    un-cookied msg1s now answered with 0x13, no Noise)
                    """
                : """
                    handshake: pressure cleared — require-cookie mode \
                    DISENGAGED (back to the token-bucket posture)
                    """)
        // A flood would print per datagram; the final stats line carries
        // these counts instead.
        case .handshakeChallenged:
            break
        case .dropped(.handshakeThrottled):
            break
        case .dropped(.handshakeCookieInvalid):
            break
        case .dropped(let reason):
            emit("drop: \(reason)")
        case .sendFailed(let what):
            emit("send-failed: \(what)")
        case .capabilitiesAgreed(let agreed):
            emit("""
                capabilities: agreed — wire minor \(agreed.wireMinor), \
                codecs \(agreed.videoCodecs), chroma \(agreed.chromaModes), \
                idle-silence \(agreed.idleSilence), \
                host-audio-routing \(agreed.hostAudioRouting), \
                max datagram \(agreed.maxDatagramBytes) B
                """)
            withConfigLock {
                _agreedPosture = AgreedMediaPosture(
                    audioQuiet: agreed.audioQuietPosture,
                    videoQuiet: agreed.videoQuietPosture,
                    chromaModes: agreed.chromaModes)
            }
            // Owed announcements are sent by the next service pass.
            if agreed.hostAudioRouting {
                routingAnnounceOwed = true
            }
            if agreed.cursorShape {
                cursorAnnounceOwed = true
            }
        case .capabilitiesFailed(let why):
            emit("""
                capabilities: NO WORKABLE INTERSECTION (\(why)) — \
                typed teardown follows
                """)
        case .capabilityUpdateAcknowledged(let accepted):
            emit("""
                capabilities: update \
                \(accepted ? "accepted" : "rejected") by the client
                """)
        case .modeTransitionSent(let mode):
            emit("""
                mode: → \(mode == .idle ? "IDLE" : "ACTIVE") \
                (0x09 on the reliable stream)
                """)
        case .teardownSent(let reason):
            emit("session: teardown 0x0A queued (\(reason))")
        case .lifecycleChanged(let state):
            switch state {
            case .frozen:
                emit("""
                    lifecycle: FROZEN — 350 ms of media-path silence; \
                    datagram video suspended, CTRL stays alive
                    """)
            case .recovery:
                emit("""
                    lifecycle: RECOVERY — evidence returned; fresh IDR \
                    at the half-stale rate, sends resume
                    """)
            case .active, .idle:
                emit("lifecycle: \(state)")
            case .closed:
                break // .sessionClosed carries the reason
            }
        case .sessionClosed(let reason):
            emit("session: CLOSED (\(reason))")
        case .inputReceived(let event, let rxMicros):
            injectInput(event, receivedAtMicroseconds: rxMicros)
        case .videoBacklogPurged(let datagrams, let bytes, let staleWireMs):
            outbox.purgeVideo(ledger: session)
            emit("""
                rate: fall purge — \(datagrams) queued video datagrams \
                (\(bytes) B, ~\(staleWireMs) ms stale at the new rate) \
                dropped, fresh IDR armed
                """)
        case .rateChanged(let bps, let reason):
            // Downshifts and pacing moves always print; the evidence
            // climb prints only on ≥5% moves, not as a 25 Hz stream.
            let significant = lastPrintedRate.map {
                Double(abs(bps - $0)) / Double($0) >= 0.05
            } ?? true
            switch reason {
            case .evidence:
                guard significant else { break }
                lastPrintedRate = bps
                emit("rate: ↑ \(bps / 1_000) kbps (evidence climb)")
            case .overuse:
                lastPrintedRate = bps
                // The evidence at fall time, for post-mortems.
                var forensics = ""
                if let f = session?.lastOveruseFallForensics {
                    func text<T>(_ value: T?) -> String {
                        value.map { "\($0)" } ?? "—"
                    }
                    let belief = f.capacityBeliefBitsPerSecond.map {
                        "\($0 / 1_000)"
                    } ?? "—"
                    let honest = f.honestAnchorBitsPerSecond.map {
                        "\($0 / 1_000) kbps"
                    } ?? "none"
                    let train = f.lastFullTrainBitsPerSecond.map {
                        let age = (f.lastFullTrainAgeNS ?? 0) / 1_000_000
                        return "\($0 / 1_000) kbps \(age) ms ago"
                    } ?? "none"
                    let loss = String(
                        format: "%.3f/%.3f",
                        f.lossFraction, f.postFecLossFraction)
                    forensics = """
                         [anchor \(f.anchorBitsPerSecond / 1_000) kbps from \
                        \(f.rateBeforeBitsPerSecond / 1_000) kbps; belief \
                        \(belief) kbps, honest \(honest), streak age \
                        \((f.streakAgeNS ?? 0) / 1_000_000) ms; streak \
                        \(text(f.streakStartMicroseconds))→\
                        \(text(f.queuingDelayMicroseconds)) µs, peak \
                        \(text(f.streakPeakMicroseconds)) µs; backlog \
                        \(f.pacerBacklogBytes) B; full-train \(train); loss \
                        \(loss) post-FEC]
                        """
                }
                emit("""
                    rate: ↓ \(bps / 1_000) kbps (queuing-delay overuse)\
                    \(forensics)
                    """)
            case .loss:
                lastPrintedRate = bps
                emit("rate: ↓ \(bps / 1_000) kbps (loss over threshold)")
            case .idrPacing(let pacing):
                lastPrintedRate = bps
                emit("rate: → \(bps / 1_000) kbps (IDR pacing \(pacing))")
            case .postFecLoss:
                lastPrintedRate = bps
                emit("rate: ↓ \(bps / 1_000) kbps (post-FEC loss — rung 3)")
            }
        case .repairEnqueued(let frame, let shards):
            emit("""
                repair: frame \(frame.rawValue) — \(shards) shard(s) \
                retransmitted (fresh seqs, videoTail)
                """)
        case .nackJudgedStale(let frame, let reason):
            emit("""
                repair: NACK frame \(frame.rawValue) judged stale \
                (\(reason))
                """)
        case .fecRegimeChanged(let regime):
            emit("""
                fec: regime → \(regime.rawValue) \
                (§5.2 \(regime == .lossy ? "lossy" : "clean") column)
                """)
        case .audioRoutingRequested(let mode):
            // Buffer only: the flip runs off-lock in service().
            emit("audio-routing: client requested \(mode) (0x18)")
            pendingAudioRouting.append(mode)
        case .audioRoutingStatusSent(let mode):
            emit("audio-routing: status \(mode) sent (0x19)")
        case .audioTrackStateSent(let state):
            emit("audio-track: \(state) announced (0x25)")
        case .videoPostureStateSent(let state):
            emit("""
                video-posture: \(state.posture) \
                keepalive \(state.keepaliveSeconds)s announced (0x26)
                """)
        case .clipboardSetReceived(let text):
            // The core's gate and echo book already ran. Buffer only: the
            // apply runs off-lock in service(). Never logs the payload.
            if clipboardApplyHandler != nil {
                emit("""
                    clipboard: 0x1A set received \
                    (\(text.utf8.count) B) — applying to the host \
                    clipboard
                    """)
                pendingClipboardApplies.append(text)
            } else {
                // Defensive: a leafless shell never declares key 10.
                emit("""
                    clipboard: 0x1A set received \
                    (\(text.utf8.count) B) — no clipboard leaf, \
                    ignored
                    """)
            }
        case .clipboardAnnounceSent(let byteCount):
            emit("clipboard: announce sent (\(byteCount) B, 0x1B)")
        case .clipboardAnnounceSuppressed(let reason):
            emit("clipboard: announce suppressed (\(reason))")
        case .cursorShapeSent(let pixelByteCount, let hidden):
            emit("""
                cursor: shape sent (0x24, \
                \(hidden ? "hidden" : "\(pixelByteCount) B"))
                """)
        case .cursorShapeSuppressed(let reason):
            // Duplicates are the steady state; only budget suppressions
            // print (both are counted).
            if reason == .overBudget {
                emit("cursor: shape suppressed (\(reason))")
            }
        case .bulkMessageReceived(let message):
            // Buffered for the off-lock shell pass; silent, since chunks
            // arrive by the hundred.
            pendingBulkMessages.append(message)
        case .clipboardImageReceived(let data, let mime):
            // Sha-verified; buffered for the off-lock apply. Never logs
            // the payload.
            if clipboardImageApplyHandler != nil {
                emit("""
                    clipboard: image received (\(data.count) B, \
                    \(mime)) — applying to the host clipboard
                    """)
                pendingClipboardImageApplies.append(data)
            } else {
                // Defensive: an imageless shell never declares key 12.
                emit("""
                    clipboard: image received (\(data.count) B) — \
                    no image leaf, ignored
                    """)
            }
        case .clipboardImageShareStarted(let byteCount):
            emit("""
                clipboard: image share started (\(byteCount) B \
                as chan-8 cargo)
                """)
        case .clipboardImageShareCompleted(let byteCount):
            emit("""
                clipboard: image share completed (\(byteCount) B, \
                sha-verified by the client)
                """)
        case .clipboardImageShareAborted(let reason, let byRemote):
            emit("""
                clipboard: image share aborted (\(reason), \
                \(byRemote ? "remote" : "local"))
                """)
        case .clipboardImageReceiveAborted(let reason, let byRemote):
            emit("""
                clipboard: image receive aborted (\(reason), \
                \(byRemote ? "remote" : "local"))
                """)
        case .clipboardImageSuppressed(let reason):
            emit("clipboard: image suppressed (\(reason))")
        case .clipboardImageRefused(let reason):
            emit("clipboard: image refused (\(reason))")
        case .clipboardImageViolation(let violation):
            emit("""
                clipboard: image lane protocol violation \
                (\(violation)) — aborted
                """)
        }
    }

    /// One input event → the injector → the session's 0x17 echo buffer.
    /// Failures are counted and loud, never fatal.
    private func injectInput(
        _ event: InputEvent, receivedAtMicroseconds rxMicros: UInt64
    ) {
        // Stamped whether or not an injector is live.
        lastInputActivityNS = SystemMonotonicClock.nowNanoseconds
        guard let injector = inputInjector else {
            if !inputNoInjectorWarned {
                inputNoInjectorWarned = true
                emit("""
                    input: event seq \(event.seq) arrived but no \
                    injection backend is active — input is OFF this run
                    """)
            }
            inputInjectFailures += 1
            return
        }
        do {
            try injector.inject(event)
        } catch {
            inputInjectFailures += 1
            emit("input: inject seq \(event.seq) failed: \(error)")
            return
        }
        let injectMicros = SystemMonotonicClock.nowMicroseconds
        inputInjected += 1
        switch event.body {
        case .pointerMotionAbsolute(let x, let y):
            lastPointerMotionInjectedAt = injectMicros
            lastAbsolutePointer = (x, y)
        case .pointerMotionRelative:
            lastPointerMotionInjectedAt = injectMicros
        case .keyKeycode, .pointerButton, .pointerAxis:
            break
        }
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
        blockedLane = nil
        noBufferBackoff = false
        guard !outbox.isEmpty else { return }
        if peerGone {
            outbox.dropAll()
            return
        }
        let outcome = outbox.flush(
            ledger: session,
            now: { SystemMonotonicClock.nowNanoseconds },
            maxBatch: Int(LYTE_NETIO_MAX_BATCH),
            sendOffPrimary: { datagram, destination in
                sendOffPrimary(datagram, to: destination)
            },
            write: { lane, batch in writeBatch(batch, lane: lane) },
            log: { emit($0) })
        switch outcome {
        case .drained:
            break
        case .wouldBlock(let lane):
            blockedLane = lane
            let blockedOutq = max(
                Int(lyte_netio_outq_bytes(socket(for: lane) ?? listenNetio)), 0)
            if lane == .latency {
                latencySocketOutqMaxBytes = max(latencySocketOutqMaxBytes, blockedOutq)
            } else {
                socketOutqMaxBytes = max(socketOutqMaxBytes, blockedOutq)
            }
        case .noBuffer:
            noBufferBackoff = true
            let now = SystemMonotonicClock.nowNanoseconds
            _ = observeKernelPressure(session, now: now)
            outbox.shedOldestStaleFreshVideo(
                ledger: session, now: now, budgetNS: session.videoQueueBudgetNS)
        case .peerGone:
            notePeerGone()
        case .failed(let why):
            throw HostError("session send failed: \(why)")
        }
    }

    private func socket(for lane: SocketLane) -> OpaquePointer? {
        lane == .latency ? latencyNetio : videoNetio
    }

    private func writeResult(_ rc: Int32) -> SocketWriteResult {
        switch rc {
        case 0: .wouldBlock
        case LYTE_NETIO_NO_BUFFER: .noBuffer
        case LYTE_NETIO_PEER_GONE: .peerGone
        case LYTE_NETIO_TRANSIENT: .transient
        case let accepted where accepted > 0: .accepted(Int(accepted))
        default: .failed(errString(sendError))
        }
    }

    /// One datagram addressed explicitly from the listening socket (path
    /// challenges, anything before the media sockets connect).
    private func sendOffPrimary(
        _ datagram: VideoChannelDatagram, to destination: FourTuple
    ) -> SocketWriteResult {
        let rc = datagram.bytes.withUnsafeBufferPointer { buf -> Int32 in
            var pkt = lyte_netio_pkt(
                data: buf.baseAddress, len: buf.count,
                tos: WireTos.byte(for: datagram.pacerClass))
            return lyte_netio_send_to(
                listenNetio, &pkt,
                destination.remoteAddress, destination.remotePort,
                &sendError, sendError.count)
        }
        return writeResult(rc)
    }

    /// One lane's batch staged into `scratch`, each datagram with its
    /// class's TOS.
    private func writeBatch(
        _ batch: ArraySlice<VideoChannelDatagram>, lane: SocketLane
    ) -> SocketWriteResult {
        guard let socket = socket(for: lane) else {
            return sendOffPrimary(
                batch[batch.startIndex], to: session.validator.primary.tuple)
        }
        sendPackets.removeAll(keepingCapacity: true)
        var offset = 0
        for d in batch {
            precondition(offset + d.bytes.count <= Self.scratchCapacity)
            d.bytes.withUnsafeBufferPointer { src in
                scratch.advanced(by: offset)
                    .update(from: src.baseAddress!, count: src.count)
            }
            sendPackets.append(lyte_netio_pkt(
                data: scratch.advanced(by: offset),
                len: d.bytes.count,
                tos: WireTos.byte(for: d.pacerClass)))
            offset += d.bytes.count
        }
        let rc = sendPackets.withUnsafeBufferPointer { buf in
            lyte_netio_send_batch(
                socket, buf.baseAddress, Int32(buf.count), nil,
                &sendError, sendError.count)
        }
        return writeResult(rc)
    }
}
