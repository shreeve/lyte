// Session: the host's sans-IO session core — one live Lyte-UDP stream
// from handshake to teardown. It owns:
//
//   • the Noise IK handshake as RESPONDER: consume the client's message
//     1, produce message 2, derive the NoiseTransport. The client knows
//     the host's static out-of-band (pinned at pairing). IK's payloads
//     carry the version byte; the session-start beacon is the host's
//     first sealed word.
//   • the seal discipline: every outbound datagram (video, audio,
//     beacons, path challenges, ARQ) is sealed with the exact header
//     bytes (fixed envelope + TLV block) as AAD, mirroring the client. A
//     test-only passthrough isolates geometry and pacing; no executable
//     can select it.
//   • the 1 Hz clock beacon on CTRL: beaconSeq from 0 plus one beacon at
//     establishment; t1 is the injected host graph-clock µs. Each sealed
//     BeaconEcho yields one offset/RTT sample; the next beacon mirrors
//     the last echo.
//   • path validation: the session mints its ConnectionId (TLV on every
//     outbound datagram), inbound datagrams feed the PathValidator,
//     challenges ride CTRL to the exact unvalidated tuple, and
//     `takeFreshKeyframeRequest()` merges promotion IDRs with client
//     0x10 requests into one encoder-loop poll.
//   • one Pacer schedule for every traffic class (VideoChannel owns it;
//     control enters via `enqueueControl`).
//   • reliable CTRL over an `ArqEndpoint`: payloads whose first byte is
//     0x07/0x08 route wholly to `ingest`; deliveries and one-shot acks
//     surface as events. The endpoint packs at the connection-id-tagged
//     plaintext ceiling; the session only seals and schedules. Beacons,
//     echoes, path messages, handshakes and IDR requests stay ARQ-exempt
//     (time-sensitive, tuple-bound, pre-transport, or self-superseding).
//     ARQ PTO deadlines fold into `nextWake` and `advance` services them.
//
// No sockets, threads or clock. Entry points take `now` (monotonic ns,
// the pacer/validator domain) and `hostMicroseconds` (PipeWire graph-clock
// µs, the envelope-timestamp and beacon-t1 domain). Datagrams leave
// through the injected send sink in pacer order; everything the caller
// must act on comes back as `SessionEvent` values.

import HostCore
import HostSession
import LyteCore
import LyteWire

/// How the session's transport keys come to exist.
public enum SessionCryptoMode: Sendable {
    /// Real Noise IK (the default): the host responds with this pinned
    /// static keypair; the transport derives from the completed
    /// handshake.
    case noise(hostStatic: NoiseKeyPair)
    /// Test-only passthrough: no handshake or authentication. Shipping
    /// executables cannot select it; gates use it to isolate wire geometry.
    @_spi(Testing) case testPassthrough
}

public struct SessionConfig: Sendable {
    public var crypto: SessionCryptoMode
    /// The negotiated session ceiling: the pacer's starting rate and the
    /// estimator's upper bound (the live rate moves inside [floor, this]).
    public var rateBitsPerSecond: Int
    public var regime: FecRegime
    public var pacerQuantumNS: UInt64
    /// Default 1 Hz; a beacon also goes out at establishment.
    public var beaconIntervalNS: UInt64
    public var path: PathValidatorConfig
    /// Reliable-CTRL knobs. The session injects its connection-id-tagged
    /// CTRL plaintext ceiling at init; the endpoint packs to it.
    public var arq: ArqConfig
    /// When set, a completing handshake whose authenticated client static
    /// is not in this set is rejected. Nil accepts any static.
    public var allowedClientStaticPublicKeys: [[UInt8]]?
    /// The pre-handshake flood throttle: message 1s beyond its budget are
    /// dropped before any Noise state is allocated.
    public var handshakeGate: HandshakeGate.Config
    /// What this host declares in the capability exchange — the session's
    /// first ARQ-carried message. The agreed set is the intersection with
    /// the client's declaration.
    public var capabilities: Capabilities
    /// The lifecycle machine's knobs: the 350 ms blackout detector, the
    /// 30 s liveness clock, RECOVERY's clean-window count.
    public var lifecycle: SessionMachineConfig
    /// Congestion estimator knobs. Nil derives the default config with
    /// `rateBitsPerSecond` as the ceiling (no capability key carries
    /// bitrate) and a 2 Mbps floor: enough for the protected lanes plus a
    /// minimum lossy-FEC video flight.
    public var estimator: RateEstimatorConfig?
    /// The retransmit gate's freeze budget. A NACK is honored iff SRTT +
    /// retransmit serialization still fit inside what remains of it,
    /// measured from the frame's last shard release. Derived as
    ///
    ///   budget = repairBudgetCadenceMultiplier × observedCadence
    ///            + repairBudgetJitterAllowanceNS
    ///
    /// where observedCadence is an EWMA (α = 1/8) of feedback-report
    /// inter-arrival clamped to the wire's 25–50 ms cadence, starting at
    /// 50 ms. The ask itself rides that cadence: it waits at most one
    /// cadence for its report plus one one-way trip, which 1.5× covers;
    /// the allowance covers both ends' scheduling jitter. At a 40 ms
    /// cadence the budget is 75 ms, inside the client's 250 ms assembler
    /// horizon, so an honored repair is still usable. Non-nil overrides
    /// the derivation (tests, ops).
    public var repairFreezeBudgetOverrideNS: UInt64?
    /// The derived budget's cadence multiplier.
    public var repairBudgetCadenceMultiplier: Double
    /// The derived budget's scheduling-jitter allowance.
    public var repairBudgetJitterAllowanceNS: UInt64
    /// Bounds on the opening-IDR exemption: until a frame has plausibly
    /// completed at the client, the last IDR stays repairable regardless
    /// of the freeze budget (on black glass a late repair beats a later
    /// IDR). Capped by honored asks and bytes so it cannot amplify
    /// congestion.
    public var openingRepairMaxAttempts: Int
    public var openingRepairMaxBytes: Int
    /// The repair store's retention window and byte cap, passed through
    /// to VideoChannel.
    public var repairRetentionNS: UInt64
    public var repairStoreByteCap: Int
    /// Hard fresh-video queue budgets, checked before encode; a rate fall
    /// re-prices the existing queue against the same budget. Clean
    /// defaults to 50 ms; impaired may spend more on FEC/repair but is
    /// clamped to 100 ms so a capacity cliff never becomes a stale tail.
    public var cleanVideoQueueBudgetNS: UInt64
    public var impairedVideoQueueBudgetNS: UInt64
    /// A repair still queued after this interval is no longer useful to
    /// the bounded client assembler and expires before transmit.
    public var repairQueueUsefulnessNS: UInt64
    /// How long a committed host IDR suppresses older-named client 0x10
    /// retries as "already answered". Storm control for an in-flight
    /// offer, not delivery proof: it matches the client's 500 ms
    /// `IdrRequester` retry so a wholly lost recovery IDR re-arms on the
    /// next episode tick.
    public var clientIdrOfferInFlightNS: UInt64

    public init(
        crypto: SessionCryptoMode,
        rateBitsPerSecond: Int,
        regime: FecRegime = .clean,
        pacerQuantumNS: UInt64 = 1_000_000,
        beaconIntervalNS: UInt64 = 1_000_000_000,
        path: PathValidatorConfig = PathValidatorConfig(),
        arq: ArqConfig = ArqConfig(),
        allowedClientStaticPublicKeys: [[UInt8]]? = nil,
        handshakeGate: HandshakeGate.Config = HandshakeGate.Config(),
        capabilities: Capabilities = .wireDefault,
        lifecycle: SessionMachineConfig = SessionMachineConfig(),
        estimator: RateEstimatorConfig? = nil,
        repairFreezeBudgetOverrideNS: UInt64? = nil,
        repairBudgetCadenceMultiplier: Double = 1.5,
        repairBudgetJitterAllowanceNS: UInt64 = 15_000_000,
        openingRepairMaxAttempts: Int = 4,
        openingRepairMaxBytes: Int = 2 << 20,
        repairRetentionNS: UInt64 = 4_000_000_000,
        repairStoreByteCap: Int = 16 << 20,
        cleanVideoQueueBudgetNS: UInt64 = 50_000_000,
        impairedVideoQueueBudgetNS: UInt64 = 100_000_000,
        repairQueueUsefulnessNS: UInt64 = 100_000_000,
        clientIdrOfferInFlightNS: UInt64 = 500_000_000
    ) {
        self.crypto = crypto
        self.rateBitsPerSecond = rateBitsPerSecond
        self.regime = regime
        self.pacerQuantumNS = pacerQuantumNS
        self.beaconIntervalNS = beaconIntervalNS
        self.path = path
        self.arq = arq
        self.allowedClientStaticPublicKeys = allowedClientStaticPublicKeys
        self.handshakeGate = handshakeGate
        self.capabilities = capabilities
        self.lifecycle = lifecycle
        self.estimator = estimator
        self.repairFreezeBudgetOverrideNS = repairFreezeBudgetOverrideNS
        self.repairBudgetCadenceMultiplier = repairBudgetCadenceMultiplier
        self.repairBudgetJitterAllowanceNS = repairBudgetJitterAllowanceNS
        self.openingRepairMaxAttempts = openingRepairMaxAttempts
        self.openingRepairMaxBytes = openingRepairMaxBytes
        self.repairRetentionNS = repairRetentionNS
        self.repairStoreByteCap = repairStoreByteCap
        let boundedCleanBudget = min(
            max(cleanVideoQueueBudgetNS, 1_000_000), 100_000_000
        )
        self.cleanVideoQueueBudgetNS = boundedCleanBudget
        self.impairedVideoQueueBudgetNS = min(
            max(impairedVideoQueueBudgetNS, boundedCleanBudget),
            100_000_000
        )
        self.repairQueueUsefulnessNS = repairQueueUsefulnessNS
        self.clientIdrOfferInFlightNS = clientIdrOfferInFlightNS
    }
}

/// What the caller must know about. Values, not callbacks — the loop
/// executes/logs them in order (the PathValidator precedent).
public enum SessionEvent: Equatable, Sendable {
    /// The Noise handshake completed; the transport is live. The key is
    /// the client's authenticated static — the identity pairing checks.
    case handshakeCompleted(remoteStaticPublicKey: [UInt8])
    /// The host answered an un-cookied message 1 with a stateless
    /// RetryChallenge (0x13) because require-cookie mode is engaged. No
    /// Noise state was allocated.
    case handshakeChallenged
    /// Require-cookie mode flipped: `true` = the msg1 rate crossed the
    /// enter threshold; `false` = pressure cleared past the exit threshold.
    case handshakeCookieModeChanged(requireCookie: Bool)
    case beaconSent(beaconSeq: UInt32)
    /// One echo consumed: one raw offset/RTT sample (the client filters;
    /// the host keeps the min-RTT-gated estimate for logs).
    case beaconEchoAccepted(
        beaconSeq: UInt32,
        offsetMicroseconds: Int64,
        rttMicroseconds: Int64
    )
    /// A client 0x10 arrived; `takeFreshKeyframeRequest()` is now true.
    case idrRequested(IdrRequest)
    /// The ARQ delivered one reliable CTRL message — exactly once, in
    /// order within its group. The bytes start with its CTRL type byte.
    case reliableCtrl(group: ArqGroupId, message: [UInt8])
    /// A one-shot group this session sent is fully acknowledged.
    case reliableOneShotAcknowledged(ArqGroupId)
    /// The ARQ endpoint ignored (part of) an ingested payload. Some
    /// reasons are routine protocol weather (a duplicate from a
    /// retransmit crossing its ACK); the shell decides what to log.
    case arqIgnored(ArqIgnoreReason)
    case path(PathValidatorEvent)
    case dropped(SessionDropReason)
    /// An outbound build step refused (seal before establishment, a
    /// budget breach) — loud, because control sends must never fail
    /// silently, but never fatal to the session.
    case sendFailed(String)
    /// The capability exchange settled; this is the agreed intersection.
    case capabilitiesAgreed(Capabilities)
    /// The peer's declaration produced an unworkable intersection (no
    /// common video codec / chroma mode) — the typed teardown follows
    /// in the same event batch.
    case capabilitiesFailed(String)
    /// The client answered our outstanding renegotiation proposal
    /// (0x12). On accept the operative datagram ceiling already moved;
    /// apply at the next IDR boundary.
    case capabilityUpdateAcknowledged(accepted: Bool)
    /// A ModeTransition (0x09) left on the reliable stream (ACTIVE⇄IDLE).
    case modeTransitionSent(SessionWireMode)
    /// A typed SessionTeardown (0x0A) left on the reliable stream.
    case teardownSent(SessionTeardownReason)
    /// The lifecycle machine changed state (wire modes and the local
    /// FROZEN/RECOVERY overlay both surface here).
    case lifecycleChanged(SessionState)
    /// The session reached `closed`: a teardown either way, or the
    /// 30 s liveness timeout (which sends nothing — the peer that
    /// would read the message is the one that died).
    case sessionClosed(SessionCloseReason)
    /// A client input event (0x16), delivered exactly once, in order. The
    /// shell injects it and reports back via `noteInputInjected`;
    /// `receivedAtMicroseconds` is the carrying datagram's host-µs arrival
    /// (the echo tuple's rx stamp). The machine's pre-arm already ran: a
    /// keypress in IDLE is the WAKE; one during FROZEN persists until
    /// RECOVERY's IDR consumes it.
    case inputReceived(InputEvent, receivedAtMicroseconds: UInt64)
    /// The estimator moved the pacer rate (feedback evidence or an
    /// IdrPacing policy); the pacer is already re-capped.
    case rateChanged(bitsPerSecond: Int, reason: RateChangeReason)
    /// The fall-repricing purge fired: a genuine fall left queued
    /// video that would serialize past the backlog threshold at the
    /// new rate — dropped from the pacer, fresh IDR armed through the
    /// coalesced latch. `staleWireMs` is the wire time the purged
    /// bytes would have occupied at the new rate.
    case videoBacklogPurged(datagrams: Int, bytes: Int, staleWireMs: Int)
    /// A client NACK passed the retransmit gate — `shards` repair
    /// datagrams are enqueued (videoTail class; seqs at release).
    case repairEnqueued(frame: FrameNumber, shards: Int)
    /// A client NACK was refused. `.budgetExceeded`/`.unavailable` send an
    /// explicit refusal (the client's recovery episode owns the IDR
    /// alternative); `.olderThanIdr` refuses silently (a newer IDR already
    /// heals); `.alreadyRepaired` is the one-attempt rule.
    case nackJudgedStale(frame: FrameNumber, reason: NackStaleReason)
    /// The estimator stepped the FEC regime; the channel's packetizing
    /// seam is already switched.
    case fecRegimeChanged(FecRegime)
    /// A client 0x18 asked for a routing flip (only when hostAudioRouting
    /// was agreed). The shell flips the audio leaf and reports back via
    /// `noteAudioRoutingApplied`, which emits the 0x19 status.
    case audioRoutingRequested(HostAudioRoutingMode)
    /// An applied posture left as a 0x19 status (at capability agreement
    /// and after every applied flip).
    case audioRoutingStatusSent(HostAudioRoutingMode)
    /// A 0x25 track-state announcement left on the reliable stream (gate
    /// close, still-quiet check-in, or wake).
    case audioTrackStateSent(AudioTrackState.State)
    /// A 0x26 video posture announcement left on the reliable stream
    /// (a backoff step, or the wake back to active).
    case videoPostureStateSent(VideoPostureState)
    /// A client 0x1A clipboard set, delivered exactly once, in order (only
    /// when clipboardText was agreed). The sync book is already pre-armed
    /// against this apply's OS echo; the shell applies it through the
    /// clipboard leaf and reports changes via `noteHostClipboardChanged`.
    case clipboardSetReceived(text: String)
    /// A host clipboard change left as a 0x1B announce (byte count only —
    /// payloads are never logged).
    case clipboardAnnounceSent(byteCount: Int)
    /// A leaf-reported clipboard change was judged and not announced.
    case clipboardAnnounceSuppressed(ClipboardSuppressReason)
    /// The cursor shape left as a 0x24 (pixel byte count only — pixels are
    /// never logged; a hidden announce carries none).
    case cursorShapeSent(pixelByteCount: Int, hidden: Bool)
    /// An eye-reported cursor shape was judged and not sent.
    case cursorShapeSuppressed(CursorSuppressReason)
    /// One decoded bulk message off chan 8's ordered stream, exactly once
    /// (only when bulkTransfer was agreed). The shell feeds it to the
    /// BulkReceiveShell, whose replies come back through `sendBulk`.
    case bulkMessageReceived(BulkMessage)
    /// A sha-verified clipboard image arrived over the bulk channel (only
    /// when keys 10 ∧ 12 were agreed); the sync book is already pre-armed
    /// against the apply's OS echo. Payload bytes appear here and never in
    /// logs.
    case clipboardImageReceived(data: [UInt8], mime: String)
    /// A host image copy left as bulk cargo (byte count only).
    case clipboardImageShareStarted(byteCount: Int)
    /// The client verified the digest — the image landed.
    case clipboardImageShareCompleted(byteCount: Int)
    /// An image share died; `byRemote` says whose abort it was (a remote
    /// decline/busy is routine — best-effort, latest wins).
    case clipboardImageShareAborted(
        reason: BulkAbortReason, byRemote: Bool
    )
    /// An admitted incoming image died before landing; nothing applied.
    case clipboardImageReceiveAborted(
        reason: BulkAbortReason, byRemote: Bool
    )
    /// A leaf-reported image copy was judged and not shared.
    case clipboardImageSuppressed(ClipboardImageSuppressReason)
    /// Incoming image cargo was refused; the typed abort is already queued.
    case clipboardImageRefused(ClipboardImageRefuseReason)
    /// The peer broke the bulk state machine inside the
    /// clipboard lane (the abort is already queued).
    case clipboardImageViolation(BulkTransferViolation)
}

/// Why a leaf-reported host clipboard change did not become a 0x1B.
/// Counted and surfaced, never thrown.
public enum ClipboardSuppressReason: Equatable, Sendable {
    /// The OS reporting our own client-set apply back — the boomerang
    /// the sync book exists to stop.
    case loopEcho
    /// Identical to the last announce — the client already holds it.
    case duplicate
    /// Past the 65,536-byte v1 ceiling — routine weather (a huge copy
    /// on the host), suppressed rather than erred.
    case overBudget
}

/// Why an eye-reported cursor shape was not sent.
public enum CursorSuppressReason: Equatable, Sendable {
    /// Identical to the last sent shape — the client already wears it.
    case duplicate
    /// The shape breaks the wire contract (an over-ceiling crop, a
    /// hostile geometry) — suppressed and counted, the client keeps
    /// the previous shape.
    case overBudget
}

/// Why a NACK did not produce a retransmit.
public enum NackStaleReason: Equatable, Sendable {
    /// The frame is older than the last IDR, whose decode chain no longer
    /// references it (the IDR itself stays repairable).
    case olderThanIdr
    /// SRTT + retransmit serialization no longer fit the remaining
    /// freeze budget (or no RTT evidence exists to promise they do).
    case budgetExceeded
    /// The store no longer holds anything the NACK names (evicted
    /// past the retention window, or indices the frame never had).
    case unavailable
    /// Every named shard already rode its one retransmit.
    case alreadyRepaired
    /// FROZEN/closed: datagram sends, retransmits included, are suppressed.
    case sendsSuppressed
}

/// Why the estimator moved the rate (the live gate's evidence axis).
public enum RateChangeReason: Equatable, Sendable {
    /// Queuing-delay inflation over the baseline (rung 2).
    case overuse
    /// Post-arrival loss over the threshold (rung 3).
    case loss
    /// Clean windows + fresh delivery evidence: ≤10%/s toward ceiling.
    case evidence
    /// A machine-demanded IDR pacing policy was applied.
    case idrPacing(IdrPacing)
    /// NACK-evidenced loss FEC could not absorb (rung 3).
    case postFecLoss
}

/// Why an inbound datagram went no further. Counted and surfaced, never
/// thrown — hostile bytes must not unwind the receive loop.
public enum SessionDropReason: Equatable, Sendable {
    case malformedEnvelope
    case reservedChannel(UInt8)
    /// Payload traffic before the handshake completed (carries the
    /// channel). In Noise mode only bare message 1 is admissible first.
    case notEstablished(UInt8)
    case unsealFailed(UInt8)
    case malformedCtrl
    case unexpectedCtrlType(UInt8)
    case unhandledChannel(UInt8)
    case handshakeFailed(String)
    case duplicateConnectionIdTlv
    /// A conn-id TLV naming some other session, refused before the AEAD.
    case foreignConnectionId
    /// A message 1 beyond the HandshakeGate budget, dropped unread before
    /// any Noise state was allocated.
    case handshakeThrottled
    /// A RetryHandshake1 (0x14) whose cookie did not verify (spoofed,
    /// stale or replayed), dropped before any Noise.
    case handshakeCookieInvalid
    /// A verbatim repeat of the answered message 1 from a tuple other
    /// than the one it was answered on: message 2 goes only to the
    /// tuple that asked, so a replayer cannot aim it elsewhere.
    case handshakeRepeatOffPath
    /// A BeaconEcho naming no beacon still awaiting its echo, or whose
    /// round trip is implausible against the host's own t1: no sample.
    case beaconEchoUnmatched
    /// A chan-3 payload FeedbackReport.decode refused. Still counted as
    /// media-path evidence (an authenticated arrival) but never fed to the
    /// estimator.
    case malformedFeedback
    /// A 0x18 routing request without hostAudioRouting agreed — the peer
    /// used a capability it never negotiated. Dropped loud, never fatal.
    case audioRoutingNotNegotiated
    /// A 0x1A clipboard set without clipboardText agreed. Dropped loud,
    /// never fatal.
    case clipboardNotNegotiated
    /// A chan-8 datagram without bulkTransfer (key 11) agreed. Dropped
    /// loud, never fatal.
    case bulkNotNegotiated
    /// A chan-8 ARQ-delivered message that failed BulkMessage.decode
    /// (outside the 0x1C–0x21 sextet and the 0x22 marker, or hostile
    /// interior bytes).
    case malformedBulk
    /// A 0x22 clipboard-image cargo marker without the image gate (keys
    /// 10 ∧ 12) agreed. Dropped loud, never fatal.
    case clipboardImagesNotNegotiated
}

public enum SessionError: Error, Equatable, Sendable {
    /// Video cannot flow before the transport exists.
    case notEstablished
    /// A prepared frame was committed out of the video producer's serial
    /// order. The executable has one video producer, so this is a caller bug.
    case staleVideoPreparation
    /// Bulk sends are legal only when key 11 survived intersection.
    case bulkNotNegotiated
}

/// Where the estimator's send ledger takes its timestamp: at pacer
/// release (sans-IO tests, immediate sinks), or once the kernel accepts
/// the datagram (the Linux UDP shell).
public enum SessionSendAccounting: Equatable, Sendable {
    case pacerRelease
    case socketConfirmed
}

/// A short-lived snapshot for off-lock RS-FEC preparation. It reserves no
/// sequence or Noise state; only `commitPreparedVideoFrame` advances either.
public struct SessionVideoFramePreparationContext: Sendable {
    fileprivate let frameNumber: FrameNumber
    fileprivate let lastInputSeq: UInt32?
    fileprivate let channelConfig: VideoFramePreparationConfig
}

public struct SessionCounters: Equatable, Sendable {
    public var datagramsReceived = 0
    public var dropped = 0
    public var unsealFailures = 0
    /// Reliable sends refused with `ArqSendError.queueFull` on the CTRL
    /// and bulk endpoints: the peer stopped acknowledging long enough to
    /// fill a group's segment bound. Never fatal; see `enqueueReliable`.
    public var ctrlQueueFullRefusals = 0
    public var bulkQueueFullRefusals = 0
    public var beaconsSent = 0
    public var beaconEchoes = 0
    public var idrRequests = 0
    /// Client 0x10 retries naming damage older than a host IDR still inside
    /// its in-flight offer window. Encode-time is not delivery proof; after
    /// the window a continuing episode may re-arm.
    public var idrRequestsSupersededByKeyframe = 0
    /// Ingested ARQ bytes the endpoint refused or deduplicated.
    public var arqIgnored = 0
    /// Sealed CTRL datagrams carrying ARQ frames, both fresh and
    /// retransmit — the loss-gate's retransmission evidence.
    public var arqDatagramsSent = 0
    /// Chan 3 arrivals (parsed or not — any authenticated arrival is
    /// media-path evidence for the blackout detector).
    public var feedbackDatagrams = 0
    /// Chan 3 payloads that decoded and fed the estimator.
    public var feedbackReportsParsed = 0
    /// Chan 3 payloads that failed FeedbackReport.decode (counted, never
    /// fatal; they carry no estimator evidence).
    public var feedbackReportsMalformed = 0
    /// Estimator-driven pacer rate moves (both directions).
    public var rateChanges = 0
    /// Fall-repricing purges: falls whose queued video was repriced
    /// past the backlog threshold and dropped (IDR armed each time).
    public var fallPurges = 0
    /// Video bytes those purges dropped before they became stale wire.
    public var fallPurgedVideoBytes = 0
    /// Entire, not-yet-started fresh frames shed at the socket seam under
    /// sustained kernel pressure.
    public var kernelPressureShedFrames = 0
    public var kernelPressureShedDatagrams = 0
    public var kernelPressureShedBytes = 0
    /// Message 1s the HandshakeGate refused.
    public var handshakesThrottled = 0
    /// RetryChallenges (0x13) minted under flood: one HMAC and a reply
    /// smaller than the request, no Noise, no per-client state.
    public var handshakeChallengesMinted = 0
    /// RetryHandshake1s (0x14) whose cookie verified.
    public var handshakeCookiesVerified = 0
    /// RetryHandshake1s whose cookie did NOT verify (spoof/replay).
    public var handshakeCookiesRejected = 0
    /// Verbatim repeats of the answered message 1 (the client's
    /// retransmit timer) answered with the same message 2 while the
    /// initiator had not yet proved key possession.
    public var handshakeMessage2Resends = 0
    /// Newer message 1s that authenticated while this session's
    /// handshake was still unconfirmed, handed to the shell to replace it.
    public var handshakesSuperseded = 0
    /// Video frames the lifecycle machine refused to put on the wire
    /// (FROZEN's freezeDatagramSends, or a closed session).
    public var videoFramesSuppressed = 0
    /// Encoded frames too large for one FEC group (the GF(2⁸) 255-shard
    /// block), dropped with the keyframe latch armed instead of thrown.
    public var videoFramesUnprotectable = 0
    /// ModeTransitions emitted.
    public var modeTransitionsSent = 0
    /// Client input events delivered off the reliable stream.
    public var inputEventsReceived = 0
    /// (seq, rx, inject) tuples sent back in 0x17 echo messages.
    public var inputEchoTuplesSent = 0
    /// 5 ms Opus packets accepted onto the wire.
    public var audioPacketsIngested = 0
    /// Audio-channel datagrams sealed and enqueued: data shards +
    /// parity (6 per completed 4+2 group).
    public var audioDatagramsEnqueued = 0
    /// Completed 4+2 audio FEC groups.
    public var audioGroupsCompleted: UInt64 = 0
    /// Audio FEC groups closed without parity because the Opus packet
    /// size changed mid-group (a bitrate step under hard CBR).
    public var audioGroupsAbandoned: UInt64 = 0
    /// Audio packets refused because the session is closed. FROZEN and
    /// IDLE never count here: audio is the path probe and keeps flowing.
    public var audioPacketsSuppressed = 0
    /// NACK entries consumed from parsed feedback reports.
    public var nackEntriesReceived = 0
    /// NACK entries that passed the gate and enqueued repairs.
    public var nacksHonored = 0
    /// NACK entries refused by the staleness ruling (any reason).
    public var nacksJudgedStale = 0
    /// Repair datagrams enqueued (fresh seqs on videoTail).
    public var repairDatagramsEnqueued = 0
    /// Explicit 0x23 repair refusals sent (stale-budget, superseded,
    /// unknown-frame); FROZEN/closed and already-repaired stay silent.
    public var repairRefusalsSent = 0
    /// NACKs honored under the opening-IDR exemption.
    public var openingExemptRepairsHonored = 0
    /// FEC regime steps applied to the packetizing seam.
    public var fecRegimeSteps = 0
    /// 0x18 routing requests delivered (past the capability gate).
    public var audioRoutingRequestsReceived = 0
    /// 0x19 posture statuses sent.
    public var audioRoutingStatusesSent = 0
    /// 0x1A clipboard sets delivered (past the capability gate).
    public var clipboardSetsReceived = 0
    /// 0x1B clipboard announces sent.
    public var clipboardAnnouncesSent = 0
    /// Leaf-reported changes the book/ceiling suppressed.
    public var clipboardAnnouncesSuppressed = 0
    /// 0x24 cursor shapes sent.
    public var cursorShapesSent = 0
    /// Eye-reported shapes the dedupe/ceiling suppressed.
    public var cursorShapesSuppressed = 0
    /// Decoded bulk messages delivered off chan 8's ordered stream.
    public var bulkMessagesReceived = 0
    /// Sealed chan-8 datagrams carrying bulk ARQ frames, fresh and
    /// retransmit alike.
    public var bulkArqDatagramsSent = 0

    public init() {}
}

/// A message 1 that authenticated while a session's handshake was
/// answered but unconfirmed. The shell hands it to a fresh session
/// (`completeSupersedingHandshake`), which answers it without re-running
/// the gate or re-reading message 1, and drops the unconfirmed one.
public struct SupersedingHandshake: Sendable {
    public let clientTuple: FourTuple
    public let message1: [UInt8]
    let responder: NoiseSession
    let handshakeGate: HandshakeGate
}

public final class Session {
    public enum Phase: Equatable, Sendable {
        case awaitingHandshake
        case established
    }

    public let config: SessionConfig
    /// Minted at init; rides every outbound datagram as TLV 0x01.
    public let connectionId: ConnectionId
    /// The path decision machine; public for the loop's routing queries
    /// and tests.
    public private(set) var validator: PathValidator
    public var phase: Phase {
        lifecycleLane.isEstablished ? .established : .awaitingHandshake
    }
    public var clock: SessionClockStats { beaconClock.stats }
    public private(set) var counters = SessionCounters()

    /// The completed handshake's transcript hash — the sid pairing binds
    /// to. Nil before establishment and in passthrough mode.
    public var handshakeHash: [UInt8]? { transport?.handshakeHash }

    private var channel: VideoChannel!
    /// The audio framer: 5 ms Opus packets → 4+2 RS groups → chan-1
    /// envelopes. The session owns seal and enqueue; the framer owns the
    /// audio seq/packet numbering.
    private var audio: AudioFramer!
    /// Nil until the handshake completes; always nil in passthrough mode.
    private var transport: NoiseTransport?

    /// Last frame admitted to packetization (nil before the first).
    public private(set) var lastAdmittedVideoFrameNumber: FrameNumber?
    private var nextVideoFrameNumber: FrameNumber {
        lastAdmittedVideoFrameNumber?.next ?? FrameNumber(rawValue: 0)
    }

    /// The reliable CTRL sublayer. Its instants are µs derived from the
    /// loop's monotonic `now` (ns / 1000).
    private var ctrlArqLane: SessionArqLane
    /// The bulk channel's own ARQ endpoint: chan 8 never shares the CTRL
    /// stream, so a file cannot head-of-line-block a keystroke. Nil when
    /// the consent toggle left key 11 undeclared.
    private var bulkArqLane: SessionArqLane?
    /// Set once a peer poisoned an ordered stream and the teardown left.
    private var orderedStreamPoisoned = false

    /// Message-1 admissions, consulted before any handshake allocation.
    private var handshakeGate: HandshakeGate
    /// Whether the initiator has proved it holds the session keys (an
    /// authenticated transport datagram arrived). Until then the session
    /// is answered but uncommitted: a verbatim repeat of its message 1
    /// gets the same message 2 again, and a newer message 1 that
    /// authenticates supersedes it (`takeSupersedingHandshake`). Noise
    /// IK message 1 carries no freshness, so answering one proves
    /// nothing about who sent it. Always true in passthrough mode.
    public private(set) var isPeerConfirmed: Bool
    /// The answered handshake while unconfirmed: message 1 as received
    /// and message 2's CTRL body, for verbatim repeats.
    private var answeredHandshake: (message1: [UInt8], message2Body: [UInt8])?
    /// The message 1 this session answered; nil before its handshake and
    /// once the initiator is confirmed.
    public var answeredMessage1: [UInt8]? { answeredHandshake?.message1 }
    private var supersedingHandshake: SupersedingHandshake?
    /// Whether the flood dial currently demands a retry cookie.
    public var handshakeCookieMode: Bool { handshakeGate.cookieMode }

    private var beaconClock: SessionBeaconClock
    private var freshKeyframes = SessionFreshKeyframeBook()
    public private(set) var freshKeyframeDemandCounts =
        FreshKeyframeDemandCounts()
    private var repairBudget = SessionRepairBudgetBook()
    /// Injected `now` when the channel last advanced `lastKeyframeNumber`.
    /// Bounds how long older-named 0x10 retries may coalesce against that
    /// offer; never treated as proof the client accepted an IRAP.
    private var lastKeyframeOfferedAtNS: UInt64?

    // MARK: Lifecycle + capabilities state

    /// The lifecycle machine, its projected timer, and FROZEN's local video
    /// admission posture. External lifecycle effects stay in Session.
    private var lifecycleLane: SessionLifecycleLane
    /// The capability negotiation machine, host role.
    private var negotiator: CapabilityNegotiator
    /// The congestion estimator: send ledger + delivery/queuing-delay/loss
    /// evidence → the pacer rate, RECOVERY verdicts and IdrPacing numbers.
    private let estimator: RateEstimator
    /// The `now` of the pump pass draining the pacer — the send instant
    /// the estimator's ledger records (the sink closure has no clock).
    private var pumpNowNS: UInt64
    private let sendAccounting: SessionSendAccounting
    private var socketPending = SessionSocketPendingBook()

    // MARK: Input state

    /// The seq of the last input event the shell reported injected,
    /// stamped on every later video frame as TLV 0x03 so the client can
    /// measure input-to-photon. Nil until the first injection.
    public var lastInputSeq: UInt32? { inputEchoBook.lastInjectedSequence }
    /// Echo stamp and pending-tuples owner. `Session` retains reliable
    /// transport, counters, and events.
    private var inputEchoBook = SessionInputEchoBook()

    /// The lifecycle machine's state; nil before establishment.
    public var lifecycleState: SessionState? { lifecycleLane.state }
    /// The wire mode beneath any overlay; nil before establishment.
    public var wireMode: SessionWireMode? { lifecycleLane.wireMode }
    /// The agreed capability set; nil until the client's declaration
    /// lands (a client that sends none stays nil, which is not an error).
    public var agreedCapabilities: Capabilities? { negotiator.agreed }
    /// True when hostAudioRouting (key 9) survived the intersection.
    /// Gates 0x18 consumption and 0x19 emission.
    public var agreedHostAudioRouting: Bool {
        negotiator.agreed?.hostAudioRouting == true
    }
    /// True when audioQuietPosture (key 15) survived the intersection.
    /// The audio leg gates transmission only under this agreement; a
    /// legacy client keeps always-on audio, silence included.
    public var agreedAudioQuietPosture: Bool {
        negotiator.agreed?.audioQuietPosture == true
    }
    /// True when videoQuietPosture (key 16) survived the intersection;
    /// the keepalive backs off only under this agreement.
    public var agreedVideoQuietPosture: Bool {
        negotiator.agreed?.videoQuietPosture == true
    }
    /// True when clipboardText (key 10) survived the intersection. Gates
    /// 0x1A consumption and 0x1B emission.
    public var agreedClipboardText: Bool {
        negotiator.agreed?.clipboardText == true
    }
    /// True when bulkTransfer (key 11) survived the intersection. Gates
    /// chan-8 ingest and `sendBulk`; consent is the standing toggle that
    /// decided whether key 11 was declared.
    public var agreedBulkTransfer: Bool {
        negotiator.agreed?.bulkTransfer == true
    }
    /// True when the image gate (keys 10 ∧ 12) survived the
    /// intersection. Gates 0x22 consumption and image cargo emission.
    /// Key 11 is deliberately not consulted — the file-drop consent
    /// must not couple to the clipboard tier.
    public var agreedClipboardImages: Bool {
        negotiator.agreed?.clipboardImagesAgreed == true
    }
    /// True when cursorShape (key 13) survived the intersection. Gates
    /// 0x24 emission; only the direct eye declares the key.
    public var agreedCursorShape: Bool {
        negotiator.agreed?.cursorShape == true
    }

    /// The loop-prevention/dedupe book, shared by the 0x1A consume path
    /// (pre-arms echo suppression) and `noteHostClipboardChanged`. Images
    /// key into the same book (0xFF ‖ sha256, disjoint from any UTF-8
    /// text), so cross-modal moves stay honest.
    private var clipboardBook = ClipboardSyncBook()
    /// The last 0x24 sent — the dedupe slot (nil until the first send, so
    /// a fresh session passes the eye's standing shape through).
    private var lastSentCursorShape: CursorShape?

    /// The clipboard-image lane (memory-backed bulk cargo). Inert unless
    /// the image gate (keys 10 ∧ 12) agreed: every entry point checks.
    private var clipboardImageChannel = ClipboardImageChannel()
    /// The injected generator: the conn-id, path-challenge tokens and
    /// image-cargo ids all draw from this one stream (see `SharedRng`).
    private var rng: SharedRng

    /// The image lane's own books (share/apply/refuse verdicts).
    public var clipboardImageCounters: ClipboardImageChannelCounters {
        clipboardImageChannel.counters
    }

    /// - Parameters:
    ///   - clientTuple: the peer's 4-tuple at session start — the
    ///     validator's initial (trusted) path: where message 1 arrived
    ///     from, or the fixed peer in passthrough mode.
    ///   - send: receives every outbound datagram in pacer order. The
    ///     loop maps `pacerClass` → TOS and `destination` (nil = the
    ///     primary path) → the socket call.
    public init(
        config: SessionConfig,
        clientTuple: FourTuple,
        now: UInt64,
        rng: some RandomNumberGenerator,
        sendAccounting: SessionSendAccounting = .pacerRelease,
        send: @escaping (VideoChannelDatagram) -> Void
    ) {
        var rng = SharedRng(rng)
        self.config = config
        self.connectionId = ConnectionId.random(using: &rng)
        // Every session datagram carries the conn-id TLV. Give that carrier
        // ceiling to the endpoint before it owns any segments, so ARQ packs
        // once and the session never needs to re-cut its output.
        var arqConfig = config.arq
        arqConfig.maxDatagramPayloadByteCount = min(
            arqConfig.maxDatagramPayloadByteCount,
            WireBudget.maxConnectionIdTaggedPlaintextByteCount
        )
        self.ctrlArqLane = SessionArqLane(
            channel: .ctrl, config: arqConfig
        )
        // The bulk endpoint exists exactly when something declared chan-8
        // carriage: key 11 (file-drop consent) or key 12 (clipboard
        // images). Same clamped config as CTRL: the default 262,144 B
        // message budget clears a max chunk message (17 B + 128 KiB) 2×.
        self.bulkArqLane = (config.capabilities.bulkTransfer
            || config.capabilities.clipboardImages)
            ? SessionArqLane(channel: .bulkTransfer, config: arqConfig)
            : nil
        self.rng = rng
        self.estimator = RateEstimator(
            config: config.estimator
                ?? RateEstimatorConfig(
                    ceilingBitsPerSecond: config.rateBitsPerSecond
                ),
            now: now
        )
        self.pumpNowNS = now
        self.sendAccounting = sendAccounting
        self.handshakeGate = HandshakeGate(config: config.handshakeGate)
        self.beaconClock = SessionBeaconClock(
            intervalNanoseconds: config.beaconIntervalNS
        )
        self.negotiator = CapabilityNegotiator(
            role: .host, local: config.capabilities
        )
        let lifecycleEstablishedAt: UInt64?
        switch config.crypto {
        case .noise: lifecycleEstablishedAt = nil
        case .testPassthrough: lifecycleEstablishedAt = now
        }
        self.isPeerConfirmed = lifecycleEstablishedAt != nil
        self.lifecycleLane = SessionLifecycleLane(
            config: config.lifecycle,
            establishedAtNanoseconds: lifecycleEstablishedAt
        )
        self.validator = PathValidator(
            connectionId: connectionId,
            initialPath: clientTuple,
            now: now,
            config: config.path,
            rng: rng
        )
        let sealTagByteCount: Int
        switch config.crypto {
        case .noise:
            sealTagByteCount = WireBudget.aeadTagByteCount
        case .testPassthrough:
            sealTagByteCount = 0
            // No handshake to wait for; the session-start beacon (and
            // the capability declaration) leave on the first `advance`.
            self.beaconClock.armSessionStart(at: now)
        }
        self.channel = VideoChannel(
            config: VideoChannelConfig(
                channel: .videoActive,
                regime: config.regime,
                rateBitsPerSecond: config.rateBitsPerSecond,
                pacerQuantumNS: config.pacerQuantumNS,
                connectionId: connectionId,
                repairRetentionNS: config.repairRetentionNS,
                repairStoreByteCap: config.repairStoreByteCap,
                repairQueueUsefulnessNS: config.repairQueueUsefulnessNS
            ),
            now: now,
            seal: { [unowned self] plaintext, aad, envelope in
                try self.sealPayload(plaintext, aad: aad, envelope: envelope)
            },
            sealTagByteCount: sealTagByteCount,
            // The estimator's send ledger taps the sink, recording (channel,
            // seq) → (instant, wire bytes) so dispersion samples match their
            // trains.
            send: { [unowned self] datagram in
                switch self.sendAccounting {
                case .pacerRelease:
                    self.noteSent(datagram, now: self.pumpNowNS)
                case .socketConfirmed:
                    self.noteSocketPending(datagram)
                }
                send(datagram)
            }
        )
        self.audio = AudioFramer(
            config: AudioFramerConfig(connectionId: connectionId)
        )
    }

    // MARK: Inbound

    /// Feeds one raw received datagram. Never throws: hostile bytes
    /// become `.dropped` events (the demux doctrine).
    public func receive(
        _ datagram: ArraySlice<UInt8>,
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        counters.datagramsReceived += 1
        if phase == .awaitingHandshake {
            return receiveBeforeHandshake(
                datagram, from: tuple,
                now: now, hostMicroseconds: hostMicroseconds
            )
        }

        // Established: open against the exact received header bytes.
        // Channel and conn-id refusals happen before the AEAD is paid.
        var claimed: ConnectionId?
        let envelope: Envelope
        let plaintext: [UInt8]
        do {
            (envelope, plaintext) = try Envelope.openDatagram(datagram) {
                envelope, wirePayload, aad in
                claimed = try admitHeader(envelope)
                try admitEstablishedHeader(envelope, claimed: claimed)
                do {
                    return try unsealPayload(
                        wirePayload, aad: aad, envelope: envelope
                    )
                } catch {
                    throw InboundRefusal(
                        .unsealFailed(envelope.channel.rawValue)
                    )
                }
            }
        } catch {
            // A handshake initiation is judged only once the AEAD has
            // refused it: a sealed CTRL datagram's first ciphertext byte
            // is 0x05 or 0x14 one time in 128, and the confirming
            // datagram must never be mistaken for a message 1.
            if !isPeerConfirmed,
               let initiation = Self.parseInitiation(datagram) {
                return receiveInitiationWhileUnconfirmed(
                    initiation, from: tuple,
                    now: now, hostMicroseconds: hostMicroseconds)
            }
            return [refuse(error)]
        }
        if !isPeerConfirmed {
            // Key possession proven: the session is committed.
            isPeerConfirmed = true
            answeredHandshake = nil
            supersedingHandshake = nil
        }

        // The demux trigger: only an authenticated arrival may
        // probe a new tuple. The conn-id TLV is readable by anyone who
        // saw one datagram, and the validator has one probe slot; the
        // AEAD, which does not depend on the source address, is what
        // proves the sender holds the session keys.
        var events = process(
            validator.datagramReceived(
                from: tuple,
                connectionId: claimed,
                byteCount: datagram.count,
                now: now
            ),
            now: now,
            hostMicroseconds: hostMicroseconds
        )

        switch envelope.channel {
        case .ctrl:
            // Authenticated CTRL is liveness/FROZEN-exit evidence, but not
            // the 350 ms detector's (1 Hz beacons cannot drive it).
            events += runLifecycle(
                .ctrlEvidence, now: now, hostMicroseconds: hostMicroseconds
            )
            events += dispatchCtrl(
                plaintext, from: tuple,
                now: now, hostMicroseconds: hostMicroseconds
            )
        case .feedback:
            counters.feedbackDatagrams += 1
            // The media-path proof stream feeds the blackout detector; a
            // malformed interior is still an arrival.
            events += runLifecycle(
                .mediaPathEvidence, now: now, hostMicroseconds: hostMicroseconds
            )
            events += ingestFeedback(
                plaintext, now: now, hostMicroseconds: hostMicroseconds
            )
        case .bulkTransfer:
            // Liveness evidence like CTRL (an authenticated arrival
            // proves the peer), deliberately NOT the 350 ms detector's.
            events += runLifecycle(
                .ctrlEvidence, now: now, hostMicroseconds: hostMicroseconds
            )
            // Chan-8 traffic outside both agreements (key 11 files, keys
            // 10∧12 images) uses a capability never negotiated: dropped
            // loud. Message-level routing separates the two lanes.
            guard agreedBulkTransfer || agreedClipboardImages,
                  bulkArqLane != nil else {
                counters.dropped += 1
                events.append(.dropped(.bulkNotNegotiated))
                return events
            }
            events += absorbBulkArq(
                bulkArqLane!.ingest(
                    plaintext[...], now: now
                ),
                now: now, hostMicroseconds: hostMicroseconds
            )
            events += serviceArqLane(
                .bulk,
                now: now, hostMicroseconds: hostMicroseconds
            )
        default:
            counters.dropped += 1
            events.append(.dropped(.unhandledChannel(envelope.channel.rawValue)))
        }
        return events
    }

    public func receive(
        _ datagram: [UInt8],
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        receive(datagram[...], from: tuple,
                now: now, hostMicroseconds: hostMicroseconds)
    }

    /// Why the header or the AEAD refused a datagram; `refuse` counts it.
    private struct InboundRefusal: Error {
        let reason: SessionDropReason
        init(_ reason: SessionDropReason) { self.reason = reason }
    }

    /// The header checks every phase applies before reading a payload:
    /// reserved channels never carry traffic, and at most one conn-id
    /// TLV may appear. Returns the claimed conn-id (nil when absent).
    private func admitHeader(_ envelope: Envelope) throws -> ConnectionId? {
        guard !envelope.channel.isReserved else {
            throw InboundRefusal(.reservedChannel(envelope.channel.rawValue))
        }
        do {
            return try ConnectionId.decode(extensions: envelope.extensions)
        } catch {
            throw InboundRefusal(.duplicateConnectionIdTlv)
        }
    }

    /// Channels an established session reads. Anything else, and a
    /// conn-id TLV naming another session, is refused before the AEAD is
    /// paid: a forged datagram there could only cost an open (and feed
    /// the transport's resync search) without carrying anything we act on.
    private static let readChannels: Set<ChannelId> =
        [.ctrl, .feedback, .bulkTransfer]

    private func admitEstablishedHeader(
        _ envelope: Envelope, claimed: ConnectionId?
    ) throws {
        guard Self.readChannels.contains(envelope.channel) else {
            throw InboundRefusal(.unhandledChannel(envelope.channel.rawValue))
        }
        guard claimed == nil || claimed == connectionId else {
            throw InboundRefusal(.foreignConnectionId)
        }
    }

    /// Counts a refused datagram and names why. An unseal failure has its
    /// own counter; everything else, including an undecodable envelope,
    /// is a drop.
    private func refuse(_ error: any Error) -> SessionEvent {
        guard let refusal = error as? InboundRefusal else {
            counters.dropped += 1
            return .dropped(.malformedEnvelope)
        }
        if case .unsealFailed = refusal.reason {
            counters.unsealFailures += 1
        } else {
            counters.dropped += 1
        }
        return .dropped(refusal.reason)
    }

    /// Pre-establishment demux: only a Noise message 1 (bare or
    /// cookie-bearing) is admissible; it is never sealed.
    private func receiveBeforeHandshake(
        _ datagram: ArraySlice<UInt8>,
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let envelope: Envelope
        let payload: ArraySlice<UInt8>
        do {
            (envelope, payload) = try Envelope.decode(datagram)
            _ = try admitHeader(envelope)
        } catch {
            return [refuse(error)]
        }
        guard case .noise(let hostStatic) = config.crypto else {
            counters.dropped += 1 // unreachable: passthrough never waits
            return [.dropped(.notEstablished(envelope.channel.rawValue))]
        }
        // Two admissible first words: a bare Noise message 1 (0x05) or a
        // RetryHandshake1 (0x14) echoing a cookie the host minted under
        // flood. Anything else is pre-establishment noise.
        let presentedCookie: ArraySlice<UInt8>?
        let message1: ArraySlice<UInt8>
        switch payload.first {
        case CtrlMessageType.noiseHandshake1:
            presentedCookie = nil
            message1 = payload.dropFirst()
        case CtrlMessageType.retryHandshake1:
            guard let resubmission = try? RetryHandshake1.decode(payload)
            else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            presentedCookie = resubmission.cookie[...]
            message1 = resubmission.message1[...]
        default:
            counters.dropped += 1
            return [.dropped(.notEstablished(envelope.channel.rawValue))]
        }

        return admitInitiation(
            presentedCookie: presentedCookie, message1: message1,
            from: tuple, hostStatic: hostStatic,
            now: now, hostMicroseconds: hostMicroseconds
        ) { responder in
            completeHandshake(
                responder: responder, message1: message1, from: tuple,
                now: now, hostMicroseconds: hostMicroseconds)
        }
    }

    /// The HandshakeGate's verdict on one message 1, executed: a stateless
    /// challenge under flood, a counted drop, or — admitted and
    /// authenticated — `onAuthenticated` with the responder that read it.
    private func admitInitiation(
        presentedCookie: ArraySlice<UInt8>?,
        message1: ArraySlice<UInt8>,
        from tuple: FourTuple,
        hostStatic: NoiseKeyPair,
        now: UInt64,
        hostMicroseconds: UInt64,
        onAuthenticated: (NoiseSession) -> [SessionEvent]
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        let decision = handshakeGate.admitMessage1(
            presentedCookie: presentedCookie,
            clientTuple: Self.cookieTuple(tuple),
            message1: message1,
            now: now
        )
        if let requireCookie = decision.cookieModeChangedTo {
            events.append(.handshakeCookieModeChanged(requireCookie: requireCookie))
        }
        switch decision.admission {
        case .admit:
            if presentedCookie != nil {
                counters.handshakeCookiesVerified += 1
            }
            switch authenticate(message1: message1, hostStatic: hostStatic) {
            case .success(let responder):
                events += onAuthenticated(responder)
            case .failure(let refusal):
                counters.dropped += 1
                events.append(.dropped(refusal.reason))
            }
        case .challenge(let cookie):
            counters.dropped += 1
            counters.handshakeChallengesMinted += 1
            // A stateless RetryChallenge (0x13) on the exact tuple the
            // message 1 arrived from — no Noise, no session state.
            do {
                try sendCtrl(
                    body: try RetryChallenge(cookie: cookie).encode(),
                    sealed: false,
                    destination: tuple,
                    now: now, hostMicroseconds: hostMicroseconds
                )
                events.append(.handshakeChallenged)
            } catch {
                events.append(.sendFailed(String(describing: error)))
            }
        case .drop(.throttled):
            counters.dropped += 1
            counters.handshakesThrottled += 1
            events.append(.dropped(.handshakeThrottled))
        case .drop(.cookieInvalid):
            counters.dropped += 1
            counters.handshakeCookiesRejected += 1
            events.append(.dropped(.handshakeCookieInvalid))
        }
        return events
    }

    /// Reads message 1 on fresh responder state — a failed one (bad
    /// version, wrong static, garbage) burns nothing — and applies the
    /// paired-set policy to the static it names.
    private func authenticate(
        message1: ArraySlice<UInt8>, hostStatic: NoiseKeyPair
    ) -> Result<NoiseSession, InboundRefusal> {
        var responder: NoiseSession
        do {
            responder = try NoiseSession(role: .responder, staticKeys: hostStatic)
            _ = try responder.readMessage1(message1)
        } catch {
            return .failure(InboundRefusal(
                .handshakeFailed(String(describing: error))))
        }
        if let allowed = config.allowedClientStaticPublicKeys,
           let remote = responder.remoteStaticPublicKey,
           !allowed.contains(remote) {
            return .failure(InboundRefusal(
                .handshakeFailed("client static not in the paired set")))
        }
        return .success(responder)
    }

    /// A handshake initiation reaching an answered, unconfirmed session. A
    /// verbatim repeat (the client's retransmit timer) gets the same
    /// message 2 again, on the path that asked. Any other message 1 goes
    /// through the gate and, if it authenticates, supersedes this session,
    /// so a replayed or abandoned handshake holds the host only until a
    /// real client dials.
    private func receiveInitiationWhileUnconfirmed(
        _ initiation: Initiation,
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard case .noise(let hostStatic) = config.crypto else { return [] }
        if let answered = answeredHandshake,
           initiation.message1.elementsEqual(answered.message1) {
            guard tuple == validator.primary.tuple else {
                counters.dropped += 1
                return [.dropped(.handshakeRepeatOffPath)]
            }
            do {
                try sendCtrl(
                    body: answered.message2Body, sealed: false,
                    now: now, hostMicroseconds: hostMicroseconds)
                counters.handshakeMessage2Resends += 1
                return []
            } catch {
                return [.sendFailed(String(describing: error))]
            }
        }
        return admitInitiation(
            presentedCookie: initiation.presentedCookie,
            message1: initiation.message1,
            from: tuple, hostStatic: hostStatic,
            now: now, hostMicroseconds: hostMicroseconds
        ) { responder in
            counters.handshakesSuperseded += 1
            supersedingHandshake = SupersedingHandshake(
                clientTuple: tuple, message1: Array(initiation.message1),
                responder: responder, handshakeGate: handshakeGate)
            return []
        }
    }

    /// The authenticated message 1 that should replace this unconfirmed
    /// session, once; nil when none arrived.
    public func takeSupersedingHandshake() -> SupersedingHandshake? {
        defer { supersedingHandshake = nil }
        return supersedingHandshake
    }

    /// Answers a superseding message 1 on this fresh session: the gate
    /// state carries over, and message 1 is not read again.
    public func completeSupersedingHandshake(
        _ superseding: SupersedingHandshake,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        precondition(phase == .awaitingHandshake,
                     "a superseding handshake needs a fresh session")
        handshakeGate = superseding.handshakeGate
        return completeHandshake(
            responder: superseding.responder,
            message1: superseding.message1[...],
            from: superseding.clientTuple,
            now: now, hostMicroseconds: hostMicroseconds)
    }

    /// A handshake initiation's carriage: a bare Noise message 1 (0x05)
    /// or a RetryHandshake1 (0x14) echoing a cookie.
    struct Initiation {
        var presentedCookie: ArraySlice<UInt8>?
        var message1: ArraySlice<UInt8>
    }

    static func parseInitiation(_ datagram: ArraySlice<UInt8>) -> Initiation? {
        guard let (envelope, payload) = try? Envelope.decode(datagram),
              envelope.channel == .ctrl else { return nil }
        switch payload.first {
        case CtrlMessageType.noiseHandshake1:
            return Initiation(presentedCookie: nil, message1: payload.dropFirst())
        case CtrlMessageType.retryHandshake1:
            guard let resubmission = try? RetryHandshake1.decode(payload)
            else { return nil }
            return Initiation(
                presentedCookie: resubmission.cookie[...],
                message1: resubmission.message1[...])
        default:
            return nil
        }
    }

    /// The Noise message 1 a handshake initiation carries (bare or
    /// cookie-bearing); nil for anything else. The listening shell keys
    /// its replay memory on it.
    public static func handshakeMessage1(in datagram: [UInt8]) -> [UInt8]? {
        parseInitiation(datagram[...]).map { Array($0.message1) }
    }

    // MARK: Video

    /// One encoded frame into the sealed, paced, conn-id-tagged stream.
    /// The session owns frame numbering (from 0). Throws
    /// `SessionError.notEstablished` before the transport exists, and
    /// whatever the packetize/seal path throws.
    @discardableResult
    public func ingestVideoFrame(
        _ annexB: [UInt8],
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        now: UInt64
    ) throws -> Int {
        try ingestVideoFrameBytes(
            annexB, captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, now: now)
    }

    /// Borrowed encoder-buffer ingress. The pointer is consumed
    /// synchronously and is never retained past this call.
    @discardableResult
    public func ingestVideoFrame(
        _ annexB: UnsafeBufferPointer<UInt8>,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        now: UInt64
    ) throws -> Int {
        try ingestVideoFrameBytes(
            annexB, captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, now: now)
    }

    private func ingestVideoFrameBytes<C>(
        _ annexB: C,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        now: UInt64
    ) throws -> Int
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        guard let context = try beginVideoFramePreparation(
            encodedByteCount: annexB.count
        ) else { return 0 }
        let prepared = try Self.prepareVideoFrame(
            annexB, isKeyframe: isKeyframe, context: context
        )
        return try commitPreparedVideoFrame(
            prepared,
            context: context,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            now: now
        )
    }

    /// Cheap locked half before RS-FEC. Suppression and the one-group
    /// ceiling are judged at this admission snapshot; no seq is consumed.
    public func beginVideoFramePreparation(
        encodedByteCount: Int
    ) throws -> SessionVideoFramePreparationContext? {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        // FROZEN (and closed): the encoder may keep producing, the wire
        // goes quiet. Suppressed frames are counted, never thrown.
        if lifecycleLane.videoSendsSuppressed {
            counters.videoFramesSuppressed += 1
            return nil
        }
        // A frame beyond one FEC group (the 255-shard GF(2⁸) block; the
        // fec field binds one group per frame number) is unshippable. It
        // is dropped with its frame number unconsumed (no numbering gap)
        // and a fresh IDR armed through the coalesced latch to re-anchor
        // whatever referenced it. The shell bounds the encoder's HRD
        // buffer by this ceiling, so the re-encode fits.
        let ceiling = channel.maxProtectableFrameByteCount(
            hasLastInputSeq: lastInputSeq != nil
        )
        guard encodedByteCount <= ceiling else {
            counters.videoFramesUnprotectable += 1
            freshKeyframes.arm(.unprotectableDrop)
            return nil
        }
        return SessionVideoFramePreparationContext(
            frameNumber: nextVideoFrameNumber,
            lastInputSeq: lastInputSeq,
            channelConfig: channel.preparationConfig(
                hasLastInputSeq: lastInputSeq != nil
            )
        )
    }

    /// Expensive pure half. The Linux shell calls this after releasing its
    /// broad Session lock so audio service remains schedulable during RS-FEC.
    public static func prepareVideoFrame<C>(
        _ annexB: C,
        isKeyframe: Bool,
        context: SessionVideoFramePreparationContext
    ) throws -> PreparedVideoFrame
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        try VideoChannel.prepareFrame(
            annexB, isKeyframe: isKeyframe, config: context.channelConfig
        )
    }

    /// Ordered locked half: pacer insertion, repair retention and
    /// frame-number advancement, one critical section with every other
    /// Session mutation. No seal runs here: chan-2 seqs and seals are
    /// assigned as `pump` releases each shard, so the first quantum can
    /// leave on the next pump. `interleave` is never called (nothing long
    /// runs here any more) and `isBorrowed` is not read; both stay only
    /// for source compatibility.
    @discardableResult
    public func commitPreparedVideoFrame(
        _ prepared: PreparedVideoFrame,
        context: SessionVideoFramePreparationContext,
        captureTimestampMicroseconds: UInt64,
        interleave: (() -> Void)? = nil,
        now: UInt64,
        isBorrowed: Bool = false
    ) throws -> Int {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        if lifecycleLane.videoSendsSuppressed {
            counters.videoFramesSuppressed += 1
            return 0
        }
        guard context.frameNumber == nextVideoFrameNumber else {
            throw SessionError.staleVideoPreparation
        }
        let shards = channel.ingestPrepared(
            prepared,
            frameNumber: context.frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            lastInputSeq: context.lastInputSeq,
            now: now
        )
        // The opening exemption's glass proxy needs the first
        // IDR's group size — "received everything through this group"
        // is the evidence that something plausibly decoded.
        if prepared.isKeyframe {
            repairBudget.noteOpeningIdr(shardCount: shards)
            lastKeyframeOfferedAtNS = now
        }
        lastAdmittedVideoFrameNumber = context.frameNumber
        return shards
    }

    // MARK: Audio

    /// One 5 ms Opus packet onto the sealed, paced, conn-id-tagged audio
    /// channel: the AudioFramer cuts it into chan-1 datagrams (its own
    /// data shard now; the group's 2 parity shards behind the 4th
    /// packet), each sealed with the header bytes as AAD and enqueued at
    /// PacerClass.audio, above every video class.
    ///
    /// Audio flows in ACTIVE, IDLE, FROZEN and RECOVERY: it is the path
    /// probe while video is frozen, its 5 ms cadence lets the client's
    /// blackout detector run at 350 ms, and it is the always-on
    /// queue-delay sensor. Only `closed` suppresses (counted, never
    /// thrown). Throws `SessionError.notEstablished` before the transport
    /// exists, and what the framer/seal path throws.
    @discardableResult
    public func ingestAudioPacket(
        _ packet: [UInt8],
        captureTimestampMicroseconds: UInt64,
        now: UInt64
    ) throws -> Int {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        if lifecycleLane.audioSendsSuppressed {
            counters.audioPacketsSuppressed += 1
            return 0
        }
        let datagrams = try audio.ingest(
            packet: packet,
            captureTimestampMicroseconds: captureTimestampMicroseconds
        )
        for (envelope, payload) in datagrams {
            channel.enqueueAudio(
                try encodeSealedAudio(
                    envelope: envelope, plaintext: payload
                ),
                seq: envelope.seq,
                frame: envelope.frame,
                now: now
            )
        }
        counters.audioPacketsIngested += 1
        counters.audioDatagramsEnqueued += datagrams.count
        counters.audioGroupsCompleted = audio.counters.groupsCompleted
        counters.audioGroupsAbandoned = audio.counters.groupsAbandoned
        return datagrams.count
    }

    /// Header bytes are the AAD and then become the final datagram buffer.
    /// Noise still owns and advances its sequence exactly once in
    /// `sealPayload`; only the post-seal assembly changes.
    private func encodeSealedAudio(
        envelope: Envelope, plaintext: [UInt8]
    ) throws -> [UInt8] {
        try envelope.sealedDatagram(plaintext[...]) { plaintext, aad in
            try sealPayload(plaintext, aad: aad, envelope: envelope)
        }
    }

    /// Audio datagrams still waiting in the shared pacer — the audio
    /// thread's bounded "make sure it left" loop reads this.
    public var queuedAudioDatagramCount: Int {
        channel.queuedCount(.audio)
    }

    /// Video-class bytes (fresh + repair tail) still queued in the pacer
    /// or the shell's socket outbox — what pre-encode admission weighs
    /// against the queue budget.
    public var queuedVideoBytes: Int {
        channel.queuedBytes(.freshVideo) + channel.queuedBytes(.videoTail)
            + socketPending.videoByteCount
    }

    public func annotateVideoFrameTelemetry(
        frame: FrameNumber, averageQP: Int?, idrCauses: [String]
    ) {
        channel.annotateFrameTelemetry(
            frame: frame, averageQP: averageQP, idrCauses: idrCauses
        )
    }

    /// Queue latency budget currently in force. The FEC regime is the
    /// existing clean/impaired posture, so admission and fall purge use
    /// one coherent mode switch.
    public var videoQueueBudgetNS: UInt64 {
        channel.regime == .lossy
            ? config.impairedVideoQueueBudgetNS
            : config.cleanVideoQueueBudgetNS
    }

    /// The encoder-loop poll: true when a fresh IDR is owed (path
    /// promotion, client 0x10, or a lifecycle demand). Clears every
    /// source; fires once per demand.
    public func takeFreshKeyframeRequest() -> Bool {
        !takeFreshKeyframeDemand().isEmpty
    }

    /// The same poll with its causes attached (a demand may carry several
    /// coalesced causes). Clears every source.
    public func takeFreshKeyframeDemand() -> FreshKeyframeDemand {
        if validator.takeFreshKeyframeRequest() {
            freshKeyframes.arm(.pathPromotion)
        }
        let demand = freshKeyframes.take()
        freshKeyframeDemandCounts.record(demand)
        return demand
    }

    // MARK: Lifecycle inputs

    /// The shell's injection report: the event with `seq` was handed to
    /// the desktop session at `injectedAtMicroseconds` (host µs). Buffers
    /// one echo tuple, flushed as 0x17 messages (≤ 32 tuples each) on the
    /// next `advance`, and moves the lastInputSeq stamp. No sends: safe
    /// to call while iterating the events that delivered the input.
    public func noteInputInjected(
        seq: UInt32,
        receivedAtMicroseconds: UInt64,
        injectedAtMicroseconds: UInt64
    ) {
        inputEchoBook.noteInjected(
            seq: seq,
            receivedAtMicroseconds: receivedAtMicroseconds,
            injectedAtMicroseconds: injectedAtMicroseconds
        )
    }

    /// Pending tuples onto the reliable stream, ≤ maxTupleCount per
    /// 0x17 message. A refused send is loud, not fatal, and the tuples
    /// stay queued for the next flush.
    private func flushInputEchoes(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard phase == .established else {
            return []
        }
        var events: [SessionEvent] = []
        while let message = inputEchoBook.nextMessage() {
            do {
                try sendReliable(
                    message.encode(),
                    now: now, hostMicroseconds: hostMicroseconds
                )
            } catch {
                events.append(.sendFailed("input echo: \(error)"))
                break
            }
            counters.inputEchoTuplesSent += inputEchoBook.commitSent(message)
        }
        return events
    }

    /// The shell's report that the audio leaf now runs in `mode` (at
    /// session start and after every applied 0x18 flip); emits the 0x19
    /// status. A no-op unless hostAudioRouting was agreed: a legacy
    /// client neither asked for the key nor knows the byte.
    public func noteAudioRoutingApplied(
        _ mode: HostAudioRoutingMode, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedHostAudioRouting else { return [] }
        do {
            try sendReliable(
                AudioRoutingStatus(mode: mode).encode(),
                now: now, hostMicroseconds: hostMicroseconds
            )
            counters.audioRoutingStatusesSent += 1
            return [.audioRoutingStatusSent(mode)]
        } catch {
            return [.sendFailed("audio routing status: \(error)")]
        }
    }

    /// The tripwire's announcement: quiet when the gate closes and on each
    /// ~5 s still-quiet check-in, active the instant it fires (before the
    /// pre-roll burst). A no-op unless key 15 was agreed.
    public func noteAudioTrackState(
        _ state: AudioTrackState.State, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedAudioQuietPosture else { return [] }
        do {
            try sendReliable(
                AudioTrackState(state: state).encode(),
                now: now, hostMicroseconds: hostMicroseconds
            )
            return [.audioTrackStateSent(state)]
        } catch {
            return [.sendFailed("audio track state: \(error)")]
        }
    }

    /// The video posture's announcement: one 0x26 per ladder step and one
    /// on the wake back to active. A no-op unless key 16 was agreed.
    public func noteVideoPostureState(
        _ state: VideoPostureState, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedVideoQuietPosture else { return [] }
        do {
            try sendReliable(
                state.encode(), now: now, hostMicroseconds: hostMicroseconds
            )
            return [.videoPostureStateSent(state)]
        } catch {
            return [.sendFailed("video posture state: \(error)")]
        }
    }

    /// The shell's report that the OS clipboard changed — genuine host
    /// copies and echoes of our own client-set applies alike; the book
    /// tells them apart. Judges the agreement, the book and the ceiling
    /// before a 0x1B leaves. A no-op unless clipboardText was agreed, or
    /// for an empty clipboard (clearing is not synced). Payloads never
    /// appear in events or logs.
    public func noteHostClipboardChanged(
        _ text: String, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedClipboardText, !text.isEmpty else { return [] }
        switch clipboardBook.admitLocalChange(text) {
        case .suppressEcho:
            counters.clipboardAnnouncesSuppressed += 1
            return [.clipboardAnnounceSuppressed(.loopEcho)]
        case .suppressDuplicate:
            counters.clipboardAnnouncesSuppressed += 1
            return [.clipboardAnnounceSuppressed(.duplicate)]
        case .share:
            break
        }
        let message: [UInt8]
        do {
            message = try ClipboardAnnounce(text: text).encode()
        } catch {
            // Over the ceiling (a huge host copy): suppressed and counted.
            counters.clipboardAnnouncesSuppressed += 1
            return [.clipboardAnnounceSuppressed(.overBudget)]
        }
        do {
            try sendReliable(
                message, now: now, hostMicroseconds: hostMicroseconds
            )
            clipboardBook.noteShared(text)
            counters.clipboardAnnouncesSent += 1
            return [.clipboardAnnounceSent(byteCount: message.count - 1)]
        } catch {
            return [.sendFailed("clipboard announce: \(error)")]
        }
    }

    /// The eye's report that the hardware cursor plane changed (a
    /// content-cropped BGRA shape or hidden). Judges the agreement, the
    /// dedupe slot and the wire contract before a 0x24 leaves; a no-op
    /// unless cursorShape was agreed. Pixels never appear in events or
    /// logs.
    public func noteCursorShapeChanged(
        _ shape: CursorShape, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedCursorShape else { return [] }
        guard shape != lastSentCursorShape else {
            counters.cursorShapesSuppressed += 1
            return [.cursorShapeSuppressed(.duplicate)]
        }
        let message: [UInt8]
        do {
            message = try shape.encode()
        } catch {
            // An over-ceiling crop or hostile geometry: suppressed and
            // counted; the client keeps the previous shape.
            counters.cursorShapesSuppressed += 1
            return [.cursorShapeSuppressed(.overBudget)]
        }
        do {
            try sendReliable(
                message, now: now, hostMicroseconds: hostMicroseconds
            )
            lastSentCursorShape = shape
            counters.cursorShapesSent += 1
            return [.cursorShapeSent(
                pixelByteCount: shape.pixels.count,
                hidden: shape.isHidden
            )]
        } catch {
            return [.sendFailed("cursor shape: \(error)")]
        }
    }

    /// The digest-free half of the image funnel: the image gate
    /// (keys 10 ∧ 12, established), then the channel's empty → lane
    /// busy → ceiling gates. Nil means only the digest-keyed sync book
    /// remains, so the shell hashes the image (outside its lock) and
    /// calls `noteHostClipboardImageChanged(_:sha256:now:hostMicroseconds:)`.
    /// Otherwise the image is settled without a digest: the returned
    /// events (empty when the gate is shut) are its whole outcome.
    public func prejudgeHostClipboardImage(
        byteCount: Int, now: UInt64
    ) -> [SessionEvent]? {
        guard agreedClipboardImages, phase == .established else {
            return []
        }
        guard let refused = clipboardImageChannel
            .refuseLocalImageBeforeDigest(byteCount: byteCount)
        else { return nil }
        return processImageEvents(refused, now: now)
    }

    /// The shell's report that the OS clipboard now holds an image (host
    /// copies and echoes of our own applies alike; the shared book, keyed
    /// 0xFF ‖ sha256, tells them apart). Judges the gate, the send lane,
    /// the 32 MiB ceiling and then the book before cargo leaves on chan
    /// 8. `sha256` is called only once the digest-free gates pass. A
    /// no-op unless keys 10 ∧ 12 were agreed. Payloads never appear in
    /// events or logs.
    public func noteHostClipboardImageChanged(
        _ data: [UInt8], sha256: () -> [UInt8],
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedClipboardImages, phase == .established else {
            return []
        }
        let channelEvents = clipboardImageChannel.shareLocalImage(
            data, sha256: sha256,
            book: &clipboardBook, rng: &rng
        )
        var events = processImageEvents(channelEvents, now: now)
        events += serviceArqLane(
            .bulk, now: now, hostMicroseconds: hostMicroseconds
        )
        return events
    }

    /// The one-lock form: hashes `data` itself, and only once the
    /// digest-free gates pass.
    public func noteHostClipboardImageChanged(
        _ data: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        noteHostClipboardImageChanged(
            data, sha256: { Sha256.digest(data) },
            now: now, hostMicroseconds: hostMicroseconds
        )
    }

    /// An orderly local close: the typed SessionTeardown leaves on the
    /// reliable stream and the machine closes. The teardown segment
    /// retransmits until acknowledged — keep servicing `advance` until
    /// `arqIsQuiescent` (or patience runs out) before exiting.
    public func beginTeardown(
        reason: SessionTeardownReason, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        runLifecycle(
            .teardownRequest(reason),
            now: now, hostMicroseconds: hostMicroseconds
        )
    }

    // MARK: Reliable CTRL

    /// Queues one message on the reliable ordered CTRL stream (ARQ group
    /// 0). The message must start with its own CTRL type byte. Throws
    /// `SessionError.notEstablished` before the transport exists and
    /// `ArqSendError` for an empty, over-budget, or backpressured
    /// (`queueFull`) message.
    public func sendReliable(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) throws {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        try enqueueReliable(on: .ctrl) {
            try ctrlArqLane.send(message, now: now)
        }
        _ = serviceArqLane(
            .control, now: now, hostMicroseconds: hostMicroseconds
        )
    }

    /// Queues one one-shot group's single message under the CTRL
    /// endpoint's next group id, which it returns. The group retransmits
    /// independently of the ordered stream and of every other one-shot;
    /// full acknowledgment surfaces as `.reliableOneShotAcknowledged`.
    @discardableResult
    public func sendReliableOneShot(
        _ message: [UInt8],
        now: UInt64,
        hostMicroseconds: UInt64
    ) throws -> ArqGroupId {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        let group = try enqueueReliable(on: .ctrl) {
            try ctrlArqLane.sendOneShot(message, now: now)
        }
        _ = serviceArqLane(
            .control, now: now, hostMicroseconds: hostMicroseconds
        )
        return group
    }

    /// True when the reliable sublayers (CTRL and, if present, bulk) have
    /// nothing left to send, retransmit or acknowledge. The teardown drain
    /// waits on both: a final bulk ack/abort deserves its retransmits too.
    public var arqIsQuiescent: Bool {
        ctrlArqLane.isQuiescent && (bulkArqLane?.isQuiescent ?? true)
    }

    // MARK: The bulk channel

    /// Queues one bulk message (the shell's accept/ack/complete/abort
    /// answers) on chan 8's own ARQ ordered stream, never CTRL. Throws
    /// `SessionError.notEstablished` before the transport exists and
    /// `SessionError.bulkNotNegotiated` unless key 11 was agreed.
    public func sendBulk(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) throws {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        guard agreedBulkTransfer, bulkArqLane != nil else {
            throw SessionError.bulkNotNegotiated
        }
        try enqueueReliable(on: .bulkTransfer) {
            try bulkArqLane!.send(message, now: now)
        }
        _ = serviceArqLane(
            .bulk, now: now, hostMicroseconds: hostMicroseconds
        )
    }

    /// Queues on the CTRL or bulk ARQ endpoint. `queueFull` is
    /// backpressure from a peer that stopped acknowledging: the message is
    /// not queued, the refusal is counted, and it propagates (never
    /// fatal). Stateful sites retry on their next call; one-off
    /// announcements surface as `.sendFailed` and are lost. A silent peer
    /// is ended by the liveness timeout, not here.
    private func enqueueReliable<T>(
        on channel: ChannelId, _ enqueue: () throws -> T
    ) throws -> T {
        do {
            return try enqueue()
        } catch ArqSendError.queueFull {
            if channel == .bulkTransfer {
                counters.bulkQueueFullRefusals += 1
            } else {
                counters.ctrlQueueFullRefusals += 1
            }
            throw ArqSendError.queueFull
        }
    }

    /// Chan-8 ingest events → session events: the 0x22 marker and
    /// clipboard-claimed messages feed the image lane; everything else
    /// surfaces as `.bulkMessageReceived`.
    private func absorbBulkArq(
        _ arqEvents: [ArqEvent], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for event in arqEvents {
            switch event {
            case .message(_, let bytes):
                events += consumeBulkStreamMessage(bytes, now: now)
            case .oneShotAcknowledged:
                break // bulk rides the ordered stream only (group 0)
            case .ignored(.orderedStreamPoisoned):
                events += tearDownPoisonedStream(
                    now: now, hostMicroseconds: hostMicroseconds)
            case .ignored(let reason):
                counters.arqIgnored += 1
                events.append(.arqIgnored(reason))
            }
        }
        return events
    }

    /// One chan-8 ARQ-delivered message, routed: marker or claimed id →
    /// image lane; everything else → the file lane (which still demands
    /// key 11 — the lanes' gates are independent).
    private func consumeBulkStreamMessage(
        _ bytes: [UInt8], now: UInt64
    ) -> [SessionEvent] {
        if bytes.first == CtrlMessageType.clipboardImageCargo {
            guard let cargo = try? ClipboardImageCargo.decode(bytes)
            else {
                counters.dropped += 1
                return [.dropped(.malformedBulk)]
            }
            // Image cargo without keys 10 ∧ 12 agreed: dropped loud.
            guard agreedClipboardImages else {
                counters.dropped += 1
                return [.dropped(.clipboardImagesNotNegotiated)]
            }
            return processImageEvents(
                clipboardImageChannel.ingestCargo(cargo), now: now
            )
        }
        guard let message = try? BulkMessage.decode(bytes) else {
            counters.dropped += 1
            return [.dropped(.malformedBulk)]
        }
        if clipboardImageChannel.claims(message) {
            return processImageEvents(
                // The incoming image is hashed chunk by chunk as its
                // prefix assembles, never as one blob at the finish.
                clipboardImageChannel.ingest(
                    message, book: &clipboardBook,
                    hasher: { Sha256() }
                ),
                now: now
            )
        }
        guard agreedBulkTransfer else {
            // Chan 8 was admitted for the image lane only — a file
            // message without key 11 is still ungated traffic.
            counters.dropped += 1
            return [.dropped(.bulkNotNegotiated)]
        }
        counters.bulkMessagesReceived += 1
        return [.bulkMessageReceived(message)]
    }

    /// A peer message past the ARQ budget poisoned an ordered stream (CTRL
    /// or bulk): it can never deliver in order again, so the session ends
    /// with a typed teardown the first time, and every later segment on
    /// that stream is counted without another event.
    private func tearDownPoisonedStream(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        counters.arqIgnored += 1
        guard !orderedStreamPoisoned else { return [] }
        orderedStreamPoisoned = true
        return [.arqIgnored(.orderedStreamPoisoned)] + runLifecycle(
            .teardownRequest(.shuttingDown),
            now: now, hostMicroseconds: hostMicroseconds)
    }

    /// Image-lane channel events → chan-8 sends + session events.
    /// Callers owe a bulk `serviceArqLane` pass afterward (the receive
    /// path already runs one; `noteHostClipboardImageChanged` runs
    /// its own).
    private func processImageEvents(
        _ channelEvents: [ClipboardImageEvent], now: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for event in channelEvents {
            switch event {
            case .send(let bytes):
                do {
                    try enqueueReliable(on: .bulkTransfer) {
                        try bulkArqLane?.send(bytes, now: now)
                    }
                } catch {
                    events.append(
                        .sendFailed("clipboard image: \(error)")
                    )
                }
            case .shareStarted(_, let byteCount):
                events.append(
                    .clipboardImageShareStarted(byteCount: byteCount)
                )
            case .shareCompleted(_, let byteCount):
                events.append(
                    .clipboardImageShareCompleted(byteCount: byteCount)
                )
            case .shareAborted(let reason, let byRemote):
                events.append(.clipboardImageShareAborted(
                    reason: reason, byRemote: byRemote
                ))
            case .receiveAborted(let reason, let byRemote):
                events.append(.clipboardImageReceiveAborted(
                    reason: reason, byRemote: byRemote
                ))
            case .suppressed(let reason):
                events.append(.clipboardImageSuppressed(reason))
            case .refused(let reason):
                events.append(.clipboardImageRefused(reason))
            case .applyImage(let data, let mime):
                events.append(
                    .clipboardImageReceived(data: data, mime: mime)
                )
            case .violated(let violation):
                events.append(.clipboardImageViolation(violation))
            }
        }
        return events
    }

    /// One chan-8 body onto the wire: conn-id-tagged envelope, header
    /// bytes as AAD, sealed under the transport, then the pacer's
    /// `.bulk` class of the shared schedule.
    private func sendBulkDatagram(
        body: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) throws {
        guard let sequence = bulkArqLane?.pendingEnvelopeSequence else {
            throw SessionError.bulkNotNegotiated
        }
        let (envelope, bytes) = try encodeChannelDatagram(
            body: body,
            wireChannel: .bulkTransfer,
            sequence: sequence,
            sealed: true,
            hostMicroseconds: hostMicroseconds
        )
        channel.enqueueBulk(bytes, seq: envelope.seq, now: now)
        bulkArqLane!.commitEnvelopeSent()
    }

    /// Ingest events → session events, with the counters kept honest.
    /// Lifecycle (0x09/0x0A) and capability (0x0F/0x11/0x12) messages are
    /// consumed here; everything else (the pairing quartet, future types)
    /// surfaces as `.reliableCtrl` for the shell.
    private func absorbArq(
        _ arqEvents: [ArqEvent], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for event in arqEvents {
            switch event {
            case .message(let group, let bytes):
                if let consumed = consumeReliable(
                    bytes, now: now, hostMicroseconds: hostMicroseconds
                ) {
                    events += consumed
                } else {
                    events.append(.reliableCtrl(group: group, message: bytes))
                }
            case .oneShotAcknowledged(let group):
                events.append(.reliableOneShotAcknowledged(group))
            case .ignored(.orderedStreamPoisoned):
                events += tearDownPoisonedStream(
                    now: now, hostMicroseconds: hostMicroseconds)
            case .ignored(let reason):
                counters.arqIgnored += 1
                events.append(.arqIgnored(reason))
            }
        }
        return events
    }

    /// The session's own reliable-CTRL consumers. Returns nil when the
    /// type byte belongs to some other consumer (the shell dispatches
    /// those). Never throws: hostile bytes become drop events.
    private func consumeReliable(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent]? {
        switch message.first {
        case CtrlMessageType.sessionTeardown:
            guard let teardown = try? SessionTeardown.decode(message) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            return runLifecycle(
                .teardownMessage(teardown.reason),
                now: now, hostMicroseconds: hostMicroseconds
            )
        case CtrlMessageType.capabilityDeclaration:
            return receiveDeclaration(
                message, now: now, hostMicroseconds: hostMicroseconds
            )
        case CtrlMessageType.capabilityUpdateAck:
            guard let ack = try? CapabilityUpdateAck.decode(message),
                  let event = try? negotiator.receive(ack) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            switch event {
            case .updateAccepted:
                return [.capabilityUpdateAcknowledged(accepted: true)]
            case .updateRejected:
                return [.capabilityUpdateAcknowledged(accepted: false)]
            case .agreed, .answerUpdate:
                counters.dropped += 1 // unreachable from receive(ack)
                return [.dropped(.malformedCtrl)]
            }
        case CtrlMessageType.inputEvent:
            guard let event = try? InputEvent.decode(message) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            counters.inputEventsReceived += 1
            // Pre-arm before the shell injects: a keypress during a
            // blackout must persist even if injection is deferred.
            var events = runLifecycle(
                .preArmInput, now: now, hostMicroseconds: hostMicroseconds
            )
            events.append(.inputReceived(
                event, receivedAtMicroseconds: hostMicroseconds
            ))
            return events
        case CtrlMessageType.audioRoutingRequest:
            guard let request = try? AudioRoutingRequest.decode(message) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            // A request without hostAudioRouting agreed by both ends uses
            // a capability never negotiated: dropped loud, never fatal.
            guard agreedHostAudioRouting else {
                counters.dropped += 1
                return [.dropped(.audioRoutingNotNegotiated)]
            }
            counters.audioRoutingRequestsReceived += 1
            return [.audioRoutingRequested(request.mode)]
        case CtrlMessageType.clipboardSet:
            guard let set = try? ClipboardSet.decode(message) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            // A set without clipboardText agreed: dropped loud, never fatal.
            guard agreedClipboardText else {
                counters.dropped += 1
                return [.dropped(.clipboardNotNegotiated)]
            }
            counters.clipboardSetsReceived += 1
            // Pre-arm the book before the shell applies: the leaf's change
            // signal for this very apply must suppress, not boomerang.
            clipboardBook.noteRemoteApplied(set.text)
            return [.clipboardSetReceived(text: set.text)]
        case CtrlMessageType.modeTransition, CtrlMessageType.capabilityUpdate,
             CtrlMessageType.inputEcho,
             CtrlMessageType.audioRoutingStatus,
             CtrlMessageType.clipboardAnnounce,
             CtrlMessageType.cursorShape:
            // Receiver-role messages arriving at the mediaSender /
            // sole proposer / echo emitter / status emitter / announce
            // emitter / shape emitter: hostile or confused. Dropped loud.
            counters.dropped += 1
            return [.dropped(.unexpectedCtrlType(message.first!))]
        case CtrlMessageType.bulkOffer, CtrlMessageType.bulkAccept,
             CtrlMessageType.bulkChunk, CtrlMessageType.bulkAck,
             CtrlMessageType.bulkComplete, CtrlMessageType.bulkAbort:
            // The bulk sextet rides chan 8, never CTRL (a chunk here would
            // head-of-line-block input). Hostile or confused; dropped loud.
            counters.dropped += 1
            return [.dropped(.unexpectedCtrlType(message.first!))]
        default:
            return nil
        }
    }

    /// The client's 0x0F: the intersection settles the session — or
    /// proves it unworkable, in which case the typed teardown is the
    /// answer (never silence: the client must learn why).
    private func receiveDeclaration(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let declaration: CapabilityDeclaration
        do {
            declaration = try CapabilityDeclaration.decode(message)
        } catch {
            counters.dropped += 1
            return [.dropped(.malformedCtrl)]
        }
        do {
            guard case .agreed(let agreed) = try negotiator.receive(declaration)
            else {
                counters.dropped += 1 // unreachable from receive(declaration)
                return [.dropped(.malformedCtrl)]
            }
            return [.capabilitiesAgreed(agreed)]
        } catch let failure as CapabilityNegotiationError
            where failure == .noCommonVideoCodec
                || failure == .noCommonChromaMode {
            var events: [SessionEvent] = [
                .capabilitiesFailed(String(describing: failure))
            ]
            events += runLifecycle(
                .teardownRequest(.shuttingDown),
                now: now, hostMicroseconds: hostMicroseconds
            )
            return events
        } catch {
            // A duplicate declaration or other protocol violation:
            // dropped loud, never fatal.
            counters.dropped += 1
            return [.dropped(.malformedCtrl)]
        }
    }

    // MARK: The lifecycle machine's runner

    /// Delegates one apply-then-poll pass, executes its external actions, and
    /// surfaces the lane's single state-change projection.
    private func runLifecycle(
        _ input: SessionInput?, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let verdict = lifecycleLane.drive(input, now: now)
        var events: [SessionEvent] = []
        if let state = verdict.stateChangedTo {
            events.append(.lifecycleChanged(state))
        }
        events += execute(
            verdict.actions, now: now, hostMicroseconds: hostMicroseconds
        )
        return events
    }

    /// Everything the machine can ask for, done.
    private func execute(
        _ actions: [SessionAction], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for action in actions {
            switch action {
            case .sendModeMessage(let mode):
                do {
                    try sendReliable(
                        ModeTransition(mode: mode).encode(),
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                    counters.modeTransitionsSent += 1
                    events.append(.modeTransitionSent(mode))
                } catch {
                    events.append(.sendFailed("mode transition: \(error)"))
                }
            case .sendTeardownMessage(let reason):
                do {
                    try sendReliable(
                        SessionTeardown(reason: reason).encode(),
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                    events.append(.teardownSent(reason))
                } catch {
                    events.append(.sendFailed("teardown: \(error)"))
                }
            case .sendFinalFrameReliably:
                // The lane asks for this only after `.ratchetConverged`,
                // which the host never feeds: the direct eye has no
                // convergence ratchet, so the session stays ACTIVE.
                break
            case .armNextDamageAsIdr(let pacing), .forceIdr(let pacing):
                switch pacing {
                case .lastGoodRate: freshKeyframes.arm(.machineWake)
                case .halfStaleEstimate:
                    freshKeyframes.arm(.machineRecovery)
                }
                // The machine names the policy; the estimator owns the
                // numbers: min(btlRate, lastGoodRate) for a WAKE,
                // max(floor, 0.5 × stale estimate) for RECOVERY. Applied
                // now, so the IDR this arms is the first thing it paces.
                let rate = estimator.applyIdrPacing(pacing, now: now)
                channel.setRate(bitsPerSecond: rate, now: now)
                counters.rateChanges += 1
                events.append(.rateChanged(
                    bitsPerSecond: rate, reason: .idrPacing(pacing)
                ))
            case .freezeDatagramSends, .resumeDatagramSends:
                // Consumed by the lane into video admission; never leave it.
                break
            case .sessionClosed(let reason):
                events.append(.sessionClosed(reason))
            }
        }
        return events
    }

    /// The capability declaration: the session's first ARQ-carried message.
    private func declareCapabilities(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard let declaration = negotiator.start() else { return [] }
        do {
            try sendReliable(
                try declaration.encode(),
                now: now, hostMicroseconds: hostMicroseconds
            )
            return []
        } catch {
            return [.sendFailed("capability declaration: \(error)")]
        }
    }

    // MARK: The estimator's diet

    /// Holds a released datagram until the kernel accepts it
    /// (`.socketConfirmed` accounting).
    private func noteSocketPending(_ datagram: VideoChannelDatagram) {
        socketPending.note(
            datagram,
            releaseRateBitsPerSecond: estimator.rateBitsPerSecond
        )
    }

    /// Confirms that a pacer-released datagram was accepted by the kernel.
    /// Production calls this once, and only once, for each successful
    /// `sendmmsg` element. EAGAIN leaves it pending and therefore invisible
    /// to path feedback until a later successful retry.
    public func confirmDatagramSent(
        _ datagram: VideoChannelDatagram, now: UInt64
    ) {
        guard sendAccounting == .socketConfirmed,
              datagram.destination == nil else { return }
        let pace = socketPending.remove(datagram)
        noteSent(datagram, now: now, paceBitsPerSecond: pace)
    }

    /// Removes one socket-pending datagram without presenting it as path
    /// evidence: a fall purge of the executable's unsent outbox, a kernel
    /// pressure shed, or a send the socket refused. A chan-2 datagram
    /// already holds its seq, so the estimator is told the client's
    /// ledger will count it missing through no fault of the path.
    public func discardPendingDatagram(_ datagram: VideoChannelDatagram) {
        guard sendAccounting == .socketConfirmed,
              datagram.destination == nil,
              socketPending.remove(datagram) != nil else { return }
        if datagram.pacerClass.sessionChannel == .videoActive {
            estimator.noteHostDroppedVideo(count: 1, now: pumpNowNS)
        }
    }

    public func noteKernelPressureFreshVideoShed(
        datagrams: Int, bytes: Int
    ) {
        guard datagrams > 0 else { return }
        counters.kernelPressureShedFrames += 1
        counters.kernelPressureShedDatagrams += datagrams
        counters.kernelPressureShedBytes += bytes
        freshKeyframes.arm(.fallPurge)
    }

    /// One released datagram into the estimator's ledger. Off-primary
    /// challenges are excluded: they travel an unvalidated tuple, so
    /// their arrivals measure a different path.
    private func noteSent(
        _ datagram: VideoChannelDatagram,
        now: UInt64,
        paceBitsPerSecond: Int? = nil
    ) {
        guard datagram.destination == nil else { return }
        let deliveryFrame: FrameNumber? =
            datagram.pacerClass == .freshVideo
                ? datagram.frameNumber : nil
        estimator.noteSent(
            channel: datagram.pacerClass.sessionChannel, seq: datagram.seq,
            bytes: datagram.bytes.count, now: now,
            deliveryFrame: deliveryFrame,
            paceBitsPerSecond: paceBitsPerSecond
        )
    }

    /// One authenticated chan-3 payload: parse, feed the estimator,
    /// apply its rate (and any FEC-regime step) to the shared channel,
    /// answer the NACK section through the retransmit gate, and
    /// — while the machine is in RECOVERY — feed its window verdicts.
    private func ingestFeedback(
        _ plaintext: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let report: FeedbackReport
        do {
            report = try FeedbackReport.decode(plaintext)
        } catch {
            counters.feedbackReportsMalformed += 1
            counters.dropped += 1
            return [.dropped(.malformedFeedback)]
        }
        counters.feedbackReportsParsed += 1
        repairBudget.noteFeedback(report, now: now)
        // The video backlog rides along: while the pacer holds a standing
        // queue, delivery trains measure our own pacing.
        let verdict = estimator.ingest(
            report, now: now, inRecovery: lifecycleLane.isRecovering,
            pacerBacklogBytes: queuedVideoBytes,
            // NACKs against frames still being sent are the client's
            // completion presumption expiring mid-drain: recused.
            recusedNackFrames: channel.framesWithQueuedShards()
                .union(socketPending.videoFrameNumbers)
        )
        var events: [SessionEvent] = []
        if let rate = verdict.newRateBitsPerSecond {
            channel.setRate(bitsPerSecond: rate, now: now)
            counters.rateChanges += 1
            let reason: RateChangeReason
            switch verdict.change {
            case .overuse: reason = .overuse
            case .loss: reason = .loss
            case .postFecLoss: reason = .postFecLoss
            case .evidence, nil: reason = .evidence
            }
            events.append(.rateChanged(bitsPerSecond: rate, reason: reason))
            // The fall-repricing purge: a genuine fall (never evidence
            // decay) reprices bytes admitted at the pre-fall rate. Backlog
            // that would now serialize past the budget is stale wire —
            // drop it and re-anchor through the coalesced keyframe latch;
            // the IDR supersedes whatever the dropped shards completed.
            if reason != .evidence {
                let backlog = queuedVideoBytes
                let staleWireNS = UInt64(
                    Double(backlog) * 8e9 / Double(rate))
                if staleWireNS > videoQueueBudgetNS {
                    let purged = channel.purgeQueuedVideo()
                    let socketDatagrams = socketPending.videoDatagramCount
                    let socketBytes = socketPending.videoByteCount
                    freshKeyframes.arm(.fallPurge)
                    counters.fallPurges += 1
                    counters.fallPurgedVideoBytes += purged.bytes + socketBytes
                    events.append(.videoBacklogPurged(
                        datagrams: purged.datagrams + socketDatagrams,
                        bytes: purged.bytes + socketBytes,
                        staleWireMs: Int(staleWireNS / 1_000_000)))
                }
            }
        }
        if let regime = verdict.fecRegime {
            // The next frame's geometry draws from the new regime.
            channel.setRegime(regime)
            counters.fecRegimeSteps += 1
            events.append(.fecRegimeChanged(regime))
        }
        for nack in report.nacks {
            events += respondToNack(
                nack, now: now, hostMicroseconds: hostMicroseconds
            )
        }
        for clean in verdict.recoveryWindows {
            events += runLifecycle(
                .feedbackWindow(clean: clean),
                now: now, hostMicroseconds: hostMicroseconds
            )
        }
        return events
    }

    /// The freeze budget in force: the config override when set, else the
    /// derivation documented on `repairFreezeBudgetOverrideNS`.
    public var repairFreezeBudgetNS: UInt64 {
        repairBudget.freezeBudgetNanoseconds(
            override: config.repairFreezeBudgetOverrideNS,
            cadenceMultiplier: config.repairBudgetCadenceMultiplier,
            jitterAllowanceNanoseconds:
                config.repairBudgetJitterAllowanceNS
        )
    }

    /// The NACK responder over the channel's repair store:
    ///
    ///   honor iff SRTT + retxSerialization < remainingFreezeBudget
    ///         AND the frame is not older than the last IDR;
    ///   one attempt per shard, no retransmission of retransmissions.
    ///
    /// Refusals the client can act on (budget gone, older than the IDR,
    /// store gone) each send one sealed, ARQ-exempt 0x23 RepairRefusal so
    /// the client stops waiting on repairs that are not coming; its
    /// recovery episode requests the IDR, and its own deadline covers a
    /// lost refusal. Already-repaired stays silent (repairs may be in
    /// flight; a refusal would double-heal into an IDR), as does
    /// FROZEN/closed (the path is dark; RECOVERY's forced IDR heals, so
    /// the latch is not armed). While nothing has plausibly reached the
    /// client's glass, an ask naming the last IDR is honored regardless
    /// of the budget, bounded by attempts and bytes.
    private func respondToNack(
        _ nack: FeedbackReport.NackEntry,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        counters.nackEntriesReceived += 1

        func stale(_ reason: NackStaleReason) -> [SessionEvent] {
            counters.nacksJudgedStale += 1
            var events: [SessionEvent] = [
                .nackJudgedStale(frame: nack.frame, reason: reason)
            ]
            let refusalReason: RepairRefusalReason?
            switch reason {
            case .budgetExceeded: refusalReason = .staleBudget
            case .olderThanIdr: refusalReason = .superseded
            case .unavailable: refusalReason = .unknownFrame
            case .alreadyRepaired, .sendsSuppressed: refusalReason = nil
            }
            if let refusalReason {
                do {
                    try sendCtrl(
                        body: RepairRefusal(
                            frame: nack.frame, reason: refusalReason
                        ).encode(),
                        sealed: true,
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                    counters.repairRefusalsSent += 1
                } catch {
                    events.append(
                        .sendFailed("repair refusal: \(error)"))
                }
            }
            return events
        }

        if lifecycleLane.videoSendsSuppressed {
            return stale(.sendsSuppressed)
        }
        // A frame behind the last IDR is a dead reference: the IDR
        // re-anchored the chain past it. The IDR itself stays repairable.
        // No IDR arm on refusal: the newer IDR is the heal.
        if let lastIdr = channel.lastKeyframeNumber, nack.frame < lastIdr {
            return stale(.olderThanIdr)
        }
        // A fall purge already armed the one replacement IDR. Treat
        // later NACKs for any purged frame as superseded: resurrecting
        // its stored shards would rebuild the stale tail, while arming
        // another IDR would turn one capacity cliff into an avalanche.
        if channel.wasPurged(nack.frame) {
            return stale(.olderThanIdr)
        }
        guard let ingestedAt = channel.repairAnchor(for: nack.frame) else {
            return stale(.unavailable)
        }
        let repairBytes = channel.repairByteCount(
            frame: nack.frame, shardIndices: nack.missingShards
        )
        guard repairBytes > 0 else {
            // Everything named already rode its one attempt. The repairs
            // may be in flight; arming an IDR would double-heal (the
            // client's requester escalates if the frame stays incomplete).
            return stale(.alreadyRepaired)
        }
        // The opening-IDR exemption skips the budget gate (SRTT may not
        // exist yet: the first beacon echo is up to 1 s away). Bounded by
        // attempts and bytes so it cannot amplify congestion.
        let openingExempt = repairBudget.openingExemptionAvailable(
            lastIdrMatches: channel.lastKeyframeNumber == nack.frame,
            repairBytes: repairBytes,
            maxAttempts: config.openingRepairMaxAttempts,
            maxBytes: config.openingRepairMaxBytes
        )
        if !openingExempt {
            // The budget clock started when the frame's flight completed;
            // the NACK's trip up is inside the elapsed time. No RTT
            // evidence means no honest promise — stale. The RTT term is
            // SRTT capped at 2 × min-RTT: beacon-echo SRTT double-counts
            // both ends' receive-loop wake latency, which a repair
            // (straight onto the pacer) never pays; real path queueing
            // moves min-RTT with it.
            let elapsedNS = now &- ingestedAt
            let budgetNS = repairFreezeBudgetNS
            guard elapsedNS < budgetNS,
                  let srttMicros = estimator.srttMicroseconds
            else {
                return stale(.budgetExceeded)
            }
            let remainingNS = budgetNS - elapsedNS
            let rttMicros = min(
                max(srttMicros, 0),
                2 * max(estimator.minRttMicroseconds ?? srttMicros, 0)
            )
            let rttNS = UInt64(rttMicros) &* 1_000
            let serializationNS = UInt64(
                Double(repairBytes) * 8
                    / Double(channel.rateBitsPerSecond) * 1e9
            )
            guard rttNS + serializationNS < remainingNS else {
                return stale(.budgetExceeded)
            }
        }

        let enqueued = channel.enqueueRepair(
            frame: nack.frame,
            shardIndices: nack.missingShards,
            now: now
        )
        guard enqueued > 0 else {
            return stale(.unavailable)
        }
        if openingExempt {
            repairBudget.commitOpeningExemptRepair(bytes: repairBytes)
            counters.openingExemptRepairsHonored += 1
        }
        counters.nacksHonored += 1
        counters.repairDatagramsEnqueued += enqueued
        return [.repairEnqueued(frame: nack.frame, shards: enqueued)]
    }

    private enum ArqCarrier: Equatable {
        case control
        case bulk
    }

    /// Polls either reliable lane and puts its already carrier-sized output
    /// on the matching channel. The lane retains its own PTO deadline; Session
    /// retains sealing, pacer selection, counters, and failure vocabulary.
    private func serviceArqLane(
        _ carrier: ArqCarrier,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard phase == .established else { return [] }
        let payloads: [[UInt8]]
        switch carrier {
        case .control:
            payloads = ctrlArqLane.poll(now: now)
        case .bulk:
            guard bulkArqLane != nil else { return [] }
            payloads = bulkArqLane!.poll(now: now)
        }
        guard !payloads.isEmpty else { return [] }

        var events: [SessionEvent] = []
        do {
            for payload in payloads {
                switch carrier {
                case .control:
                    try sendCtrl(
                        body: payload, sealed: true,
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                    counters.arqDatagramsSent += 1
                case .bulk:
                    try sendBulkDatagram(
                        body: payload,
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                    counters.bulkArqDatagramsSent += 1
                }
            }
        } catch {
            // Segments the poll marked sent stay armed on their PTO
            // timers — a refused send heals like a lost datagram.
            let label = carrier == .control ? "arq" : "bulk arq"
            events.append(.sendFailed("\(label): \(error)"))
        }
        return events
    }

    // MARK: Timers and pumping

    /// Clock advance with no datagram — the loop's timer wake: due
    /// beacons, ARQ retransmits, lifecycle timers, validator expiries.
    /// Until the initiator proves key possession the beacon cadence and
    /// ARQ retransmits stay parked: message 1 carries no freshness, so an
    /// unconfirmed session may be answering a spoofed source, and it
    /// sends that source nothing beyond its one answer (and verbatim
    /// message 2 resends to the asking tuple).
    public func advance(now: UInt64, hostMicroseconds: UInt64) -> [SessionEvent] {
        var events = process(
            validator.advance(now: now),
            now: now, hostMicroseconds: hostMicroseconds
        )
        guard phase == .established else { return events }
        if isPeerConfirmed {
            events += serviceConfirmedTimers(
                now: now, hostMicroseconds: hostMicroseconds)
        }
        if lifecycleLane.shouldService(at: now) {
            events += runLifecycle(
                nil, now: now, hostMicroseconds: hostMicroseconds
            )
        }
        return events
    }

    private func serviceConfirmedTimers(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        // Passthrough mode establishes without a handshake, so the
        // declaration leaves on the first wake (a no-op once declared).
        var events = declareCapabilities(
            now: now, hostMicroseconds: hostMicroseconds
        )
        if let beacon = beaconClock.takeDueBeacon(
            now: now, hostMicroseconds: hostMicroseconds
        ) {
            events += emitBeacon(
                beacon, now: now, hostMicroseconds: hostMicroseconds
            )
        }
        events += flushInputEchoes(now: now, hostMicroseconds: hostMicroseconds)
        if let due = ctrlArqLane.nextDeadlineNanoseconds, now >= due {
            events += serviceArqLane(
                .control, now: now, hostMicroseconds: hostMicroseconds
            )
        }
        if let due = bulkArqLane?.nextDeadlineNanoseconds, now >= due {
            events += serviceArqLane(
                .bulk, now: now, hostMicroseconds: hostMicroseconds
            )
        }
        return events
    }

    /// Drains due pacer batches to the sink. Returns the datagram count.
    @discardableResult
    public func pump(now: UInt64) -> Int {
        pumpNowNS = now
        return channel.pump(now: now)
    }

    /// Releases only control/audio pacer work. Used when the executable
    /// already has sealed video waiting on a blocked socket.
    @discardableResult
    public func pumpLatency(now: UInt64) -> Int {
        pumpNowNS = now
        return channel.pumpLatency(now: now)
    }

    /// Stable cross-channel priority for an unsent socket outbox. Noise
    /// replay/nonce state is per channel, so control/audio may move ahead of
    /// video byte-identically. Relative order within every channel remains
    /// unchanged; video classes are deliberately not reordered among
    /// themselves because they share channel 2.
    public static func prioritizeLatency(
        _ datagrams: [VideoChannelDatagram]
    ) -> [VideoChannelDatagram] {
        var ordered = datagrams
        prioritizeLatency(&ordered)
        return ordered
    }

    /// In-place form. The pacer already releases in class order, so the
    /// common case is a single ordered scan with no allocation.
    public static func prioritizeLatency(
        _ datagrams: inout [VideoChannelDatagram]
    ) {
        func rank(_ datagram: VideoChannelDatagram) -> Int {
            switch datagram.pacerClass {
            case .control: 0
            case .audio: 1
            default: 2
            }
        }
        var previous = 0
        var ordered = true
        for datagram in datagrams {
            let current = rank(datagram)
            if current < previous {
                ordered = false
                break
            }
            previous = current
        }
        guard !ordered else { return }
        var control: [VideoChannelDatagram] = []
        var audio: [VideoChannelDatagram] = []
        var remaining: [VideoChannelDatagram] = []
        for datagram in datagrams {
            switch rank(datagram) {
            case 0: control.append(datagram)
            case 1: audio.append(datagram)
            default: remaining.append(datagram)
            }
        }
        datagrams.removeAll(keepingCapacity: true)
        datagrams.append(contentsOf: control)
        datagrams.append(contentsOf: audio)
        datagrams.append(contentsOf: remaining)
    }

    /// The earliest instant anything here has work (pacer, beacon, ARQ,
    /// lifecycle or validator deadline). A shell that pumps only latency
    /// classes passes `.audio`, so video it will not release cannot make
    /// the wake "now".
    public func nextWake(
        now: UInt64, upThrough highestClass: PacerClass = .bulk
    ) -> UInt64? {
        var wake = channel.nextWake(now: now, upThrough: highestClass)
        func fold(_ candidate: UInt64?) {
            guard let candidate else { return }
            wake = wake.map { min($0, candidate) } ?? candidate
        }
        if isPeerConfirmed {
            fold(beaconClock.nextDeadlineNanoseconds)
            fold(ctrlArqLane.nextDeadlineNanoseconds)
            fold(bulkArqLane?.nextDeadlineNanoseconds)
        }
        fold(lifecycleLane.nextDeadlineNanoseconds)
        fold(validator.nextDeadline)
        return wake
    }

    public var isIdle: Bool { channel.isIdle }

    /// Passes a rate to the shared pacer. The estimator drives it from
    /// feedback; shells and tests may force one (the estimator's next
    /// verdict moves it again).
    public func setRate(bitsPerSecond: Int, now: UInt64) {
        channel.setRate(bitsPerSecond: bitsPerSecond, now: now)
    }

    // MARK: Estimator surfaces

    /// The estimator's standing rate — what the pacer should be (and,
    /// short of a manual `setRate`, is) running at.
    public var estimatedRateBitsPerSecond: Int {
        estimator.rateBitsPerSecond
    }

    /// The windowed-max measured delivery rate; nil before evidence.
    public var deliveryRateBitsPerSecond: Int? {
        estimator.deliveryRateBitsPerSecond
    }

    /// The reporting-grade delivery figure (full-train median — the
    /// overuse anchor's evidence); the windowed max above is the
    /// control law's burst-tolerant probe, not a summary number.
    public var measuredDeliveryRateBitsPerSecond: Int? {
        estimator.measuredDeliveryRateBitsPerSecond
    }

    /// The current queuing-delay inflation estimate, µs.
    public var queuingDelayMicroseconds: Int64? {
        estimator.queuingDelayMicroseconds
    }

    /// The estimator's capacity belief — what it honestly
    /// believes the path can carry (raised by any delivery above it,
    /// demoted only by evidence a censored sender cannot manufacture).
    public var capacityBeliefBitsPerSecond: Int? {
        estimator.capacityBeliefBitsPerSecond
    }

    public var estimatorStats: RateEstimatorStats { estimator.stats }

    /// The last overuse fall's evidence (the ramp hunt's forensics) —
    /// print alongside the `.overuse` rate change it belongs to.
    public var lastOveruseFallForensics: OveruseFallForensics? {
        estimator.lastOveruseFall
    }

    /// The frame ceiling at the live estimate: R×B/8 − higherClassBytes(B),
    /// B = min(2/fps, 25 ms) — the single-frame VBV cap the encoder
    /// should enforce.
    public func frameByteCeiling(fps: Int) -> Int {
        estimator.frameByteCeiling(fps: fps)
    }

    /// The largest frame the current regime and TLV posture can ship as
    /// one protected FEC group — the ingest guard's live bound.
    public var protectableFrameByteCeiling: Int {
        channel.maxProtectableFrameByteCount(
            hasLastInputSeq: lastInputSeq != nil
        )
    }

    /// That ceiling's session-static worst case (lossy regime,
    /// input stamp riding) — what the shell caps the encoder's opening
    /// VBV to, so no reachable posture can mint an unshippable frame.
    public var worstCaseProtectableFrameByteCeiling: Int {
        channel.worstCaseProtectableFrameByteCount
    }

    /// The rate the shared pacer is actually running at.
    public var pacerRateBitsPerSecond: Int { channel.rateBitsPerSecond }

    public var pacerTelemetry: PacerTelemetry { channel.pacerTelemetry }
    public var videoCounters: VideoChannelCounters { channel.counters }

    // MARK: Repair surfaces

    /// The FEC regime the packetizing seam is drawing from.
    public var fecRegime: FecRegime { channel.regime }

    /// The retransmit gate's smoothed RTT; nil before beacon evidence.
    public var srttMicroseconds: Int64? { estimator.srttMicroseconds }

    /// Bytes retained for repair (the retention ring's live size).
    public var repairStoreBytes: Int { channel.repairStoreBytes }

    public func takeFrameTransmitTelemetry() -> [VideoFrameTransmitTelemetry] {
        channel.takeFrameTransmitTelemetry()
    }

    // MARK: Handshake (responder)

    /// True when `datagram` is shaped like a client handshake initiation:
    /// a bare CTRL carriage whose payload is typed 0x05 (Noise message 1)
    /// or 0x14 (cookie resubmission). A shape check for choosing what a
    /// listening shell feeds a session; admission, cookies and Noise
    /// still judge the bytes.
    public static func looksLikeHandshakeInitiation(_ datagram: [UInt8]) -> Bool {
        guard let (envelope, payload) = try? Envelope.decode(datagram),
              envelope.channel == .ctrl
        else { return false }
        return payload.first == CtrlMessageType.noiseHandshake1
            || payload.first == CtrlMessageType.retryHandshake1
    }

    /// The opaque bytes the retry cookie binds address ownership to: the
    /// client's address ‖ port, within RetryCookie's 1…255-byte tuple
    /// bound ("255.255.255.255:65535" is 21 bytes).
    static func cookieTuple(_ tuple: FourTuple) -> [UInt8] {
        Array("\(tuple.remoteAddress):\(tuple.remotePort)".utf8)
    }

    /// Answers an authenticated message 1: message 2, the transport, the
    /// session-start beacon and the capability declaration. The session
    /// is established but not yet confirmed (`isPeerConfirmed`).
    private func completeHandshake(
        responder: NoiseSession,
        message1: ArraySlice<UInt8>,
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var responder = responder
        // Until a handshake completes the session is bound to no client:
        // the first message 1 to authenticate names the client's path,
        // whichever tuple the shell first saw. A spoofed or unpaired
        // arrival therefore cannot pin the session to its source.
        if tuple != validator.primary.tuple {
            validator = PathValidator(
                connectionId: connectionId,
                initialPath: tuple,
                now: now,
                config: config.path,
                rng: rng
            )
        }
        do {
            let message2Body = [CtrlMessageType.noiseHandshake2]
                + (try responder.writeMessage2())
            try sendCtrl(
                body: message2Body,
                sealed: false,
                now: now, hostMicroseconds: hostMicroseconds
            )
            transport = try responder.makeTransport()
            answeredHandshake = (Array(message1), message2Body)
        } catch {
            return [.dropped(.handshakeFailed(String(describing: error)))]
        }
        lifecycleLane.establish(at: now)
        var events: [SessionEvent] = [.handshakeCompleted(
            remoteStaticPublicKey: responder.remoteStaticPublicKey ?? []
        )]
        // Message 2 is already queued ahead of this session-start beacon
        // in the control FIFO, so the client derives its transport before
        // the first sealed datagram lands.
        let beacon = beaconClock.makeSessionStartBeacon(
            now: now, hostMicroseconds: hostMicroseconds
        )
        events += emitBeacon(
            beacon, now: now, hostMicroseconds: hostMicroseconds
        )
        // The machine begins at establishment in ACTIVE, and the
        // capability declaration is the first word on the reliable stream
        // (beacons are ARQ-exempt).
        events += declareCapabilities(
            now: now, hostMicroseconds: hostMicroseconds
        )
        events += runLifecycle(nil, now: now, hostMicroseconds: hostMicroseconds)
        return events
    }

    // MARK: CTRL dispatch

    private func dispatchCtrl(
        _ payload: [UInt8],
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard let type = payload.first else {
            counters.dropped += 1
            return [.dropped(.malformedCtrl)]
        }
        switch type {
        case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
            // A payload starting with either ARQ byte is wholly ARQ.
            // Ingest, then poll at once so the owed ACK (and any fast
            // retransmit) leaves in this same pass.
            var events = absorbArq(
                ctrlArqLane.ingest(payload[...], now: now),
                now: now, hostMicroseconds: hostMicroseconds
            )
            events += serviceArqLane(
                .control, now: now, hostMicroseconds: hostMicroseconds
            )
            return events
        case CtrlMessageType.beaconEcho:
            guard let echo = try? BeaconEcho.decode(payload) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            return accept(echo: echo, hostMicroseconds: hostMicroseconds)
        case CtrlMessageType.pathResponse:
            guard let response = try? PathResponse.decode(payload) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            return process(
                validator.pathResponseReceived(
                    from: tuple, response: response, now: now
                ),
                now: now, hostMicroseconds: hostMicroseconds
            )
        case CtrlMessageType.idrRequest:
            guard let request = try? IdrRequest.decode(payload) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            counters.idrRequests += 1
            // The requester retries every 500 ms until its renderer
            // accepts an IRAP. An encoded IDR is an offer, not delivery
            // proof: older-named retries are suppressed only inside the
            // in-flight window, so a wholly lost recovery IDR can re-arm.
            // Damage at/after the offered anchor re-arms immediately.
            if let lastIdr = channel.lastKeyframeNumber,
               request.frame < lastIdr,
               let offeredAt = lastKeyframeOfferedAtNS,
               now &- offeredAt < config.clientIdrOfferInFlightNS {
                counters.idrRequestsSupersededByKeyframe += 1
            } else {
                freshKeyframes.arm(.clientRequest)
            }
            return [.idrRequested(request)]
        default:
            counters.dropped += 1
            return [.dropped(.unexpectedCtrlType(type))]
        }
    }

    private func accept(
        echo: BeaconEcho, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard let sample = beaconClock.accept(
            echo: echo, hostMicroseconds: hostMicroseconds
        ) else {
            counters.dropped += 1
            return [.dropped(.beaconEchoUnmatched)]
        }
        counters.beaconEchoes += 1
        // RTT evidence into the estimator (telemetry and the retransmit
        // gate; the rate law runs on dispersion).
        estimator.noteRtt(microseconds: sample.rttMicroseconds)
        return [.beaconEchoAccepted(
            beaconSeq: echo.beaconSeq,
            offsetMicroseconds: sample.offsetMicroseconds,
            rttMicroseconds: sample.rttMicroseconds
        )]
    }

    // MARK: Outbound plumbing

    private func emitBeacon(
        _ beacon: ClockBeacon,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        do {
            try sendCtrl(
                body: beacon.encode(), sealed: true,
                now: now, hostMicroseconds: hostMicroseconds
            )
        } catch {
            return [.sendFailed("beacon \(beacon.beaconSeq): \(error)")]
        }
        counters.beaconsSent += 1
        return [.beaconSent(beaconSeq: beaconClock.noteBeaconSent())]
    }

    /// Executes the validator's decisions (a challenge is a CTRL send on
    /// the probed tuple) and surfaces every event to the caller.
    private func process(
        _ pathEvents: [PathValidatorEvent],
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for event in pathEvents {
            if case .sendChallenge(let tuple, let challenge) = event {
                do {
                    try sendCtrl(
                        body: challenge.encode(), sealed: true,
                        destination: tuple,
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                } catch {
                    events.append(.sendFailed("path challenge: \(error)"))
                }
            }
            // A promotion moves media to a path whose delay and capacity
            // the estimator has never measured.
            if case .promoted = event {
                estimator.notePathChanged(now: now)
            }
            // .freshKeyframeNeeded needs no execution here: the encoder
            // loop polls takeFreshKeyframeRequest(), which reads the
            // validator's latch directly.
            events.append(.path(event))
        }
        return events
    }

    /// One CTRL body onto the wire: conn-id-tagged envelope, header
    /// bytes as AAD, sealed under the transport (`sealed: false` only
    /// for the bare handshake message 2), then the control class of the
    /// shared pacer.
    private func sendCtrl(
        body: [UInt8],
        sealed: Bool,
        destination: FourTuple? = nil,
        now: UInt64,
        hostMicroseconds: UInt64
    ) throws {
        let (envelope, bytes) = try encodeChannelDatagram(
            body: body,
            wireChannel: .ctrl,
            sequence: ctrlArqLane.pendingEnvelopeSequence,
            sealed: sealed,
            hostMicroseconds: hostMicroseconds
        )
        channel.enqueueControl(
            bytes, seq: envelope.seq, destination: destination, now: now
        )
        ctrlArqLane.commitEnvelopeSent()
    }

    /// The one channel-envelope encoding and sealing path. Carrier-specific
    /// queue selection and sequence commitment stay at the two call sites.
    private func encodeChannelDatagram(
        body: [UInt8],
        wireChannel: ChannelId,
        sequence: ChannelSeq,
        sealed: Bool,
        hostMicroseconds: UInt64
    ) throws -> (Envelope, [UInt8]) {
        let envelope = Envelope(
            channel: wireChannel,
            seq: sequence,
            frame: FrameNumber(rawValue: 0),
            timestamp: hostMicroseconds,
            fec: 0,
            extensions: [connectionId.wireExtension]
        )
        guard sealed else {
            return (envelope, try envelope.encode(payload: body))
        }
        let bytes = try envelope.sealedDatagram(body[...]) { plaintext, aad in
            try sealPayload(plaintext, aad: aad, envelope: envelope)
        }
        return (envelope, bytes)
    }

    // MARK: The crypto seam

    private func sealPayload(
        _ plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        switch config.crypto {
        case .testPassthrough:
            return Array(plaintext)
        case .noise:
            guard transport != nil else { throw SessionError.notEstablished }
            return try transport!.seal(
                plaintext: plaintext, aad: aad, envelope: envelope
            )
        }
    }

    private func unsealPayload(
        _ wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        switch config.crypto {
        case .testPassthrough:
            return Array(wirePayload)
        case .noise:
            guard transport != nil else { throw SessionError.notEstablished }
            return try transport!.unseal(
                wirePayload: wirePayload, aad: aad, envelope: envelope
            )
        }
    }
}

/// The init's injected generator, shared by reference: the conn-id,
/// every path validator's challenge tokens and the image-id mint draw
/// from one stream. Copies of a value-typed generator would replay each
/// other, making challenge tokens equal to image ids a client sees.
struct SharedRng: RandomNumberGenerator {
    private final class State {
        var base: any RandomNumberGenerator
        init(_ base: any RandomNumberGenerator) { self.base = base }
    }
    private let state: State

    init(_ base: some RandomNumberGenerator) {
        state = State(base)
    }

    mutating func next() -> UInt64 { state.base.next() }
}
