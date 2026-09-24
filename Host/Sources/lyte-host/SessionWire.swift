// SessionWire: lyte-host's Lyte-UDP session shell over HostWire.Session
// (which owns the Noise responder handshake, sealing, beacons, the
// conn-id TLV, path validation, the pacer, and the estimator). This file
// is syscalls, threads, and scheduling: CNetIO sockets, recvmmsg into
// Session.receive with real source tuples, Session's paced datagrams
// through SocketOutbox into sendmmsg with per-class TOS (HostCore's
// WireTos: control/audio/repairs 0xC0, video 0xA0), and the per-poll
// snapshot the capture leg reads.
//
// Sockets: one listening socket bound to the session port and never
// connected — it hears message 1 from any client and a migrated client's
// new path, and carries every explicitly addressed datagram. When a
// handshake completes, a video socket (SO_PRIORITY 4) and a latency
// socket (control and audio, 6) join the port via SO_REUSEPORT and
// connect to the authenticated client; a path promotion re-connects them.
//
// Threads: the capture thread (DirectEyeLeg) calls sendFrame and
// takeLegSnapshot; the audio thread only publishes into a narrow mailbox
// (packets and track states) and tries the session lock without waiting;
// the janitor runs service() every 10 ms for shell work (clipboard, bulk
// files, audio routing, pairing) off the lock; the SCHED_RR sender thread
// waits in ppoll on its wake eventfd, the sockets, and the session's next
// timer, then services and flushes. One NSLock guards the Session and the
// outbox, so sequence allocation, sealing, pacer insertion, and socket
// flush keep one order; console lines are formatted under it and printed
// after it is released. The agreed capability flags the audio and capture
// threads poll live under a separate narrow config lock.

import LyteIO
import LyteCore
import CNetIO
import Foundation
import HostCore
import HostSession
import HostWire
import LyteWire

/// Best-effort realtime elevation for a latency-owning thread. The 1 ms
/// pacing drain and the 5 ms audio cadence rode default CFS against
/// NVENC submission and the compositor; SCHED_RR buys their tail
/// behavior on a LOADED box (the idle reference pair never showed the
/// cost — `maxQueueDelayNS` books are the evidence surface). Degrades
/// gracefully in order: SCHED_RR → per-thread nice −10 (Linux tasks
/// carry their own nice) → accept and say so once. Unprivileged runs
/// need an rtprio rlimit (see Host/README) — the host must run fine
/// without one.
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

final class SessionWire {
    enum ClientAwaitOutcome: Equatable {
        case established
        case terminationRequested
    }

    /// The listening socket: bound to the session port and never
    /// connected, so it receives every tuple no connected socket claims —
    /// message 1 from any client, and a migrated client's new path. It
    /// also carries every datagram addressed explicitly (path challenges,
    /// pre-establishment replies).
    private let listenNetio: OpaquePointer
    /// The media sockets, connected to the client's primary tuple once it
    /// is known (SO_REUSEPORT members of the listening port, so the wire
    /// 4-tuple is one): video at SO_PRIORITY 4, control and audio at 6,
    /// each with its own kernel send buffer. Nil until then.
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
    private var session: Session!
    /// HS-15: serializes Session/outbox access between the video
    /// capture loop thread and the audio capture loop thread (see the
    /// threading note in the header). Held across service passes,
    /// released across sleeps.
    private let lock = NSLock()
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
    private var outbox = SocketOutbox()

    /// Scratch for one sendmmsg batch: pointers must stay valid for the
    /// duration of the call, so datagrams are staged here.
    private let scratch: UnsafeMutablePointer<UInt8>
    private static let scratchCapacity = Int(LYTE_NETIO_MAX_BATCH) * 1_200
    /// One batch's packet descriptors, reused across flushes.
    private var sendPackets: [lyte_netio_pkt] = []
    private var sendError = [CChar](repeating: 0, count: 256)

    /// One flat region for recv_batch slots (stable pointers, one slot
    /// stride per batch position).
    private let recvScratch: UnsafeMutablePointer<UInt8>
    private static let recvSlotCapacity = 2_048
    /// Reused by every receive drain. All receive paths hold `lock`, so
    /// this vector has one owner and its pointers remain fixed on the
    /// lifetime-stable `recvScratch` allocation across recvmmsg calls.
    private var recvSlots: [lyte_netio_slot]
    private var recvError = [CChar](repeating: 0, count: 256)

    /// T2-13: the six surfaces below are published by main AFTER the
    /// drain thread is live (injector and shells exist only once the
    /// backend/consent policy has run). Every access snapshots under
    /// this dedicated lock — never the session `lock`, so the callers'
    /// off-lock discipline is preserved, and the lock is never held
    /// across a callback (the accessor releases before returning).
    private let configLock = NSLock()
    private func withConfigLock<T>(_ body: () -> T) -> T {
        configLock.lock()
        defer { configLock.unlock() }
        return body()
    }

    /// HS-13: the injection sink for client input events. Nil = input
    /// disabled (counted loud, never fatal). Set by main after the
    /// backend policy runs.
    private var _inputInjector: InputInjector?
    var inputInjector: InputInjector? {
        get { withConfigLock { _inputInjector } }
        set { withConfigLock { _inputInjector = newValue } }
    }

    /// HS-18: the shell's audio-leaf flipper — stop the leaf, bring it
    /// back in the requested routing, return whether it stuck. Nil =
    /// no flip surface this run (requests answered with the standing
    /// posture). Set by main once audio is up. Called OFF the session
    /// lock: a flip is a PipeWire connect (milliseconds, and it must
    /// not stall the 5 ms audio thread against the lock).
    private var _audioRoutingHandler: ((HostAudioRoutingMode) -> Bool)?
    var audioRoutingHandler: ((HostAudioRoutingMode) -> Bool)? {
        get { withConfigLock { _audioRoutingHandler } }
        set { withConfigLock { _audioRoutingHandler = newValue } }
    }

    /// HS-19: the shell's clipboard-apply sink (the leaf's
    /// SetSelection). Nil = no leaf this run — the session core never
    /// surfaces 0x1A then anyway (key 10 undeclared), so the arm is
    /// defensive. Called OFF the session lock: SetSelection is a
    /// blocking D-Bus round-trip.
    private var _clipboardApplyHandler: ((String) -> Void)?
    var clipboardApplyHandler: ((String) -> Void)? {
        get { withConfigLock { _clipboardApplyHandler } }
        set { withConfigLock { _clipboardApplyHandler = newValue } }
    }
    /// P-1: the image half of the same sink (the leaf's SetSelection
    /// with the PNG flavor). Same off-lock discipline.
    private var _clipboardImageApplyHandler: (([UInt8]) -> Void)?
    var clipboardImageApplyHandler: (([UInt8]) -> Void)? {
        get { withConfigLock { _clipboardImageApplyHandler } }
        set { withConfigLock { _clipboardImageApplyHandler = newValue } }
    }
    /// HS-19: the leaf's off-lock service pass (D-Bus signal drain +
    /// fd transfer pumps), run once per `service()` like the routing
    /// work — never under the lock, never on the audio thread.
    private var _clipboardServiceHook: (() -> Void)?
    var clipboardServiceHook: (() -> Void)? {
        get { withConfigLock { _clipboardServiceHook } }
        set { withConfigLock { _clipboardServiceHook = newValue } }
    }
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
    private var _bulkShell: BulkReceiveShell?
    var bulkShell: BulkReceiveShell? {
        get { withConfigLock { _bulkShell } }
        set { withConfigLock { _bulkShell = newValue } }
    }
    /// Chan-8 messages delivered by the session (under the lock),
    /// awaiting the shell's disk work outside it (drained by
    /// `service()`).
    private var pendingBulkMessages: [BulkMessage] = []
    /// The posture the audio leaf is actually running (main seeds it;
    /// applied flips move it). Mutated under `lock`.
    private(set) var currentAudioRouting: HostAudioRoutingMode = .hostAudible
    /// Pairing outcomes delivered under the lock, executed (keystore
    /// write, console lines) outside it by `service()`.
    private var pendingPairingEvents: [PairingResponderService.Event] = []
    /// 0x18 requests delivered by the session, awaiting the shell's
    /// flip outside the lock (drained by `service()`).
    private var pendingAudioRouting: [HostAudioRoutingMode] = []
    /// Set at capability agreement when hostAudioRouting survived the
    /// intersection: the client is owed one starting-posture 0x19.
    private var routingAnnounceOwed = false
    /// receive→inject per event, µs (the HS-13 p99 < 2 ms gate edge).
    private(set) var inputLatency = Histogram<UInt64>()
    private(set) var inputInjected = 0
    private(set) var inputInjectFailures = 0
    private var inputNoInjectorWarned = false
    /// Monotonic µs of the most recent successful injection (0 = never).
    /// Written under `lock` on the service thread; the capture tick's
    /// starvation tripwire reads it through the locked accessor below.
    private var lastInputInjectedAt: UInt64 = 0
    /// Pointer-motion is the only input kind that structurally owes an
    /// EMBEDDED-cursor damage frame. Keys/buttons/scroll may target a
    /// surface that draws nothing, so treating any input as a capture
    /// liveness witness manufactures false starvation on a static desk.
    private var pointerMotionInjected = 0
    private var lastPointerMotionInjectedAt: UInt64 = 0
    /// E3: the last absolute pointer position injected (monitor
    /// device pixels) — the cursor watcher's hotspot anchor (hotspot
    /// = injected position − cursor plane CRTC position; i915 exposes
    /// no HOTSPOT_X/Y props to ask directly).
    private var lastAbsolutePointer: (x: Double, y: Double)?
    /// E3: the eye's latest cursor shape, standing — re-offered when
    /// capabilities agree so a client that connects mid-run wears the
    /// current cursor, not a default.
    private var standingCursorShape: CursorShape?
    /// E3: capabilities just agreed with key 13 — the client is owed
    /// the standing shape. Buffered; the next service pass sends it
    /// off the agreement stack (the routingAnnounceOwed pattern).
    private var cursorAnnounceOwed = false

    private(set) var framesSent = 0
    /// Most recent successfully admitted frame, for the synchronous
    /// encoder callback to attach QP/IDR-cause fields to its flight.
    private var lastFrameForTelemetry: FrameNumber?
    /// What the audio capture thread publishes, in capture order: 5 ms
    /// packets and the tripwire's track-state announcements.
    private enum AudioMailboxEntry {
        case packet(bytes: [UInt8], captureMicros: UInt64, offeredAtNS: UInt64)
        case trackState(AudioTrackState.State)
    }
    /// The audio capture thread owns only this narrow publication lock.
    /// The Session owner swaps the whole FIFO out before doing any
    /// framing/sealing work, so capture never waits for video.
    private let audioMailboxLock = NSLock()
    private var audioMailbox: [AudioMailboxEntry] = []
    private static let audioMailboxCapacity = 64
    private(set) var audioMailboxMaxDepth = 0
    private(set) var audioMailboxOverflows = 0
    private(set) var audioMailboxMaxDwellNS: UInt64 = 0
    private(set) var audioMailboxDwell = Histogram<UInt64>()
    /// Root-cause telemetry for the split video path. Preparation includes
    /// Annex-B classification + RS-FEC and is now deliberately off-lock;
    /// commit includes seq allocation, Noise sealing, and pacer insertion.
    private(set) var videoPrepareMaxNS: UInt64 = 0
    private(set) var videoCommitLockWaitMaxNS: UInt64 = 0
    private(set) var videoCommitLockHoldMaxNS: UInt64 = 0
    private(set) var serviceOnceMaxNS: UInt64 = 0
    private(set) var receiveAllMaxNS: UInt64 = 0
    /// HS-15 audio-thread counters (mutated under `lock`, except mailbox
    /// publication counters above which use `audioMailboxLock`).
    private(set) var audioPacketsSent = 0
    private(set) var audioSendFailures = 0
    private(set) var audioPacketsDroppedPreSession = 0
    /// The socket outbox's own books (sends, would-blocks, ENOBUFS,
    /// shedding, audio outbox delay). Read after shutdown.
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
    private(set) var lastSendError: String?
    private(set) var sendErrors = 0
    /// The agreed capability flags the capture and audio threads poll,
    /// published once at agreement (the agreement never changes after
    /// it lands). Read and written under `configLock`, never the session
    /// lock, so the 5 ms audio path and the 1 ms capture poll never wait
    /// behind a video commit.
    private struct AgreedMediaPosture {
        var audioQuiet = false
        var videoQuiet = false
        var chromaModes: [UInt64]?
    }
    private var _agreedPosture = AgreedMediaPosture()
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
    /// The starvation tripwire's input-recency witness (0 = no input
    /// injected yet this session).
    var lastInputInjectedAtMicros: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastInputInjectedAt
    }
    /// Atomic starvation witness: successful pointer-motion count and
    /// latest injection time from one lock acquisition.
    var pointerMotionWitness: (count: Int, lastAtMicros: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (pointerMotionInjected, lastPointerMotionInjectedAt)
    }
    /// ECONNREFUSED evidence (LYTE_NETIO_PEER_GONE): the client's socket
    /// is closed — session-ending, not an I/O failure (HS-11).
    private(set) var peerGone = false

    /// The sender thread's wake (an eventfd): capture, audio, and the
    /// janitor signal it when bytes were enqueued; it also wakes on socket
    /// readability and at the session's next timer (drainLoop).
    private let wakeFd: Int32
    /// Guards the sender thread's lifecycle flags below. Lock order:
    /// `lock` → `drainCondition` (takeLegSnapshot), never the reverse.
    private let drainCondition = NSCondition()
    private var drainStop = false
    private var drainExited = false
    /// The last flush ended on a full socket buffer (the lane to wait on
    /// for POLLOUT) or on ENOBUFS (a short back-off). Under `lock`.
    private var blockedLane: SocketLane?
    private var noBufferBackoff = false
    /// A drain-thread send failure (not peer-gone — that has its own
    /// flag): recorded loud and session-ending, mirroring what a thrown
    /// sendFrame used to do to the capture loop.
    private var drainFailed = false

    /// Everything the capture loop consults per poll, taken with one
    /// session-lock acquisition (the agreed flags and the input stamp come
    /// from the narrow config lock). Taking it consumes the pending IDR
    /// demand and rate directive.
    struct LegSnapshot {
        /// Nothing more can usefully happen: the peer's socket is closed,
        /// the lifecycle reached `closed` (teardown or the 30 s liveness
        /// timeout), or the drain thread failed. The capture loop quits.
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
    /// P-1: the image lane's books (share/apply/refuse verdicts).
    var clipboardImageCounters: ClipboardImageChannelCounters {
        session.clipboardImageCounters
    }
    /// V-4: the agreed chroma list (nil until the client's declaration
    /// lands — or forever, for a grandfathered pre-W7 peer). The Sink
    /// branches the encoder posture on it at open.
    var agreedChromaModes: [UInt64]? {
        withConfigLock { _agreedPosture.chromaModes }
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
    var kernelPressureState: KernelPressureState {
        kernelPressureDecision?.state ?? .calm
    }
    var kernelVideoServiceDebtNS: UInt64 {
        kernelPressureDecision?.totalVideoServiceDebtNS ?? 0
    }
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
    /// Exact bytes that entered through the borrowed callback seam. The
    /// former implementation allocated and copied this many bytes here.
    private(set) var borrowedFrameBytesIngested: UInt64 = 0
    /// HS-32: the derived freeze budget in force (ms), for the books.
    var repairBudgetMS: UInt64 { session.repairFreezeBudgetNS / 1_000_000 }

    /// - Parameters:
    ///   - listenPort: bind here and await a connecting client (nil =
    ///     kernel-assigned port, requires `peer`).
    ///   - peer: optional pre-connected far end; Noise message 1 must
    ///     still arrive from it before the session is established.
    init(
        listenPort: UInt16?,
        peer: (host: String, port: UInt16)?,
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
        // A-23: every validation that can refuse lives ABOVE the first
        // allocation. A throw after the drain thread holds `self` would
        // leave that thread on a deinit'd object — nothing may throw
        // past thread.start() below.
        self.rateBitsPerSecond = rateBitsPerSecond
        self.capabilities = capabilities
        self.allowedClientStatics = allowedClientStatics
        self.handshakeGateConfig = handshakeGateConfig
        self.pairing = pairing
        self.onPairingEvent = onPairingEvent

        self.requiredPeer = peer
        var err = [CChar](repeating: 0, count: 256)
        guard let n = lyte_netio_new("0.0.0.0", listenPort ?? 0,
                                     &err, err.count) else {
            throw HostError("session socket open failed: \(errString(err))")
        }
        listenNetio = n
        guard lyte_netio_set_priority(n, 6) == 0 else {
            lyte_netio_free(n)
            throw HostError("listening socket SO_PRIORITY failed")
        }
        wakeFd = lyte_netio_wake_new()
        guard wakeFd >= 0 else {
            lyte_netio_free(n)
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

        // The sender thread comes up parked (no work until the first
        // ingest signals it); it holds `self` for its lifetime, so the
        // shell must stop it (shutdown does) before the process lets
        // the SessionWire go. SessionWire is cross-thread by design
        // (capture, audio, janitor, sender threads) with `lock` as the
        // discipline — the unsafe capture states that fact to the
        // compiler, exactly like the audio thread's Unmanaged
        // trampoline does implicitly.
        nonisolated(unsafe) let shared = self
        let thread = Thread {
            // The drain owns 1 ms-quantum pacing precision via usleep;
            // audio (12) outranks it — its cadence bound is tighter.
            elevateCurrentThread("wire-drain", rtPriority: 10)
            shared.drainLoop()
        }
        thread.name = "lyte-wire-drain"
        thread.start()
    }

    deinit {
        scratch.deallocate()
        recvScratch.deallocate()
        if let latencyNetio {
            lyte_netio_free(latencyNetio)
        }
        if let videoNetio {
            lyte_netio_free(videoNetio)
        }
        lyte_netio_free(listenNetio)
        close(wakeFd)
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

    /// Points the media sockets at the client: opens them on first use
    /// (bound to the listening port) or re-connects them (a path
    /// promotion).
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

    /// Noise mode: block until a client completes message 1 (the session
    /// establishes inside `receive`), for up to `timeoutSeconds` (nil = as
    /// long as it takes, the listening service's posture). Prints the
    /// static public key the client must hold. Call before capture opens
    /// so no video is encoded for nobody.
    ///
    /// Until a handshake completes the host is bound to no client: only
    /// plausible handshake initiations reach the session, from any tuple
    /// (a wire-out host accepts only its peer), and the one that
    /// authenticates names the client's path — the media sockets connect
    /// there. A spoofed, unpaired, or abandoned message 1 cannot lock out
    /// the next client.
    func awaitClient(
        hostStatic: NoiseKeyPair,
        timeoutSeconds: Double?,
        stopRequested: () -> Bool = { false }
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
            var established = false
            lock.lock()
            do {
                let handle: ([UInt8], FourTuple) -> Void = { [weak self]
                    datagram, tuple in
                    guard let self else { return }
                    guard self.session?.phase != .established else {
                        self.receiveEstablished(datagram, from: tuple)
                        return
                    }
                    self.awaitPrimaryDatagrams += 1
                    // Shape check, not trust: the gate still authenticates.
                    // A relaunched host also hears the previous session's
                    // sealed feedback from the client's old port; only an
                    // initiation is worth a session's attention.
                    let plausible = Session.looksLikeHandshakeInitiation(datagram)
                        && self.admitsPeer(tuple)
                    let payloadType: UInt8? = (try? Envelope.decode(
                        datagram[...]))?.1.first
                    self.traceHandshake("primaryDatagram", fields: [
                        "ordinal": String(self.awaitPrimaryDatagrams),
                        "bytes": String(datagram.count),
                        "remoteAddress": tuple.remoteAddress,
                        "remotePort": String(tuple.remotePort),
                        "shapeAccepted": String(plausible),
                        "payloadType": payloadType.map(String.init) ?? "",
                    ])
                    guard plausible else { return }
                    if self.session == nil {
                        self.makeSession(
                            crypto: .noise(hostStatic: hostStatic),
                            clientTuple: tuple
                        )
                    }
                    for event in self.session.receive(
                        datagram, from: tuple,
                        now: SystemMonotonicClock.nowNanoseconds,
                        hostMicroseconds: SystemMonotonicClock.nowMicroseconds
                    ) {
                        self.execute(event)
                        if case .handshakeCompleted = event { established = true }
                    }
                }
                try receiveFromAll(handle)
                // A pre-establishment pump is what lets HS-21's 0x13
                // RetryChallenge (enqueued into the pacer by
                // Session.receive under flood) actually leave the box:
                // msg 2 escapes later via the streaming service loop's
                // pump, but a challenge answers a flood that never
                // establishes, so awaitClient must drain the pacer here.
                if let session {
                    pumpForSocketState(session)
                }
                try flushOutbox() // challenges, message 2, session-start beacon
            } catch {
                lock.unlock()
                flushLogLines()
                throw error
            }
            let done = established && session?.phase == .established
            lock.unlock()
            flushLogLines()
            if done {
                // The sender thread owns the established session's pacing
                // from here.
                signalDrain()
                return .established
            }
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

    /// The session port (the kernel's pick when bound to port 0).
    var localPort: UInt16 { lyte_netio_local_port(listenNetio) }

    /// wire-out mode admits only its configured peer.
    private func admitsPeer(_ tuple: FourTuple) -> Bool {
        guard let requiredPeer else { return true }
        return tuple.remoteAddress == requiredPeer.host
            && tuple.remotePort == requiredPeer.port
    }

    /// One receive batch from every socket that can hold inbound
    /// datagrams.
    private func receiveFromAll(
        _ handle: ([UInt8], FourTuple) -> Void
    ) throws {
        try receiveAll(from: listenNetio, handle)
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
        // A recvmmsg burst can contain many feedback/control packets.
        // Do not let parsing the whole burst consume an audio period.
        drainAudioMailboxLocked()
    }

    /// HS-20: arm the encoder-VBV policy once the encoder's opening
    /// rate-control posture is known (main calls this right after the
    /// session comes up; the policy's baseline mirrors the native
    /// seat's opening posture).
    func armEncoderVbv(_ config: EncoderVbvConfig) {
        lock.lock()
        defer { lock.unlock() }
        vbvPolicy = EncoderVbvPolicy(config: config)
    }

    /// Requires `lock`. The estimator's LIVE frameByteCeiling into the
    /// VBV policy; a non-nil directive must reach the encoder before the
    /// next frame is sent.
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

    /// HS-11: the orderly close — SessionTeardown 0x0A on the reliable
    /// stream, then a bounded linger so the segment can be delivered and
    /// acknowledged before the process exits (the graceful-exit half of
    /// the ECONNREFUSED fix: the client learns the session ended instead
    /// of inferring it from silence).
    func shutdown(reason: SessionTeardownReason, lingerSeconds: Double = 0.5) {
        // main stops the audio source before teardown; flush its final
        // published quantum while the established session still exists.
        lock.lock()
        drainAudioMailboxLocked()
        lock.unlock()
        // The sender thread goes first: teardown owns the send path
        // from here (and the thread holds `self` — this is also its
        // lifetime end).
        stopDrain()
        runPendingPairingEvents()
        lock.lock()
        guard let session, session.phase == .established,
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

    /// One encoded Annex-B packet → sealed shards on the wire. Runs on
    /// the capture thread: validation and RS-FEC happen off the session
    /// lock, sealing and pacer insertion under it; the first quantum
    /// leaves on this stack and the sender thread paces out the rest.
    func sendFrame(
        data: UnsafePointer<UInt8>, size: Int, isKeyframe: Bool,
        captureMicros: UInt64
    ) throws {
        let frame = UnsafeBufferPointer(start: data, count: size)
        borrowedFrameBytesIngested &+= UInt64(size)

        // Snapshot admission under the Session lock, then release it for
        // Annex-B validation + RS-FEC. That pure work has produced
        // 90–180 ms scheduling tails under 1080p60 motion; keeping the lock
        // there prevented the sender from servicing 5 ms audio despite its
        // dedicated wake and every-four-seal checkpoints.
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

        // Ordered commit: seq allocation, Noise sealing, pacer mutation,
        // and socket flush remain serialized with audio/control/feedback.
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
        framesSent += 1
        // First quantum leaves on this stack (the bucket is credited
        // while idle, so this is one batch + one sendmmsg, tens of µs);
        // the sender thread paces out the rest while the capture loop
        // returns to the compositor.
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

    /// The capture leg's pre-encode admission inputs (VideoAdmissionGate):
    /// the queued video's wire time and the budget in force, from one
    /// locked Session snapshot so a regime or rate move cannot mix eras.
    var videoAdmissionPosture: (backlogWireTimeNS: UInt64, budgetNS: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return (0, UInt64.max) }
        let pressure = observeKernelPressure(
            session, now: SystemMonotonicClock.nowNanoseconds)
        return (pressure.totalVideoServiceDebtNS, pressure.admissionBudgetNS)
    }

    /// HS-15: one encoded 5 ms Opus packet from the AUDIO capture
    /// thread. Audio deliberately flows in IDLE and FROZEN (the 5 ms path
    /// probe — Session's ruling; only `closed` suppresses).
    func sendAudioPacket(_ packet: [UInt8], captureMicros: UInt64) {
        publishAudio(.packet(
            bytes: packet, captureMicros: captureMicros,
            offeredAtNS: SystemMonotonicClock.nowNanoseconds))
    }

    /// Tripwire: one 0x25 track-state announcement onto the reliable
    /// stream (a no-op at the session layer unless key 15 was agreed).
    /// It rides the audio mailbox, so it stays ordered with the packets
    /// around it and the audio thread never waits for the session lock.
    func sendAudioTrackState(_ state: AudioTrackState.State) {
        publishAudio(.trackState(state))
    }

    /// The audio thread's only entry into the session. Publication takes
    /// the narrow mailbox lock; it never waits behind video
    /// packetize/FEC/seal or broad session service. The elevated sender
    /// (or a cooperative video-ingest checkpoint) performs ordered
    /// framing, Noise sealing, pacing, and send.
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

        // The capture callback is already scheduled at the 5 ms cadence.
        // Use that wake directly whenever the Session owner is between
        // bounded critical sections; this avoids making audio depend solely
        // on a default-CFS sender thread being scheduled after signal().
        // try() never blocks the capture loop, and the lines this pass
        // formats are printed later by the janitor or the drain thread —
        // the audio thread never does console I/O.
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

    /// Requires the broad Session lock. The mailbox lock is held only
    /// long enough to swap the FIFO; framing/sealing/syscalls happen
    /// after audio capture is free to publish its next quantum.
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
                    audioPacketsSent += 1
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

    /// The between-frames service hook (idle-floor tick cadence):
    /// inbound datagrams, session timers (beacons), pacer leftovers,
    /// and the HS-18 routing work that must run OFF the lock.
    func service() {
        lock.lock()
        guard session != nil else {
            lock.unlock()
            return
        }
        serviceAndFlushLocked()
        // Anything this pass enqueued but could not emit inside one
        // quantum (repair retransmits from a NACK, a burst of ARQ
        // segments) belongs to the sender thread, not the next tick.
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

        // The starting-posture 0x19 (capabilities just agreed) and any
        // client flips — both re-take the lock per send, neither holds
        // it across the PipeWire work.
        if announce {
            noteAudioRoutingApplied(standing)
        }
        // E3: the agreed-time re-offer — the client wears the eye's
        // standing shape from its first frame (re-takes the lock, the
        // noteAudioRoutingApplied discipline).
        if cursorOwed, let shape = standingCursor {
            noteCursorShape(shape)
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

    /// E3: the eye's report that the hardware cursor plane changed —
    /// a content-cropped shape or the hidden state. Remembered as the
    /// standing shape (re-offered when capabilities agree), then the
    /// 0x24 (or the suppression verdict) happens inside the core; a
    /// no-key-13 session stays silent (the rule-3 gate).
    func noteCursorShape(_ shape: CursorShape) {
        withEstablishedSession(before: { standingCursorShape = shape }) {
            $0.noteCursorShapeChanged(shape, now: $1, hostMicroseconds: $2)
        }
    }

    /// E3: the last absolute pointer position injected (monitor
    /// device pixels) and when — the cursor watcher derives the
    /// hotspot from it once the plane settles under the pointer.
    func lastAbsolutePointerInjection(
    ) -> (x: Double, y: Double, atMicros: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = lastAbsolutePointer else { return nil }
        return (p.x, p.y, lastPointerMotionInjectedAt)
    }

    /// HS-19: the leaf's report that the OS clipboard changed —
    /// genuine host copies AND the echoes of our own applies; the
    /// session's sync book tells them apart. The 0x1B (or the
    /// suppression verdict) happens inside the core; a no-key-10
    /// session stays silent (the rule-3 gate).
    func noteHostClipboardChanged(_ text: String) {
        withEstablishedSession {
            $0.noteHostClipboardChanged(text, now: $1, hostMicroseconds: $2)
        }
    }

    /// P-1: the leaf's report that the OS clipboard now holds an
    /// image (whole PNG bytes) — genuine host copies AND the echoes
    /// of our own applies; the session's shared book tells them
    /// apart. Cargo (or the suppression verdict) happens inside the
    /// core; an ungated session stays silent (the keys-10∧12 gate).
    func noteHostClipboardImageChanged(_ data: [UInt8]) {
        withEstablishedSession {
            $0.noteHostClipboardImageChanged(data, now: $1, hostMicroseconds: $2)
        }
    }

    /// HS-18: main's seed — what posture the audio leaf came up in.
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

    /// The applied-posture 0x19 onto the reliable stream (a no-op at
    /// the session layer unless hostAudioRouting was negotiated).
    func noteAudioRoutingApplied(_ mode: HostAudioRoutingMode) {
        withEstablishedSession {
            $0.noteAudioRoutingApplied(mode, now: $1, hostMicroseconds: $2)
        }
    }

    /// Tripwire: whether THIS session agreed key 15 (audioQuietPosture).
    /// The audio thread asks per packet before ever gating — a legacy
    /// client keeps the always-on contract, silence included.
    func audioQuietPostureAgreed() -> Bool {
        withConfigLock { _agreedPosture.audioQuiet }
    }

    /// Video posture: one 0x26 announcement onto the reliable stream
    /// (a no-op at the session layer unless key 16 was agreed).
    func sendVideoPostureState(quiet: Bool, keepaliveSeconds: UInt8) {
        let state = VideoPostureState(
            posture: quiet ? .quiet : .active,
            keepaliveSeconds: keepaliveSeconds)
        withEstablishedSession {
            $0.noteVideoPostureState(state, now: $1, hostMicroseconds: $2)
        }
    }

    /// The wake-on-input half of the video posture: the drain thread
    /// stamps every injected input event; the video leg reads the
    /// stamp each poll (LegSnapshot) — an input packet IS the wake, zero
    /// added latency. Monotonic ns under configLock.
    private var _lastInputActivityNS: UInt64 = 0
    private var lastInputActivityNS: UInt64 {
        get { withConfigLock { _lastInputActivityNS } }
        set { withConfigLock { _lastInputActivityNS = newValue } }
    }

    /// One session note from a shell thread, under `lock`: skipped
    /// unless the session is established; its events execute, then one
    /// service pass and flush so the note's sends leave now rather than
    /// on the next tick. `before` runs under the lock either way.
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
        lastSendError = String(describing: error)
        if sendErrors <= 3 {
            emit("session: send path error (\(sendErrors)): \(error)")
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
        emit("""
            session: client unreachable (ICMP port closed — it exited) \
            — closing cleanly
            """)
    }

    /// Wakes the sender thread: bytes were enqueued (or leftovers were
    /// observed) and the pacer needs pumping at its own wake instants.
    private func signalDrain() {
        lyte_netio_wake_signal(wakeFd)
    }

    /// Stops the sender thread and waits for it to exit (it holds
    /// `self` and shares the send scratch, so teardown must not race
    /// it). Idempotent; the thread exits within its current pass.
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
        /// Sockets whose readability ends the wait, with POLLOUT on the
        /// one whose buffer was full.
        var sockets: [(fd: Int32, pollOut: Bool)] = []
    }

    /// The sender thread's whole life: one service pass (receive, timers,
    /// pacer, flush), then wait — on its wake eventfd, the sockets'
    /// readability (an inbound datagram, e.g. input, is read at once),
    /// POLLOUT on a full socket, or the session's next timer — and again.
    /// A send failure is recorded and ends the session (the capture loop
    /// reads it); the thread itself stays stoppable.
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
                lock.lock()
                lastSendError = String(describing: error)
                lock.unlock()
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

    /// Callers must NOT hold `lock`: the pass takes it for the service
    /// work and the wait happens outside it, so the audio thread's 5 ms
    /// sends interleave with a long video drain (the structural half of
    /// the 5 ms ± 2 ms bound; the pacer's class order is the other half).
    private func drainPass() throws -> DrainWait {
        lock.lock()
        guard let session, session.phase == .established, !peerGone else {
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
        let wake = session.nextWake(now: now)
        let blocked = outbox.isEmpty ? nil : blockedLane
        let backoff = !outbox.isEmpty && noBufferBackoff
        var sockets: [(fd: Int32, pollOut: Bool)] = [
            (lyte_netio_fd(listenNetio), false)
        ]
        if let videoNetio {
            sockets.append((lyte_netio_fd(videoNetio), blocked == .video))
        }
        if let latencyNetio {
            sockets.append((lyte_netio_fd(latencyNetio), blocked == .latency))
        }
        lock.unlock()
        flushLogLines()

        return DrainWait(
            timeoutNS: SenderWait.timeoutNS(
                nowNS: now, nextWakeNS: wake, noBufferBackoff: backoff),
            sockets: sockets)
    }

    private func block(until wait: DrainWait) {
        var fds: [Int32] = [wakeFd]
        var events: [Int16] = [Int16(POLLIN)]
        for socket in wait.sockets {
            fds.append(socket.fd)
            events.append(Int16(socket.pollOut ? POLLIN | POLLOUT : POLLIN))
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
        // Always service the scheduling island before lower-frequency
        // receive/timer/stat work under this lock.
        drainAudioMailboxLocked()
        try receiveFromAll { [weak self] datagram, tuple in
            self?.receiveEstablished(datagram, from: tuple)
        }
        for event in session.advance(
            now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
        ) {
            execute(event)
        }
        // A nonempty outbox means the previous socket write hit EAGAIN.
        // Releasing another VIDEO quantum before retrying would turn kernel
        // backpressure into an unbounded userspace queue. The helper admits
        // only latency classes while blocked so audio can cross channels
        // ahead of the sealed video without adding more video pressure.
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
        // turn a receive into an unbounded hold of the session lock; the
        // sender takes another pass after releasing it.
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

    /// Lines the event log formats UNDER `lock`, printed only after it
    /// releases. stdout is line-buffered to a pipe/tty: a stalled
    /// reader (a stopped terminal, a wedged ssh) would otherwise block
    /// the write INSIDE the lock and freeze audio, pacing, and capture
    /// behind console I/O — priority inversion through the one lock
    /// everything shares. Guarded by `lock`; drained by
    /// `flushLogLines()` at the seams that release it (the service
    /// tick and the drain loop — rare out-of-band events ride until
    /// the next tick, order preserved).
    private var pendingLogLines: [String] = []

    private func emit(_ line: String) { pendingLogLines.append(line) }

    /// Print whatever the locked sections accumulated. Callers must
    /// NOT hold `lock`.
    private func flushLogLines() {
        lock.lock()
        let lines = pendingLogLines
        pendingLogLines.removeAll(keepingCapacity: true)
        lock.unlock()
        for line in lines { print(line) }
    }

    /// Executes one session event: prints go through `emit`, side
    /// effects (input injection, path rebinds, pairing, outbox purges,
    /// buffered shell work) run here under `lock`.
    private func execute(_ event: SessionEvent) {
        switch event {
        case .handshakeCompleted(let remote):
            emit("""
                noise: handshake complete — client static \
                \(Hex.string(remote))
                """)
            // The authenticated client's path: the media sockets connect
            // there before message 2 is flushed. Should that fail, sends
            // still leave through the listening socket, addressed.
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
                emit("beacon: echo \(seq) offset \(offset) µs rtt \(rtt) µs")
            }
        case .reliableCtrl(let group, let message):
            // The pairing service claims its four CTRL types; nil means
            // the message is some other consumer's (none exist yet —
            // capabilities land with W7).
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
                // The keystore write and its prints run off the lock
                // (service() drains these), never on the drain thread
                // under it.
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
                // Execute the rebind: media now targets the new tuple.
                do {
                    try connectMedia(
                        host: primary.tuple.remoteAddress,
                        port: primary.tuple.remotePort)
                } catch {
                    emit("path: rebind failed: \(error)")
                }
            }
        case .handshakeCookieModeChanged(let requireCookie):
            // HS-21: the observable dial. Loud on purpose — this is the
            // live evidence the flip happened and cleared.
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
            // HS-18: both ends declared key 9 — the client is owed one
            // starting-posture 0x19 (its control strip renders it).
            // Buffered; the next service pass sends it off this stack.
            if agreed.hostAudioRouting {
                routingAnnounceOwed = true
            }
            // E3: both ends declared key 13 — the client is owed the
            // eye's standing cursor shape (the same buffered pattern).
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
                emit("rate: ↑ \(bps / 1_000) kbps (evidence climb)")
            case .overuse:
                lastPrintedRate = bps
                // The ramp hunt's forensics: the evidence at fall time,
                // so a post-mortem can say why neither the
                // self-reference gate nor the stall gate held it.
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
            // Delivered under the lock mid-iteration: buffer only. The
            // flip (a PipeWire connect) runs off-lock in service().
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
            // CL-15/HS-19: the session's gate + book already ran (the
            // book is pre-armed against this apply's echo). Delivered
            // under the lock mid-iteration: buffer only — the apply
            // (a blocking D-Bus SetSelection) runs off-lock in
            // service(). Never logs the payload.
            if clipboardApplyHandler != nil {
                emit("""
                    clipboard: 0x1A set received \
                    (\(text.utf8.count) B) — applying to the host \
                    clipboard
                    """)
                pendingClipboardApplies.append(text)
            } else {
                // Defensive: a leafless shell never declares key 10,
                // so the core's rule-3 gate makes this unreachable.
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
            // Duplicates are the watcher's steady state between real
            // changes — only budget suppressions are worth a line;
            // both land in the counters either way.
            if reason == .overBudget {
                emit("cursor: shape suppressed (\(reason))")
            }
        case .bulkMessageReceived(let message):
            // Buffered for the off-lock shell pass (disk IO must not
            // ride the session lock). Chunks arrive by the hundred —
            // silent here; the shell's events narrate the transfer.
            pendingBulkMessages.append(message)
        case .clipboardImageReceived(let data, let mime):
            // P-1: sha-verified — buffer for the off-lock leaf apply
            // (a blocking D-Bus SetSelection). Never logs the payload.
            if clipboardImageApplyHandler != nil {
                emit("""
                    clipboard: image received (\(data.count) B, \
                    \(mime)) — applying to the host clipboard
                    """)
                pendingClipboardImageApplies.append(data)
            } else {
                // Defensive: an imageless shell never declares key
                // 12, so the core's gate makes this unreachable.
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

    /// One delivered input event → the injector → the session's echo
    /// buffer (flushed as 0x17 on the next service pass). Failures are
    /// counted and loud, never fatal — a stuck injector must not kill
    /// the stream carrying the user's screen.
    private func injectInput(
        _ event: InputEvent, receivedAtMicroseconds rxMicros: UInt64
    ) {
        // The video posture's wake signal — stamped whether or not an
        // injector is live (the user acted either way).
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
        lastInputInjectedAt = injectMicros
        switch event.body {
        case .pointerMotionAbsolute(let x, let y):
            pointerMotionInjected += 1
            lastPointerMotionInjectedAt = injectMicros
            lastAbsolutePointer = (x, y)
        case .pointerMotionRelative:
            pointerMotionInjected += 1
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
            lastSendError = why
            throw HostError("session send failed: \(why)")
        }
    }

    /// The connected media socket for a lane, once the client is known.
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

    /// One datagram addressed explicitly, from the listening socket: path
    /// challenges to unvalidated tuples, and anything sent before the
    /// media sockets connect.
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

    /// One lane's batch staged into `scratch` (stable pointers for the
    /// sendmmsg call), each datagram with its class's TOS.
    private func writeBatch(
        _ batch: ArraySlice<VideoChannelDatagram>, lane: SocketLane
    ) -> SocketWriteResult {
        guard let socket = socket(for: lane) else {
            // No connected media socket yet: address the head datagram to
            // the primary tuple from the listening socket.
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
