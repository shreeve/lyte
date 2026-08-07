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
// Mode (extending HS-5's --wire-out into a real session):
//   • Noise: bind, print the host static public key, block
//     until a client's IK message 1 arrives (that datagram's source is
//     the session's initial validated tuple), connect() to it, complete
//     the handshake, then stream. `--wire-listen PORT` binds a fixed
//     port; `--wire-out HOST:PORT` pre-connects and still awaits msg1.
//
// Threading honesty, amended at HS-15 and again at the fps-ceiling fix:
// the VIDEO PipeWire loop thread runs capture → encode → sendFrame
// (ingest only) and the idle-floor tick's service pass; audio arrives on
// ITS OWN PipeWire loop thread (CPipeWireAudio owns a separate
// pw_main_loop) at the 5 ms cadence — a cadence the ~16.7 ms video tick
// could never honor, which is exactly why audio cannot funnel through
// the video thread. One NSLock therefore guards the (single-threaded by
// design) Session and the outbox. Audio capture never waits for that
// broad lock: it publishes each 5 ms packet into a narrow FIFO mailbox
// and wakes the elevated sender. Sequence allocation, Noise sealing,
// pacer insertion, and socket flush still happen under the Session lock,
// preserving one mutation order. Large video ingests cooperatively drain
// the mailbox between small shard groups, so packetize/FEC/seal cannot
// monopolize the lock across an audio deadline.
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
        print("sched: \(label) thread nice -10 (no rtprio rlimit — "
            + "SCHED_RR refused; see Host/README to grant it)")
        return
    }
    print("sched: \(label) thread NOT elevated (unprivileged, no "
        + "RLIMIT_NICE) — running at default CFS priority")
    #endif
}

final class SessionWire {
    enum ClientAwaitOutcome: Equatable {
        case established
        case terminationRequested
    }

    private let netio: OpaquePointer
    private var latencyNetio: OpaquePointer?
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
    private var outbox: [VideoChannelDatagram] = []

    /// Scratch for one sendmmsg batch: pointers must stay valid for the
    /// duration of the call, so datagrams are staged here.
    private let scratch: UnsafeMutablePointer<UInt8>
    private static let scratchCapacity = Int(LYTE_NETIO_MAX_BATCH) * 1_200

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
    /// Stage books for the fps-ceiling hunt (Q-1's red row): the last
    /// sendFrame's packetize+FEC+seal time and its pacer-drain time,
    /// split so the Sink's 5 s stage window can say where the frame
    /// period went. Written and read on the video loop thread only.
    private(set) var lastFrameIngestNanos: UInt64 = 0
    private(set) var lastFrameDrainNanos: UInt64 = 0
    /// Most recent successfully admitted frame, for the synchronous
    /// encoder callback to attach QP/IDR-cause fields to its flight.
    private var lastFrameForTelemetry: FrameNumber?
    private struct PendingAudioPacket {
        var bytes: [UInt8]
        var captureMicros: UInt64
        var offeredAtNS: UInt64
    }
    /// The audio capture thread owns only this narrow publication lock.
    /// The Session owner swaps the whole FIFO out before doing any
    /// framing/sealing work, so capture never waits for video.
    private let audioMailboxLock = NSLock()
    private var audioMailbox: [PendingAudioPacket] = []
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
    private(set) var datagramsSent = 0
    private(set) var bytesSent = 0
    private(set) var socketWouldBlockCount = 0
    private(set) var socketPendingMaxDatagrams = 0
    private(set) var socketPendingMaxBytes = 0
    private(set) var audioSocketWouldBlockCount = 0
    private(set) var audioSocketOutboxMaxNS: UInt64 = 0
    private(set) var audioSocketWorstSeq: UInt16?
    private(set) var audioSocketWorstEnqueuedAtNS: UInt64?
    private(set) var audioSocketWorstAcceptedAtNS: UInt64?
    private(set) var audioSocketWorstBlockedByVideo = false
    private(set) var socketSendBufferBytes = 0
    private(set) var latencySocketSendBufferBytes = 0
    private(set) var latencySocketOutqMaxBytes = 0
    private(set) var socketOutqMaxBytes = 0
    private(set) var socketOutqQueryFailures = 0
    private(set) var socketENOBUFSCount = 0
    private(set) var videoSocketWouldBlockCount = 0
    private(set) var latencySocketWouldBlockCount = 0
    private(set) var videoSocketENOBUFSCount = 0
    private(set) var latencySocketENOBUFSCount = 0
    private(set) var socketFreshVideoShedDatagrams = 0
    private(set) var socketFreshVideoShedBytes = 0
    private var currentVideoSocketOutqBytes = 0
    private var currentLatencySocketOutqBytes = 0
    private var kernelPressureGovernor = KernelPressureGovernor()
    private var kernelPressureDecision: KernelPressureDecision?
    private struct AudioOutboxTrace {
        var enqueuedAtNS: UInt64
        var blockedByVideo: Bool
    }
    private var audioOutboxTrace: [UInt16: AudioOutboxTrace] = [:]
    private var freshVideoReleasedAtNS: [UInt64: UInt64] = [:]
    private var freshVideoFramesPartiallyAccepted: Set<UInt32> = []
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

        var err = [CChar](repeating: 0, count: 256)
        guard let n = lyte_netio_new("0.0.0.0", listenPort ?? 0,
                                     &err, err.count) else {
            throw HostError("session socket open failed: \(errString(err))")
        }
        netio = n
        guard lyte_netio_set_priority(n, 4) == 0 else {
            lyte_netio_free(n)
            throw HostError("video socket SO_PRIORITY failed")
        }
        socketSendBufferBytes = max(
            Int(lyte_netio_send_buffer_bytes(n)), 0)
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
            try openLatencyLane(peerHost: peer.host, peerPort: peer.port)
        }

        // The sender thread comes up parked (no work until the first
        // ingest signals it); it holds `self` for its lifetime, so the
        // shell must stop it (shutdown does) before the process lets
        // the SessionWire go. SessionWire is cross-thread by design
        // (video loop, audio loop, sender thread) with `lock` as the
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
        lyte_netio_free(netio)
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

    private func openLatencyLane(
        peerHost: String, peerPort: UInt16
    ) throws {
        guard latencyNetio == nil else { return }
        var err = [CChar](repeating: 0, count: 256)
        let localPort = lyte_netio_local_port(netio)
        guard let lane = lyte_netio_new(
            "0.0.0.0", localPort, &err, err.count
        ) else {
            throw HostError("latency socket open failed: \(errString(err))")
        }
        guard lyte_netio_set_peer(
            lane, peerHost, peerPort, &err, err.count
        ) == 0 else {
            lyte_netio_free(lane)
            throw HostError("latency socket connect failed: \(errString(err))")
        }
        guard lyte_netio_set_priority(lane, 6) == 0 else {
            lyte_netio_free(lane)
            throw HostError("latency socket SO_PRIORITY failed")
        }
        latencyNetio = lane
        latencySocketSendBufferBytes = max(
            Int(lyte_netio_send_buffer_bytes(lane)), 0)
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
            sendAccounting: .socketConfirmed
        ) { [weak self] datagram in
            self?.appendOutbox(datagram)
        }
    }

    private func appendOutbox(_ datagram: VideoChannelDatagram) {
        if datagram.pacerClass == .audio {
            let blockedByVideo = outbox.contains {
                $0.pacerClass == .freshVideo
                    || $0.pacerClass == .videoTail
                    || $0.pacerClass == .refinement
            }
            audioOutboxTrace[datagram.seq.rawValue] = AudioOutboxTrace(
                enqueuedAtNS: SystemMonotonicClock.nowNanoseconds, blockedByVideo: blockedByVideo)
        }
        if datagram.pacerClass == .freshVideo {
            freshVideoReleasedAtNS[datagramTraceKey(datagram)] = SystemMonotonicClock.nowNanoseconds
        }
        outbox.append(datagram)
    }

    private func datagramTraceKey(_ datagram: VideoChannelDatagram) -> UInt64 {
        UInt64(datagram.frameNumber.rawValue) << 16
            | UInt64(datagram.seq.rawValue)
    }

    @discardableResult
    private func observeKernelPressure(
        _ session: Session, now: UInt64
    ) -> KernelPressureDecision {
        let videoOutq = Int(lyte_netio_outq_bytes(netio))
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
                videoWouldBlockCount: videoSocketWouldBlockCount,
                latencyWouldBlockCount: latencySocketWouldBlockCount,
                videoENOBUFSCount: videoSocketENOBUFSCount,
                latencyENOBUFSCount: latencySocketENOBUFSCount,
                pacerRateBitsPerSecond: session.pacerRateBitsPerSecond,
                videoQueueBudgetNS: session.videoQueueBudgetNS,
                frameBudgetBytes: session.frameByteCeiling(fps: 60)))
        kernelPressureDecision = decision
        return decision
    }

    private func shedOldestStaleFreshVideo(
        now: UInt64, budgetNS: UInt64
    ) {
        guard let session else { return }
        var oldest: (frame: UInt32, releasedAt: UInt64)?
        for datagram in outbox
        where datagram.pacerClass == .freshVideo {
            let frame = datagram.frameNumber.rawValue
            guard !freshVideoFramesPartiallyAccepted.contains(frame)
            else { continue }
            guard let releasedAt = freshVideoReleasedAtNS[
                datagramTraceKey(datagram)],
                KernelPressureGovernor.shouldShedAtSocket(
                    priorityClass: datagram.pacerClass,
                    releasedAtNS: releasedAt,
                    nowNS: now,
                    videoQueueBudgetNS: budgetNS)
            else { continue }
            if oldest == nil || releasedAt < oldest!.releasedAt {
                oldest = (frame, releasedAt)
            }
        }
        guard let oldest else { return }
        var droppedDatagrams = 0
        var droppedBytes = 0
        outbox.removeAll { datagram in
            guard datagram.pacerClass == .freshVideo,
                  datagram.frameNumber.rawValue == oldest.frame
            else { return false }
            freshVideoReleasedAtNS.removeValue(
                forKey: datagramTraceKey(datagram))
            session.discardPendingDatagram(datagram)
            droppedDatagrams += 1
            droppedBytes += datagram.bytes.count
            return true
        }
        session.noteKernelPressureFreshVideoShed(
            datagrams: droppedDatagrams, bytes: droppedBytes)
        socketFreshVideoShedDatagrams += droppedDatagrams
        socketFreshVideoShedBytes += droppedBytes
    }

    private func pumpForSocketState(_ session: Session) {
        let now = SystemMonotonicClock.nowNanoseconds
        let pressure = observeKernelPressure(session, now: now)
        if pressure.state == .latencyOnly {
            shedOldestStaleFreshVideo(
                now: now, budgetNS: session.videoQueueBudgetNS)
        }
        if outbox.isEmpty, pressure.allowVideoPump {
            session.pump(now: now)
        } else {
            session.pumpLatency(now: now)
        }
    }

    /// Noise mode: block until a client completes message 1 (the session
    /// establishes inside `receive`), up to `timeoutSeconds`. Prints the
    /// static public key the client must hold. Call before capture opens
    /// so no video is encoded for nobody.
    func awaitClient(
        hostStatic: NoiseKeyPair,
        timeoutSeconds: Double,
        stopRequested: () -> Bool = { false }
    ) throws -> ClientAwaitOutcome {
        print("noise: host static public key "
            + Hex.string(hostStatic.publicKey))
        print("noise: awaiting client handshake on port "
            + "\(lyte_netio_local_port(netio)) …")
        traceHandshake("awaitClientBegin", fields: [
            "pid": String(getpid()),
            "primaryLocalPort": String(lyte_netio_local_port(netio)),
            "latencySocketExists": String(latencyNetio != nil),
        ])

        let deadline = SystemMonotonicClock.nowNanoseconds + UInt64(timeoutSeconds * 1e9)
        while SystemMonotonicClock.nowNanoseconds < deadline {
            if stopRequested() {
                return .terminationRequested
            }
            var established = false
            lock.lock()
            do {
                try receiveAll(from: netio) { [weak self] datagram, tuple in
                    guard let self else { return }
                    if self.session == nil {
                        self.awaitPrimaryDatagrams += 1
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
                        let plausible =
                            Self.looksLikeHandshakeInitiation(datagram)
                        let payloadType: UInt8? = (try? Envelope.decode(
                            datagram[...]))?.1.first
                        self.traceHandshake("primaryDatagram", fields: [
                            "ordinal": String(self.awaitPrimaryDatagrams),
                            "bytes": String(datagram.count),
                            "remoteAddress": tuple.remoteAddress,
                            "remotePort": String(tuple.remotePort),
                            "shapeAccepted": String(plausible),
                            "payloadType": payloadType.map(String.init) ?? "",
                            "latencySocketExists":
                                String(self.latencyNetio != nil),
                        ])
                        guard plausible else { return }
                        // Its source is the session's initial tuple;
                        // connect() so the send path has a peer.
                        var err = [CChar](repeating: 0, count: 256)
                        guard lyte_netio_set_peer(
                            self.netio, tuple.remoteAddress, tuple.remotePort,
                            &err, err.count) == 0 else {
                            self.emit(
                                "session: connect to \(tuple.remoteAddress):"
                                    + "\(tuple.remotePort) failed: "
                                    + "\(errString(err))")
                            return
                        }
                        do {
                            try self.openLatencyLane(
                                peerHost: tuple.remoteAddress,
                                peerPort: tuple.remotePort)
                            self.traceHandshake(
                                "latencySocketOpened", fields: [
                                    "remoteAddress": tuple.remoteAddress,
                                    "remotePort": String(tuple.remotePort),
                                ])
                        } catch {
                            self.emit("session: \(error)")
                            return
                        }
                        self.makeSession(
                            crypto: .noise(hostStatic: hostStatic),
                            clientTuple: tuple
                        )
                    }
                    let events = self.session.receive(
                        datagram, from: tuple,
                        now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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
                try drainToIdle()
                return .established
            }
            usleep(2_000)
        }
        if stopRequested() {
            return .terminationRequested
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
    /// session comes up; the policy's baseline mirrors the native
    /// seat's opening posture).
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
            now: SystemMonotonicClock.nowNanoseconds
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
            now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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
            now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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
        // main stops the audio source before teardown; flush its final
        // published quantum while the established session still exists.
        lock.lock()
        drainAudioMailboxLocked()
        lock.unlock()
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
            now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
        ) {
            log(event)
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
                lastSendError = String(describing: error)
                lock.unlock()
                break
            }
            lock.unlock()
            usleep(2_000)
        }
        flushLogLines()
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
        let ingestStart = SystemMonotonicClock.nowNanoseconds
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
        lastFrameIngestNanos = SystemMonotonicClock.nowNanoseconds - ingestStart
        lastFrameDrainNanos = 0 // the capture thread no longer waits
        signalDrain()
    }

    /// Debug/evidence drain for the synthetic motion leg. The underlying
    /// telemetry is populated by the unchanged production admission and
    /// sender paths.
    func takeFrameTransmitTelemetry() -> [VideoFrameTransmitTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        return session.takeFrameTransmitTelemetry()
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

    /// Atomic pre-encode admission posture. The queue's wire time and
    /// clean/impaired budget come from the same locked Session snapshot,
    /// so a regime/rate move cannot mix eras in the admission decision.
    var videoAdmissionPosture: (
        backlogWireTimeNS: UInt64, budgetNS: UInt64, regime: FecRegime,
        kernelState: KernelPressureState
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let session else {
            return (0, 50_000_000, .clean, .calm)
        }
        let pressure = observeKernelPressure(
            session, now: SystemMonotonicClock.nowNanoseconds)
        return (
            pressure.totalVideoServiceDebtNS,
            pressure.admissionBudgetNS,
            session.fecRegime,
            pressure.state)
    }

    /// HS-15: one encoded 5 ms Opus packet from the AUDIO capture
    /// thread. Publication uses only the narrow mailbox lock; it never
    /// waits behind video packetize/FEC/seal or broad session service.
    /// The elevated sender (or a cooperative video-ingest checkpoint)
    /// performs ordered framing, Noise sealing, pacing, and send.
    /// Audio deliberately flows in IDLE and FROZEN (the 5 ms path
    /// probe — Session's ruling; only `closed` suppresses).
    func sendAudioPacket(_ packet: [UInt8], captureMicros: UInt64) {
        let pending = PendingAudioPacket(
            bytes: packet, captureMicros: captureMicros,
            offeredAtNS: SystemMonotonicClock.nowNanoseconds
        )
        audioMailboxLock.lock()
        if audioMailbox.count < Self.audioMailboxCapacity {
            audioMailbox.append(pending)
            audioMailboxMaxDepth = max(audioMailboxMaxDepth, audioMailbox.count)
        } else {
            audioMailboxOverflows += 1
        }
        audioMailboxLock.unlock()

        // The capture callback is already scheduled at the 5 ms cadence.
        // Use that wake directly whenever the Session owner is between
        // bounded critical sections; this avoids making audio depend solely
        // on a default-CFS sender thread being scheduled after signal().
        // try() never blocks the capture loop. Sequence allocation, Noise
        // sealing, pacer insertion, and send still happen under `lock`.
        if lock.try() {
            drainAudioMailboxLocked()
            if let session, session.phase == .established, !peerGone {
                pumpForSocketState(session)
                do {
                    try flushOutbox()
                } catch {
                    audioSendFailures += 1
                    lastSendError = String(describing: error)
                }
            }
            lock.unlock()
            flushLogLines()
        }
        signalDrain()
    }

    /// Requires the broad Session lock. The mailbox lock is held only
    /// long enough to swap the FIFO; framing/sealing/syscalls happen
    /// after audio capture is free to publish its next quantum.
    private func drainAudioMailboxLocked() {
        audioMailboxLock.lock()
        var pending: [PendingAudioPacket] = []
        swap(&pending, &audioMailbox)
        audioMailboxLock.unlock()
        guard !pending.isEmpty else { return }

        for packet in pending {
            guard let session, session.phase == .established, !peerGone else {
                audioPacketsDroppedPreSession += 1
                continue
            }
            let now = SystemMonotonicClock.nowNanoseconds
            let dwell = now &- packet.offeredAtNS
            audioMailboxMaxDwellNS = max(audioMailboxMaxDwellNS, dwell)
            audioMailboxDwell.record(dwell)
            do {
                _ = try session.ingestAudioPacket(
                    packet.bytes,
                    captureTimestampMicroseconds: packet.captureMicros,
                    now: now
                )
                pumpForSocketState(session)
                try flushOutbox()
                audioPacketsSent += 1
            } catch {
                audioSendFailures += 1
                lastSendError = String(describing: error)
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
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
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
        lock.unlock()
        flushLogLines()
        if leftovers { signalDrain() }

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
                    print("files: offer \(Hex.string(id)) accepted — "
                        + "\"\(BulkFileNaming.sanitized(name))\" "
                        + "(\(bytes) B\(resuming ? ", RESUMING" : ""))")
                case .offerRefusedBusy(let id):
                    print("files: offer \(Hex.string(id)) refused — "
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
        guard let session, session.phase == .established else {
            lock.unlock()
            return
        }
        for reply in replies {
            do {
                try session.sendBulk(
                    reply.encode(),
                    now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
                )
            } catch {
                lastSendError = String(describing: error)
                emit("files: bulk send failed: \(error)")
            }
        }
        do {
            try serviceOnce()
            try flushOutbox()
        } catch {
            lastSendError = String(describing: error)
        }
        lock.unlock()
        flushLogLines()
    }

    /// E3: the eye's report that the hardware cursor plane changed —
    /// a content-cropped shape or the hidden state. Remembered as the
    /// standing shape (re-offered when capabilities agree), then the
    /// 0x24 (or the suppression verdict) happens inside the core; a
    /// no-key-13 session stays silent (the rule-3 gate).
    func noteCursorShape(_ shape: CursorShape) {
        lock.lock()
        defer { lock.unlock() }
        standingCursorShape = shape
        guard let session, session.phase == .established else { return }
        for event in session.noteCursorShapeChanged(
            shape, now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        for event in session.noteHostClipboardChanged(
            text, now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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
            data, now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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
            mode, now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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

    /// Tripwire: whether THIS session agreed key 15 (audioQuietPosture).
    /// The audio thread asks per packet before ever gating — a legacy
    /// client keeps the always-on contract, silence included.
    func audioQuietPostureAgreed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return false }
        return session.agreedAudioQuietPosture
    }

    /// Video posture: whether THIS session agreed key 16. The video
    /// leg asks per poll before ever backing off its keepalive.
    func videoQuietPostureAgreed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return false }
        return session.agreedVideoQuietPosture
    }

    /// Video posture: one 0x26 announcement onto the reliable stream
    /// (a no-op at the session layer unless key 16 was agreed).
    func sendVideoPostureState(quiet: Bool, keepaliveSeconds: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        let state = VideoPostureState(
            posture: quiet ? .quiet : .active,
            keepaliveSeconds: keepaliveSeconds)
        for event in session.noteVideoPostureState(
            state, now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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

    /// The wake-on-input half of the video posture: the drain thread
    /// stamps every injected input event; the video leg reads the
    /// stamp each poll — an input packet IS the wake, zero added
    /// latency (postures design). Monotonic ns, atomic via configLock
    /// (cold: one store per input event, one load per poll).
    private var _lastInputActivityNS: UInt64 = 0
    var lastInputActivityNS: UInt64 {
        get { withConfigLock { _lastInputActivityNS } }
        set { withConfigLock { _lastInputActivityNS = newValue } }
    }

    /// Tripwire: one 0x25 track-state announcement onto the reliable
    /// stream (a no-op at the session layer unless key 15 was agreed).
    func sendAudioTrackState(_ state: AudioTrackState.State) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, session.phase == .established else { return }
        for event in session.noteAudioTrackState(
            state, now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
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
        emit("session: client unreachable (ICMP port closed — it exited) "
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
                flushLogLines()
                throw error
            }
            let done = peerGone || (session.isIdle && outbox.isEmpty)
            let now = SystemMonotonicClock.nowNanoseconds
            let wake = session.nextWake(now: now)
            let socketRetry = !outbox.isEmpty
            lock.unlock()
            flushLogLines()
            if done { return }
            if socketRetry {
                // Nonblocking UDP backpressure: retry outside the Session
                // lock so 5 ms audio can still enter and preempt video.
                usleep(200)
            } else if let wake, wake > now {
                usleep(UInt32(min((wake - now) / 1_000 + 1, 2_000)))
            }
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
        let receive: ([UInt8], FourTuple) -> Void = { [weak self]
            datagram, tuple in
            guard let self, let session = self.session else { return }
            for event in session.receive(
                datagram, from: tuple,
                now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
            ) {
                self.log(event)
            }
            // A recvmmsg burst can contain many feedback/control packets.
            // Do not let parsing the whole burst consume an audio period.
            self.drainAudioMailboxLocked()
        }
        try receiveAll(from: netio, receive)
        if let latencyNetio {
            try receiveAll(from: latencyNetio, receive)
        }
        for event in session.advance(
            now: SystemMonotonicClock.nowNanoseconds, hostMicroseconds: SystemMonotonicClock.nowMicroseconds
        ) {
            log(event)
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
        while true {
            let got = recvSlots.withUnsafeMutableBufferPointer { slots in
                lyte_netio_recv_batch(socket, slots.baseAddress,
                                      Int32(slots.count),
                                      &recvError, recvError.count)
            }
            if got == LYTE_NETIO_PEER_GONE {
                notePeerGone()
                return
            }
            if got < 0 {
                throw HostError("recv failed: \(errString(recvError))")
            }
            if got == 0 { return }
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
            // One recvmmsg batch per critical section. A continuously full
            // feedback socket must not turn `receiveAll` into an unbounded
            // broad-lock owner; the sender loop immediately takes another
            // pass, with an unlock/service opportunity between batches.
            return
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

    private func log(_ event: SessionEvent) {
        switch event {
        case .handshakeCompleted(let remote):
            emit("noise: handshake complete — client static "
                + Hex.string(remote))
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
                for pairingEvent in output.events {
                    onPairingEvent(pairingEvent)
                }
                return
            }
            emit("ctrl-arq: message group \(group.rawValue) "
                + "(\(message.count) B, type "
                + "\(Hex.string(message.first ?? 0, prefix: true)))")
        case .reliableOneShotAcknowledged(let group):
            emit("ctrl-arq: one-shot group \(group.rawValue) acknowledged")
        case .arqIgnored(let reason):
            emit("ctrl-arq: ignored \(reason)")
        case .idrRequested(let request):
            emit("ctrl: IDR request seq \(request.requestSeq) "
                + "(frame \(request.frame.rawValue), "
                + "coalesced \(request.coalescedCount))")
        case .path(let pathEvent):
            emit("path: \(pathEvent)")
            if case .promoted(let primary, _) = pathEvent {
                // Execute the rebind: media now targets the new tuple.
                var err = [CChar](repeating: 0, count: 256)
                if lyte_netio_set_peer(
                    netio, primary.tuple.remoteAddress,
                    primary.tuple.remotePort, &err, err.count) != 0 {
                    emit("path: rebind connect failed: \(errString(err))")
                }
                if let latencyNetio,
                   lyte_netio_set_peer(
                    latencyNetio, primary.tuple.remoteAddress,
                    primary.tuple.remotePort, &err, err.count) != 0 {
                    emit("path: latency rebind failed: \(errString(err))")
                }
            }
        case .handshakeCookieModeChanged(let requireCookie):
            // HS-21: the observable dial. Loud on purpose — this is the
            // live evidence the flip happened and cleared.
            emit(requireCookie
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
            emit("drop: \(reason)")
        case .sendFailed(let what):
            emit("send-failed: \(what)")
        case .capabilitiesAgreed(let agreed):
            emit("capabilities: agreed — wire minor \(agreed.wireMinor), "
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
            // E3: both ends declared key 13 — the client is owed the
            // eye's standing cursor shape (the same buffered pattern).
            if agreed.cursorShape {
                cursorAnnounceOwed = true
            }
        case .capabilitiesFailed(let why):
            emit("capabilities: NO WORKABLE INTERSECTION (\(why)) — "
                + "typed teardown follows")
        case .capabilityUpdateAcknowledged(let accepted):
            emit("capabilities: update "
                + (accepted ? "accepted" : "rejected") + " by the client")
        case .modeTransitionSent(let mode):
            emit("mode: → \(mode == .idle ? "IDLE" : "ACTIVE") "
                + "(0x09 on the reliable stream)")
        case .finalFrameSent(let group):
            emit("mode: converged frame riding one-shot group "
                + "\(group.rawValue) — its ack is the idle flip")
        case .teardownSent(let reason):
            emit("session: teardown 0x0A queued (\(reason))")
        case .lifecycleChanged(let state):
            switch state {
            case .frozen:
                emit("lifecycle: FROZEN — 350 ms of media-path silence; "
                    + "datagram video suspended, CTRL stays alive")
            case .recovery:
                emit("lifecycle: RECOVERY — evidence returned; fresh IDR "
                    + "at the half-stale rate, sends resume")
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
            purgeSocketPendingVideo()
            emit("rate: fall purge — \(datagrams) queued video datagrams "
                + "(\(bytes) B, ~\(staleWireMs) ms stale at the new rate) "
                + "dropped, fresh IDR armed")
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
                emit("rate: ↓ \(bps / 1_000) kbps (queuing-delay overuse)"
                    + forensics)
            case .loss:
                lastPrintedRate = bps
                emit("rate: ↓ \(bps / 1_000) kbps (loss over threshold)")
            case .idrPacing(let pacing):
                lastPrintedRate = bps
                emit("rate: → \(bps / 1_000) kbps (IDR pacing \(pacing))")
            case .postFecLoss:
                lastPrintedRate = bps
                emit("rate: ↓ \(bps / 1_000) kbps (post-FEC loss — "
                    + "rung 3)")
            }
        case .repairEnqueued(let frame, let shards):
            emit("repair: frame \(frame.rawValue) — \(shards) shard(s) "
                + "retransmitted (fresh seqs, videoTail)")
        case .nackJudgedStale(let frame, let reason):
            emit("repair: NACK frame \(frame.rawValue) judged stale "
                + "(\(reason))")
        case .fecRegimeChanged(let regime):
            emit("fec: regime → \(regime.rawValue) "
                + "(§5.2 \(regime == .lossy ? "lossy" : "clean") column)")
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
            emit("video-posture: \(state.posture) "
                + "keepalive \(state.keepaliveSeconds)s announced (0x26)")
        case .clipboardSetReceived(let text):
            // CL-15/HS-19: the session's gate + book already ran (the
            // book is pre-armed against this apply's echo). Delivered
            // under the lock mid-iteration: buffer only — the apply
            // (a blocking D-Bus SetSelection) runs off-lock in
            // service(). Never logs the payload.
            if clipboardApplyHandler != nil {
                emit("clipboard: 0x1A set received "
                    + "(\(text.utf8.count) B) — applying to the host "
                    + "clipboard")
                pendingClipboardApplies.append(text)
            } else {
                // Defensive: a leafless shell never declares key 10,
                // so the core's rule-3 gate makes this unreachable.
                emit("clipboard: 0x1A set received "
                    + "(\(text.utf8.count) B) — no clipboard leaf, "
                    + "ignored")
            }
        case .clipboardAnnounceSent(let byteCount):
            emit("clipboard: announce sent (\(byteCount) B, 0x1B)")
        case .clipboardAnnounceSuppressed(let reason):
            emit("clipboard: announce suppressed (\(reason))")
        case .cursorShapeSent(let pixelByteCount, let hidden):
            emit("cursor: shape sent (0x24, "
                + (hidden ? "hidden" : "\(pixelByteCount) B") + ")")
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
                emit("clipboard: image received (\(data.count) B, "
                    + "\(mime)) — applying to the host clipboard")
                pendingClipboardImageApplies.append(data)
            } else {
                // Defensive: an imageless shell never declares key
                // 12, so the core's gate makes this unreachable.
                emit("clipboard: image received (\(data.count) B) — "
                    + "no image leaf, ignored")
            }
        case .clipboardImageShareStarted(let byteCount):
            emit("clipboard: image share started (\(byteCount) B "
                + "as chan-8 cargo)")
        case .clipboardImageShareCompleted(let byteCount):
            emit("clipboard: image share completed (\(byteCount) B, "
                + "sha-verified by the client)")
        case .clipboardImageShareAborted(let reason, let byRemote):
            emit("clipboard: image share aborted (\(reason), "
                + "\(byRemote ? "remote" : "local"))")
        case .clipboardImageReceiveAborted(let reason, let byRemote):
            emit("clipboard: image receive aborted (\(reason), "
                + "\(byRemote ? "remote" : "local"))")
        case .clipboardImageSuppressed(let reason):
            emit("clipboard: image suppressed (\(reason))")
        case .clipboardImageRefused(let reason):
            emit("clipboard: image refused (\(reason))")
        case .clipboardImageViolation(let violation):
            emit("clipboard: image lane protocol violation "
                + "(\(violation)) — aborted")
        }
    }

    private func purgeSocketPendingVideo() {
        guard let session else { return }
        outbox.removeAll { datagram in
            let isVideo = datagram.pacerClass == .freshVideo
                || datagram.pacerClass == .videoTail
                || datagram.pacerClass == .refinement
            if isVideo {
                session.discardPendingDatagram(datagram)
                freshVideoReleasedAtNS.removeValue(
                    forKey: datagramTraceKey(datagram))
            }
            return isVideo
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
                emit("input: event seq \(event.seq) arrived but no "
                    + "injection backend is active — input is OFF this run")
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
        guard !outbox.isEmpty else { return }
        if peerGone {
            outbox.removeAll(keepingCapacity: true)
            audioOutboxTrace.removeAll(keepingCapacity: true)
            freshVideoReleasedAtNS.removeAll(keepingCapacity: true)
            return
        }
        let queued = outbox
        outbox.removeAll(keepingCapacity: true)
        var err = [CChar](repeating: 0, count: 256)

        // Challenges to unvalidated tuples ride sendmsg-with-address on
        // the connected socket (lyte_netio_send_to): the challenge MUST
        // travel on the exact probed tuple — that is what it proves.
        let filtered = queued.filter { datagram in
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
                emit("path: challenge sent to \(destination.remoteAddress):"
                    + "\(destination.remotePort) (off-primary sendto)")
            } else if rc == LYTE_NETIO_PEER_GONE {
                notePeerGone()
            } else {
                lastSendError = errString(err)
                emit("path: challenge to \(destination.remoteAddress):"
                    + "\(destination.remotePort) failed: \(errString(err))")
            }
            return false
        }
        // Noise transport state is per channel. Move control/audio ahead
        // of video byte-identically, preserving FIFO within every channel.
        let deliverable = Session.prioritizeLatency(filtered)

        var staged = 0
        while staged < deliverable.count {
            let firstClass = deliverable[staged].pacerClass
            let socketLane = SocketLane.forClass(firstClass)
            let sendSocket = socketLane == .latency
                ? (latencyNetio ?? netio) : netio
            let batchEnd: Int
            if socketLane == .latency {
                var end = staged
                while end < deliverable.count,
                      end - staged < Int(LYTE_NETIO_MAX_BATCH),
                      deliverable[end].pacerClass <= .audio {
                    end += 1
                }
                batchEnd = end
            } else {
                batchEnd = min(
                    staged + Int(LYTE_NETIO_MAX_BATCH), deliverable.count)
            }
            let batch = deliverable[staged..<batchEnd]
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
                    lyte_netio_send_batch(
                        sendSocket, buf.baseAddress, Int32(buf.count), nil,
                        &err, err.count)
                }
                if sent == LYTE_NETIO_PEER_GONE {
                    notePeerGone()
                    return
                }
                if sent == LYTE_NETIO_NO_BUFFER {
                    socketENOBUFSCount += 1
                    if socketLane == .latency {
                        latencySocketENOBUFSCount += 1
                    } else {
                        videoSocketENOBUFSCount += 1
                    }
                    let unsent = staged + sentTotal
                    outbox.append(contentsOf: deliverable[unsent...])
                    let now = SystemMonotonicClock.nowNanoseconds
                    _ = observeKernelPressure(session, now: now)
                    shedOldestStaleFreshVideo(
                        now: now, budgetNS: session.videoQueueBudgetNS)
                    return
                }
                if sent < 0 {
                    lastSendError = errString(err)
                    throw HostError("session send failed: \(errString(err))")
                }
                if sent == 0 {
                    // Preserve exact datagram order and return immediately.
                    // The sender loop retries after releasing `lock`; sleeping
                    // here was the measured 100+ ms audio-mailbox stall.
                    let unsent = staged + sentTotal
                    outbox.append(contentsOf: deliverable[unsent...])
                    socketWouldBlockCount += 1
                    if socketLane == .latency {
                        latencySocketWouldBlockCount += 1
                    } else {
                        videoSocketWouldBlockCount += 1
                    }
                    let blockedOutq = max(
                        Int(lyte_netio_outq_bytes(sendSocket)), 0)
                    if socketLane == .latency {
                        latencySocketOutqMaxBytes = max(
                            latencySocketOutqMaxBytes, blockedOutq)
                    } else {
                        socketOutqMaxBytes = max(
                            socketOutqMaxBytes, blockedOutq)
                    }
                    if deliverable[unsent...].contains(where: {
                        $0.pacerClass == .audio
                    }) {
                        audioSocketWouldBlockCount += 1
                    }
                    socketPendingMaxDatagrams = max(
                        socketPendingMaxDatagrams, outbox.count)
                    socketPendingMaxBytes = max(
                        socketPendingMaxBytes,
                        outbox.reduce(0) { $0 + $1.bytes.count })
                    return
                }
                let accepted = batch.dropFirst(sentTotal).prefix(Int(sent))
                let acceptedAt = SystemMonotonicClock.nowNanoseconds
                for d in accepted {
                    if d.pacerClass == .freshVideo {
                        freshVideoFramesPartiallyAccepted.insert(
                            d.frameNumber.rawValue)
                        freshVideoReleasedAtNS.removeValue(
                            forKey: datagramTraceKey(d))
                    }
                    if d.pacerClass == .audio,
                       let trace = audioOutboxTrace.removeValue(
                            forKey: d.seq.rawValue) {
                        let delay = acceptedAt &- trace.enqueuedAtNS
                        if delay > audioSocketOutboxMaxNS {
                            audioSocketOutboxMaxNS = delay
                            audioSocketWorstSeq = d.seq.rawValue
                            audioSocketWorstEnqueuedAtNS = trace.enqueuedAtNS
                            audioSocketWorstAcceptedAtNS = acceptedAt
                            audioSocketWorstBlockedByVideo =
                                trace.blockedByVideo
                        }
                    }
                    session.confirmDatagramSent(d, now: acceptedAt)
                    datagramsSent += 1
                    bytesSent += d.bytes.count
                }
                sentTotal += Int(sent)
            }
            staged += batch.count
        }
    }
}
