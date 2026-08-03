// Session: the host's session stub (HS-7) — the sans-IO core that
// assembles the full send path into one live Lyte-UDP stream and feeds
// J-G1. It owns, in one place:
//
//   • the Noise IK handshake as RESPONDER (W5): consume the client's
//     message 1, produce message 2, derive the NoiseTransport. The
//     client knows the host's static out-of-band (pinned at pairing;
//     printed by the executable for the J-G1 debug client). There is no
//     hello beyond the handshake — IK's own payloads carry the version
//     byte (W5's first-payload rule), and the session-start beacon is
//     the host's first sealed word.
//   • the seal discipline: every outbound datagram — video shards from
//     VideoChannel, audio shards from AudioFramer (HS-15), beacons,
//     path challenges — is sealed
//     under the transport with the exact header bytes (fixed envelope +
//     TLV block) as AAD, mirroring the client seam (CL-1/CL-3) so both
//     directions speak identical crypto. `--insecure` (CP-3 fallback,
//     §4.1) is the same wiring with a passthrough seal; the default is
//     Noise, and geometry/pacing are mode-identical by construction.
//   • the 1 Hz clock beacon on CTRL (§4.6, W4a): beaconSeq from 0 at
//     session start plus one beacon at establishment; t1 is the host
//     graph-clock µs the caller injects. Client BeaconEchoes come back
//     sealed; each yields one offset/RTT sample (NTP arithmetic in the
//     codec) and the next beacon mirrors the last echo per W4a's layout.
//   • HS-12 integration: the session mints its ConnectionId, every
//     outbound datagram carries the TLV, inbound datagrams feed the
//     PathValidator's demux trigger, challenges ride CTRL to the exact
//     unvalidated tuple, and `takeFreshKeyframeRequest()` merges the
//     validator's promotion IDR with client 0x10 IDR requests into one
//     encoder-loop poll.
//   • HS-6 integration: all traffic classes through one Pacer schedule
//     (VideoChannel owns it; control enters via `enqueueControl`).
//   • HS-8 integration: reliable CTRL rides an `ArqEndpoint` (W3).
//     `sendReliable`/`sendReliableOneShot` queue messages; inbound
//     payloads whose first byte is 0x07/0x08 route wholly to
//     `ArqEndpoint.ingest` (the one-byte peek); delivered messages and
//     one-shot acknowledgments surface as events. ARQ datagrams are
//     sealed CTRL like everything else — conn-id TLV, header-as-AAD,
//     the control pacer class — which is why the endpoint's output
//     repacks to the session's real 1101 B plaintext budget (the HS-7
//     accounting fix, applied to the reliable sublayer: poll packs to
//     the bare 1112 B table, exact only without TLV + tag). The
//     deliberately ARQ-EXEMPT registry traffic is untouched: beacons
//     and echoes are time-sensitive samples (a late beacon is a lie),
//     path messages must travel on the exact unvalidated tuple
//     (HS-12), handshake datagrams predate the transport, and a lost
//     IDR request is superseded by the requester's next coalesced
//     emission. ARQ retransmit timers ride the session's wake
//     machinery: `nextWake` folds the endpoint's PTO deadline in, and
//     `advance` services it — on the Linux host that is the idle-floor
//     tick, the between-frames service point.
//
// Sans-IO in the house style: no sockets, no threads, no clock. Entry
// points take `now` (monotonic ns — the pacer/validator domain) and
// `hostMicroseconds` (the PipeWire graph-clock µs — the envelope
// timestamp and beacon-t1 domain); outputs leave through the injected
// send sink as `VideoChannelDatagram`s in pacer order, and everything
// the caller must react to comes back as `SessionEvent` values. The
// Linux loop (lyte-host) is deliberately thin over this; the macOS gate
// test drives the whole session in-process against a LyteWire initiator.

import HostCore
import LyteCore
import LyteWire

/// How the session's transport keys come to exist.
public enum SessionCryptoMode: Sendable {
    /// Real Noise IK (the default): the host responds with this pinned
    /// static keypair; the transport derives from the completed
    /// handshake.
    case noise(hostStatic: NoiseKeyPair)
    /// The CP-3 recorded `--insecure` fallback (§4.1): passthrough seal,
    /// no handshake — the session is established from init and streams
    /// to the configured peer. Same wiring, same geometry, mandatory
    /// re-gate with Noise.
    case insecure
}

public struct SessionConfig: Sendable {
    public var crypto: SessionCryptoMode
    /// The negotiated session ceiling: the pacer's starting rate and
    /// the HS-16 estimator's upper bound (the estimator moves the live
    /// rate inside [floor, this]).
    public var rateBitsPerSecond: Int
    public var regime: FecRegime
    public var pacerQuantumNS: UInt64
    /// §4.6: 1 Hz. A beacon also goes out at establishment.
    public var beaconIntervalNS: UInt64
    public var path: PathValidatorConfig
    /// The reliable-CTRL sublayer's knobs (HS-8). The session clamps
    /// `maxSegmentBodyByteCount` to its own CTRL plaintext budget
    /// (1101 B with the conn-id TLV + AEAD tag) at init — a caller
    /// cannot configure a segment that would burst a datagram.
    public var arq: ArqConfig
    /// When set, a completing handshake whose authenticated client
    /// static is not in this set is rejected. Nil accepts any static —
    /// honest for the stub: pairing (W6 PIN-PAKE) is what mints this
    /// set, and J-G1 runs statics-pinned-out-of-band in both directions.
    public var allowedClientStaticPublicKeys: [[UInt8]]?
    /// The pre-handshake flood throttle (HS-9): message 1s beyond this
    /// budget are dropped before any Noise state is allocated.
    public var handshakeGate: HandshakeGate.Config
    /// What this host declares in the W7 capability exchange. The
    /// declaration is the session's FIRST ARQ-carried message
    /// post-establishment; the agreed set is the intersection with the
    /// client's declaration.
    public var capabilities: Capabilities
    /// The W4b lifecycle machine's knobs: the 350 ms blackout detector,
    /// the 30 s liveness clock, RECOVERY's clean-window count.
    public var lifecycle: SessionMachineConfig
    /// HS-22: how long damage must stay quiet AFTER the ratchet
    /// converges before the idle handoff starts (the one-shot ride
    /// whose ack flips the mode to IDLE). The pillar's decision of
    /// record stands — idle→active restarts with an IDR — which is
    /// exactly why the flip must not be entered eagerly: a desktop
    /// metronome (a 1 Hz clock, a ~1 Hz cursor blink) that keeps
    /// converging and re-damaging would otherwise cycle
    /// IDLE→WAKE→full-frame-IDR every beat — the owner's "1 Hz blur
    /// while paused". 3 s is three missed beats of the slowest common
    /// ticker: a genuinely static desktop still flips (3 s late, one
    /// converged frame held meanwhile), a ticking one stays ACTIVE on
    /// small P-frames at near-idle bandwidth. Convergence noted with
    /// NO damage ever recorded flips immediately (the pre-HS-22
    /// behavior — and the shape every existing pin drives).
    public var idleFlipQuietNS: UInt64
    /// The HS-16 congestion estimator's knobs. Nil derives the default
    /// config with `rateBitsPerSecond` as the ceiling — the negotiated
    /// session rate IS the ceiling (no capability key carries bitrate
    /// in v1) and the floor is resiliency's 500 kbps.
    public var estimator: RateEstimatorConfig?
    /// HS-17 → HS-32: the retransmit gate's freeze budget. A NACK is
    /// honored iff SRTT + retransmit serialization still fit inside
    /// what remains of the budget, measured from the frame's last
    /// shard release. HS-17 pinned the budget at a constant 2 frame
    /// intervals (33 ms) — which the squeeze review §2 proved DEAD ON
    /// ARRIVAL by construction: the ask itself rides the client's
    /// 25–50 ms feedback cadence, so nearly every honest ask arrived
    /// already past the budget (twin-leg books: 82 asks, 1682 shards,
    /// 0 frames repaired). The budget is now DERIVED:
    ///
    ///   budget = repairBudgetCadenceMultiplier × observedCadence
    ///            + repairBudgetJitterAllowanceNS
    ///
    /// where observedCadence is an EWMA (α = 1/8) of feedback-report
    /// inter-arrival CLAMPED to the wire-pinned 25–50 ms cadence
    /// range (out-of-cadence NACK flushes and lost reports are not
    /// the cadence), starting from the 50 ms documented worst case
    /// before evidence exists. Derivation rationale: an ask detected
    /// geometry-immediately waits at most one cadence for its report
    /// plus one one-way trip — 1.5× the cadence covers both, and the
    /// allowance covers both ends' scheduling jitter. At the client's
    /// reference 40 ms cadence the derived budget is 75 ms, well
    /// inside the client's 250 ms assembler horizon (the TRUE ceiling
    /// a repair must beat before the group evicts), so "honor" still
    /// promises a repair the glass can use. Non-nil here overrides
    /// the derivation entirely (tests, ops).
    public var repairFreezeBudgetOverrideNS: UInt64?
    /// HS-32: the derived budget's cadence multiplier (see above).
    public var repairBudgetCadenceMultiplier: Double
    /// HS-32: the derived budget's scheduling-jitter allowance.
    public var repairBudgetJitterAllowanceNS: UInt64
    /// HS-32: the opening-IDR exemption's bounds. While NO frame has
    /// plausibly ever completed at the client (nothing on glass yet),
    /// the LAST IDR stays repairable regardless of the freeze budget:
    /// a black glass is the one case where a late repair beats a
    /// re-minted IDR that starts even later. Bounded by honored asks
    /// and repair bytes so the exemption can never amplify
    /// congestion (the consult's caution); the client's own ask
    /// discipline (once-ever per shard, ≤250 ms old) bounds it again
    /// from the other end.
    public var openingRepairMaxAttempts: Int
    public var openingRepairMaxBytes: Int
    /// Peer-driven unknown-frame NACKs may arm at most one IDR in this
    /// interval. Other stale-NACK reasons and every host-driven demand
    /// source are unaffected. This bounds an authenticated peer naming
    /// a fresh garbage frame on every 25–50 ms feedback report.
    public var unknownFrameIdrArmIntervalNS: UInt64
    /// HS-17: the repair store's retention window (build plan's
    /// "≥4 s rings") and byte cap, passed through to VideoChannel.
    public var repairRetentionNS: UInt64
    public var repairStoreByteCap: Int
    /// Hard fresh-video queue budgets. Admission checks these before
    /// encode and a rate fall re-prices the existing queue against the
    /// same budget. Clean defaults to 50 ms. Lossy/impaired mode may
    /// spend more time on FEC/repair, but is clamped to 100 ms so it can
    /// never turn a capacity cliff into a stale tail.
    public var cleanVideoQueueBudgetNS: UInt64
    public var impairedVideoQueueBudgetNS: UInt64
    /// A repair still queued after this interval is no longer useful to
    /// the bounded client assembler and expires before transmit.
    public var repairQueueUsefulnessNS: UInt64

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
        idleFlipQuietNS: UInt64 = 3_000_000_000,
        estimator: RateEstimatorConfig? = nil,
        repairFreezeBudgetOverrideNS: UInt64? = nil,
        repairBudgetCadenceMultiplier: Double = 1.5,
        repairBudgetJitterAllowanceNS: UInt64 = 15_000_000,
        openingRepairMaxAttempts: Int = 4,
        openingRepairMaxBytes: Int = 2 << 20,
        unknownFrameIdrArmIntervalNS: UInt64 = 1_000_000_000,
        repairRetentionNS: UInt64 = 4_000_000_000,
        repairStoreByteCap: Int = 16 << 20,
        cleanVideoQueueBudgetNS: UInt64 = 50_000_000,
        impairedVideoQueueBudgetNS: UInt64 = 100_000_000,
        repairQueueUsefulnessNS: UInt64 = 100_000_000
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
        self.idleFlipQuietNS = idleFlipQuietNS
        self.estimator = estimator
        self.repairFreezeBudgetOverrideNS = repairFreezeBudgetOverrideNS
        self.repairBudgetCadenceMultiplier = repairBudgetCadenceMultiplier
        self.repairBudgetJitterAllowanceNS = repairBudgetJitterAllowanceNS
        self.openingRepairMaxAttempts = openingRepairMaxAttempts
        self.openingRepairMaxBytes = openingRepairMaxBytes
        self.unknownFrameIdrArmIntervalNS = unknownFrameIdrArmIntervalNS
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
    }
}

/// Why a fresh keyframe is owed (the estimator-ramp hunt's IDR books):
/// every source `takeFreshKeyframeRequest` merges, named. An OptionSet
/// because demands coalesce — one frame can answer several at once.
public struct FreshKeyframeDemand: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// HS-12: a path promotion re-anchors the new primary.
    public static let pathPromotion = FreshKeyframeDemand(rawValue: 1 << 0)
    /// A client 0x10 IDR request.
    public static let clientRequest = FreshKeyframeDemand(rawValue: 1 << 1)
    /// The lifecycle machine's WAKE (armNextDamageAsIdr, .lastGoodRate).
    public static let machineWake = FreshKeyframeDemand(rawValue: 1 << 2)
    /// The lifecycle machine's RECOVERY (forceIdr, .halfStaleEstimate).
    public static let machineRecovery = FreshKeyframeDemand(rawValue: 1 << 3)
    /// HS-17: a stale NACK verdict left the client stuck — re-anchor.
    public static let staleNackArm = FreshKeyframeDemand(rawValue: 1 << 4)
    /// HS-25: an unprotectable frame was dropped — re-anchor references.
    public static let unprotectableDrop = FreshKeyframeDemand(rawValue: 1 << 5)
    /// A rate fall purged queued video mid-flight — re-anchor.
    public static let fallPurge = FreshKeyframeDemand(rawValue: 1 << 6)

    /// The books' short names, in bit order.
    public var names: [String] {
        var out: [String] = []
        if contains(.pathPromotion) { out.append("path-promotion") }
        if contains(.clientRequest) { out.append("client-request") }
        if contains(.machineWake) { out.append("wake") }
        if contains(.machineRecovery) { out.append("recovery") }
        if contains(.staleNackArm) { out.append("stale-nack") }
        if contains(.unprotectableDrop) { out.append("unprotectable") }
        if contains(.fallPurge) { out.append("fall-purge") }
        return out
    }
}

/// What the caller must know about. Values, not callbacks — the loop
/// executes/logs them in order (the PathValidator precedent).
public enum SessionEvent: Equatable, Sendable {
    /// The Noise handshake completed; the transport is live. The key is
    /// the client's authenticated static — the identity pairing checks.
    case handshakeCompleted(remoteStaticPublicKey: [UInt8])
    /// HS-21: the host answered an un-cookied message 1 with a stateless
    /// RetryChallenge (0x13) because require-cookie mode is engaged. No
    /// Noise state was allocated — this is the bounded flood cost.
    case handshakeChallenged
    /// HS-21: require-cookie mode flipped. `true` = the msg1 arrival rate
    /// crossed the enter threshold (flood detected — the host now demands
    /// a cookie); `false` = pressure cleared past the exit threshold.
    case handshakeCookieModeChanged(requireCookie: Bool)
    case beaconSent(beaconSeq: UInt32)
    /// One echo consumed: one raw offset/RTT sample recorded (filtering
    /// is CL-10's HostClockModel on the client; the host keeps the
    /// min-RTT-gated estimate for logs and glass-to-glass math).
    case beaconEchoAccepted(
        beaconSeq: UInt32,
        offsetMicroseconds: Int64,
        rttMicroseconds: Int64
    )
    /// A client 0x10 arrived; `takeFreshKeyframeRequest()` is now true.
    case idrRequested(IdrRequest)
    /// The ARQ delivered one reliable CTRL message — exactly once, in
    /// order within its group (HS-8). The bytes start with the
    /// message's own CTRL type byte; dispatch registers types as the
    /// reliable consumers (capabilities at W7, mode transitions at
    /// HS-11) land.
    case reliableCtrl(group: ArqGroupId, message: [UInt8])
    /// A one-shot group this session sent is fully acknowledged — the
    /// HS-11 "final frame landed, flip to IDLE" signal, surfaced.
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
    /// The W7 exchange settled: both declarations met, this is the
    /// session's agreed set (the intersection).
    case capabilitiesAgreed(Capabilities)
    /// The peer's declaration produced an unworkable intersection (no
    /// common video codec / chroma mode) — the typed teardown follows
    /// in the same event batch.
    case capabilitiesFailed(String)
    /// The client answered our outstanding renegotiation proposal
    /// (0x12). On accept the operative datagram ceiling already moved;
    /// apply at the next IDR boundary.
    case capabilityUpdateAcknowledged(accepted: Bool)
    /// A ModeTransition (0x09) left on the reliable stream — the
    /// mediaSender's ACTIVE⇄IDLE flip, as the wire hears it.
    case modeTransitionSent(SessionWireMode)
    /// The converged ratchet frame left on its reliable one-shot group
    /// (HS-11). Its `.reliableOneShotAcknowledged` is the idle flip.
    case finalFrameSent(ArqGroupId)
    /// A typed SessionTeardown (0x0A) left on the reliable stream.
    case teardownSent(SessionTeardownReason)
    /// The W4b machine changed state (wire modes and the local
    /// FROZEN/RECOVERY overlay both surface here).
    case lifecycleChanged(SessionState)
    /// The session reached `closed`: a teardown either way, or the
    /// 30 s liveness timeout (which sends nothing — the peer that
    /// would read the message is the one that died).
    case sessionClosed(SessionCloseReason)
    /// A client input event (0x16) arrived on the reliable stream —
    /// exactly once, in order (HS-13). The shell injects it into the
    /// desktop session and reports back via `noteInputInjected`;
    /// `receivedAtMicroseconds` is the host µs the carrying datagram
    /// arrived at (the echo tuple's rx stamp). The machine's pre-arm
    /// already ran: a keypress in IDLE is the WAKE, one during FROZEN
    /// persists until RECOVERY's IDR consumes it (W4b).
    case inputReceived(InputEvent, receivedAtMicroseconds: UInt64)
    /// The HS-16 estimator moved the pacer rate (feedback evidence, or
    /// a machine-demanded IdrPacing policy). The pacer is already
    /// re-capped when this surfaces; the shell logs it.
    case rateChanged(bitsPerSecond: Int, reason: RateChangeReason)
    /// The fall-repricing purge fired: a genuine fall left queued
    /// video that would serialize past the backlog threshold at the
    /// new rate — dropped from the pacer, fresh IDR armed through the
    /// coalesced latch. `staleWireMs` is the wire time the purged
    /// bytes would have occupied at the new rate.
    case videoBacklogPurged(datagrams: Int, bytes: Int, staleWireMs: Int)
    /// HS-17: a client NACK passed the retransmit gate — `shards`
    /// repair datagrams are enqueued (fresh seqs, videoTail class).
    case repairEnqueued(frame: FrameNumber, shards: Int)
    /// HS-17: a client NACK was judged per the staleness ruling and
    /// refused. `.budgetExceeded`/`.unavailable` arm the coalesced
    /// keyframe latch (the IDR alternative, §1.1 rule 4);
    /// `.olderThanIdr` refuses silently (a newer IDR already heals)
    /// and `.alreadyRepaired` is the one-attempt rule holding.
    case nackJudgedStale(frame: FrameNumber, reason: NackStaleReason)
    /// HS-17: the estimator stepped the §5.2 FEC regime; the channel's
    /// packetizing seam is already switched when this surfaces.
    case fecRegimeChanged(FecRegime)
    /// HS-18: a client 0x18 asked for a routing flip. Only surfaces
    /// when the agreed capabilities carry hostAudioRouting (W7 rule 3);
    /// the shell flips the audio leaf and reports back via
    /// `noteAudioRoutingApplied`, which is what emits the 0x19 status.
    case audioRoutingRequested(HostAudioRoutingMode)
    /// HS-18: an applied posture left as a 0x19 status on the reliable
    /// stream (at capability agreement and after every applied flip).
    case audioRoutingStatusSent(HostAudioRoutingMode)
    /// Tripwire: a 0x25 track-state announcement left on the reliable
    /// stream (gate close, still-quiet check-in, or wake).
    case audioTrackStateSent(AudioTrackState.State)
    /// Video posture: a 0x26 announcement left on the reliable stream
    /// (a backoff step, or the wake back to active).
    case videoPostureStateSent(VideoPostureState)
    /// CL-15: a client 0x1A clipboard set arrived on the reliable
    /// stream — exactly once, in order. Only surfaces when the agreed
    /// capabilities carry clipboardText (the W7 rule-3 gate); the
    /// sync book is already pre-armed against this apply's OS echo.
    /// The shell applies it through the HostClipboardLeaf seam and
    /// reports the leaf's own change signals via
    /// `noteHostClipboardChanged` — the book eats the echo there.
    case clipboardSetReceived(text: String)
    /// CL-15: a host clipboard change left as a 0x1B announce on the
    /// reliable stream (byte count only — payloads are never logged).
    case clipboardAnnounceSent(byteCount: Int)
    /// CL-15: a leaf-reported clipboard change was judged and NOT
    /// announced — the loop-prevention/dedupe/ceiling discipline
    /// holding (design doc §5).
    case clipboardAnnounceSuppressed(ClipboardSuppressReason)
    /// E3: the hardware cursor plane's shape left as a 0x24 on the
    /// reliable stream (pixel byte count only — pixels are never
    /// logged; a hidden announce carries zero of them).
    case cursorShapeSent(pixelByteCount: Int, hidden: Bool)
    /// E3: an eye-reported cursor shape was judged and NOT sent —
    /// the dedupe/ceiling discipline holding.
    case cursorShapeSuppressed(CursorSuppressReason)
    /// F-3: one decoded bulk message off chan 8's ARQ ordered stream —
    /// exactly once, in order. Only surfaces when the agreed
    /// capabilities carry bulkTransfer (the W7 rule-3 gate, key 11);
    /// the shell feeds it to the BulkReceiveShell, whose replies come
    /// back through `sendBulk`.
    case bulkMessageReceived(BulkMessage)
    /// P-1: a sha-verified clipboard IMAGE arrived over the bulk
    /// channel — the shell applies it through the leaf's image seam.
    /// Only surfaces when the image gate (keys 10 ∧ 12) survived
    /// intersection; the sync book is already pre-armed against the
    /// apply's OS echo. Payload bytes appear here and nowhere else —
    /// never in logs (the CL-15 rule).
    case clipboardImageReceived(data: [UInt8], mime: String)
    /// P-1: a host image copy left as bulk-channel cargo (marker +
    /// offer in flight; byte count only).
    case clipboardImageShareStarted(byteCount: Int)
    /// P-1: the client verified the digest — the image landed.
    case clipboardImageShareCompleted(byteCount: Int)
    /// P-1: an image share died; `byRemote` says whose abort it was
    /// (a remote declined/busy is routine weather — best-effort
    /// latest-wins).
    case clipboardImageShareAborted(
        reason: BulkAbortReason, byRemote: Bool
    )
    /// P-1: an admitted incoming image died before landing — nothing
    /// was applied.
    case clipboardImageReceiveAborted(
        reason: BulkAbortReason, byRemote: Bool
    )
    /// P-1: a leaf-reported image copy was judged and NOT shared —
    /// the loop-prevention/dedupe/ceiling/lane discipline holding.
    case clipboardImageSuppressed(ClipboardImageSuppressReason)
    /// P-1: incoming image cargo was refused; the typed abort is
    /// already queued on chan 8.
    case clipboardImageRefused(ClipboardImageRefuseReason)
    /// P-1: the peer broke the bulk state machine inside the
    /// clipboard lane (the abort is already queued).
    case clipboardImageViolation(BulkTransferViolation)
}

/// Why a leaf-reported host clipboard change did not become a 0x1B
/// (CL-15's suppression axis). Counted and surfaced, never thrown.
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

/// Why an eye-reported cursor shape was not sent (E3).
public enum CursorSuppressReason: Equatable, Sendable {
    /// Identical to the last sent shape — the client already wears it.
    case duplicate
    /// The shape breaks the wire contract (an over-ceiling crop, a
    /// hostile geometry) — suppressed and counted, the client keeps
    /// the previous shape.
    case overBudget
}

/// Why a NACK did not produce a retransmit (HS-17's verdict axis).
public enum NackStaleReason: Equatable, Sendable {
    /// The frame is older than the last IDR — the decode chain past
    /// that IDR no longer references it (§1.1 rule 3; the IDR itself
    /// stays repairable per §5.2's burst-loss rationale).
    case olderThanIdr
    /// SRTT + retransmit serialization no longer fit the remaining
    /// freeze budget (or no RTT evidence exists to promise they do).
    case budgetExceeded
    /// The store no longer holds anything the NACK names (evicted
    /// past the retention window, or indices the frame never had).
    case unavailable
    /// Every named shard already rode its one retransmit.
    case alreadyRepaired
    /// FROZEN/closed: datagram sends (retransmits included) are
    /// suppressed (resiliency §4's freeze protocol).
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
    /// A machine-demanded IDR pacing policy was applied (W4b).
    case idrPacing(IdrPacing)
    /// NACK-evidenced loss FEC could not absorb (rung 3, HS-17).
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
    /// A message 1 beyond the HandshakeGate budget: dropped unread,
    /// before any Noise state was allocated (HS-9's flood posture).
    case handshakeThrottled
    /// A RetryHandshake1 (0x14) whose cookie did not verify — a spoofer
    /// or a stale/replayed cookie, dropped before any Noise (HS-21).
    case handshakeCookieInvalid
    /// A chan-3 payload FeedbackReport.decode refused. Still counted as
    /// media-path evidence (an authenticated arrival is an arrival) but
    /// the estimator never sees it — HS-16 runs on parsed reports only.
    case malformedFeedback
    /// A 0x18 routing request without hostAudioRouting in the agreed
    /// set — the peer is using a capability it never negotiated
    /// (HS-18; the W7 rule-3 gate holding). Dropped loud, never fatal.
    case audioRoutingNotNegotiated
    /// A 0x1A clipboard set without clipboardText in the agreed set
    /// (CL-15; the same rule-3 gate). Dropped loud, never fatal.
    case clipboardNotNegotiated
    /// A chan-8 datagram without bulkTransfer in the agreed set (F-3;
    /// the same rule-3 gate — the toggle-off host never declared key
    /// 11, so any bulk traffic is a peer using a superpower it never
    /// negotiated). Dropped loud, never fatal.
    case bulkNotNegotiated
    /// A chan-8 ARQ-delivered message that failed BulkMessage.decode
    /// (outside the 0x1C–0x21 sextet and the 0x22 marker, or hostile
    /// interior bytes).
    case malformedBulk
    /// A 0x22 clipboard-image cargo marker without the image gate
    /// (keys 10 ∧ 12) in the agreed set (P-1; the same rule-3 gate).
    /// Dropped loud, never fatal.
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

/// Where the estimator's send ledger takes its timestamp. Sans-IO tests and
/// callers with an immediate sink keep the historical pacer-release seam;
/// the Linux UDP shell confirms only after the kernel accepts the datagram.
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

/// Raw clock-mapping samples from the beacon/echo exchange.
public struct SessionClockStats: Equatable, Sendable {
    public var samples = 0
    public var lastOffsetMicroseconds: Int64?
    public var lastRttMicroseconds: Int64?
    public var minRttMicroseconds: Int64?
    /// The offset carried by the min-RTT sample — the least
    /// queue-polluted estimate (the min-filter idea, one sample deep).
    public var minRttOffsetMicroseconds: Int64?

    public init() {}
}

public struct SessionCounters: Equatable, Sendable {
    public var datagramsReceived = 0
    public var dropped = 0
    public var unsealFailures = 0
    public var beaconsSent = 0
    public var beaconEchoes = 0
    public var idrRequests = 0
    /// Reliable CTRL messages the ARQ delivered (HS-8).
    public var arqMessages = 0
    /// Ingested ARQ bytes the endpoint refused or deduplicated.
    public var arqIgnored = 0
    /// Sealed CTRL datagrams carrying ARQ frames, both fresh and
    /// retransmit — the loss-gate's retransmission evidence.
    public var arqDatagramsSent = 0
    /// Chan 3 arrivals (parsed or not — any authenticated arrival is
    /// media-path evidence for the blackout detector).
    public var feedbackDatagrams = 0
    /// Chan 3 payloads that decoded as FeedbackReports and fed the
    /// HS-16 estimator.
    public var feedbackReportsParsed = 0
    /// Chan 3 payloads that failed FeedbackReport.decode (counted,
    /// dropped loud, never fatal — hostile bytes cannot starve the
    /// detector, they just carry no estimator evidence).
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
    /// Message 1s the HandshakeGate refused (HS-9's flood evidence).
    public var handshakesThrottled = 0
    /// RetryChallenges (0x13) the host minted under flood (HS-21) — the
    /// bounded-cost answer: one HMAC + a reply smaller than the request,
    /// no Noise, no per-client state.
    public var handshakeChallengesMinted = 0
    /// RetryHandshake1s (0x14) whose cookie verified — the extra-round-
    /// trip admits that got in while require-cookie mode stood.
    public var handshakeCookiesVerified = 0
    /// RetryHandshake1s whose cookie did NOT verify (spoof/replay).
    public var handshakeCookiesRejected = 0
    /// Video frames the lifecycle machine refused to put on the wire
    /// (FROZEN's freezeDatagramSends, or a closed session).
    public var videoFramesSuppressed = 0
    /// HS-25: encoded frames too large for one protected FEC group
    /// (the GF(2⁸) 255-shard block) — dropped with the keyframe latch
    /// armed instead of thrown; one oversized frame must never kill
    /// the session.
    public var videoFramesUnprotectable = 0
    /// ModeTransitions emitted (HS-11's live evidence).
    public var modeTransitionsSent = 0
    /// Client input events delivered off the reliable stream (HS-13).
    public var inputEventsReceived = 0
    /// (seq, rx, inject) tuples sent back in 0x17 echo messages.
    public var inputEchoTuplesSent = 0
    /// 5 ms Opus packets accepted onto the wire (HS-15).
    public var audioPacketsIngested = 0
    /// Audio-channel datagrams sealed and enqueued: data shards +
    /// parity (6 per completed 4+2 group).
    public var audioDatagramsEnqueued = 0
    /// Completed 4+2 audio FEC groups.
    public var audioGroupsCompleted = 0
    /// Audio datagrams assembled by extending their pre-sized AAD header
    /// in place after sealing, avoiding a third header+payload array.
    public var audioSealedDatagramsAssembledInPlace = 0
    /// Audio packets refused because the session is closed. FROZEN and
    /// IDLE deliberately never count here — audio is the path probe
    /// and keeps flowing through both (W4b).
    public var audioPacketsSuppressed = 0
    /// HS-17: NACK entries consumed from parsed feedback reports.
    public var nackEntriesReceived = 0
    /// NACK entries that passed the gate and enqueued repairs.
    public var nacksHonored = 0
    /// NACK entries refused by the staleness ruling (any reason).
    public var nacksJudgedStale = 0
    /// Repair datagrams enqueued (fresh seqs on videoTail).
    public var repairDatagramsEnqueued = 0
    /// Stale verdicts that armed the coalesced keyframe latch.
    public var idrArmedOnStaleNack = 0
    /// Unknown-frame NACK arms refused by the peer-driven interval cap.
    public var unknownFrameIdrArmsThrottled = 0
    /// HS-32: explicit 0x23 repair refusals sent (stale-budget,
    /// superseded, unknown-frame — the verdicts the client can act
    /// on; FROZEN/closed and already-repaired stay silent by design).
    public var repairRefusalsSent = 0
    /// HS-32: NACKs honored under the opening-IDR exemption (nothing
    /// on glass yet — the last IDR repairable regardless of budget).
    public var openingExemptRepairsHonored = 0
    /// FEC regime steps applied to the packetizing seam.
    public var fecRegimeSteps = 0
    /// HS-18: 0x18 routing requests delivered (past the rule-3 gate).
    public var audioRoutingRequestsReceived = 0
    /// HS-18: 0x19 posture statuses sent.
    public var audioRoutingStatusesSent = 0
    /// CL-15: 0x1A clipboard sets delivered (past the rule-3 gate).
    public var clipboardSetsReceived = 0
    /// Tripwire: 0x25 track-state announcements sent.
    public var audioTrackStatesSent = 0
    /// Video posture: 0x26 announcements sent.
    public var videoPostureStatesSent = 0
    /// CL-15: 0x1B clipboard announces sent.
    public var clipboardAnnouncesSent = 0
    /// CL-15: leaf-reported changes the book/ceiling suppressed.
    public var clipboardAnnouncesSuppressed = 0
    /// E3: 0x24 cursor shapes sent.
    public var cursorShapesSent = 0
    /// E3: eye-reported shapes the dedupe/ceiling suppressed.
    public var cursorShapesSuppressed = 0
    /// F-3: decoded bulk messages delivered off chan 8's ordered
    /// stream (past the rule-3 gate).
    public var bulkMessagesReceived = 0
    /// F-3: sealed chan-8 datagrams carrying bulk ARQ frames, fresh
    /// and retransmit alike.
    public var bulkArqDatagramsSent = 0

    public init() {}
}

public final class Session {
    public enum Phase: Equatable, Sendable {
        case awaitingHandshake
        case established
    }

    public let config: SessionConfig
    /// Minted at init; rides every outbound datagram as TLV 0x01.
    public let connectionId: ConnectionId
    /// HS-12's decision machine; public for the loop's routing queries
    /// (primary tuple, send allowances) and the tests' state checks.
    public let validator: PathValidator
    public private(set) var phase: Phase
    public private(set) var clock = SessionClockStats()
    public private(set) var counters = SessionCounters()

    /// The completed Noise handshake's transcript hash — the sid the
    /// W6 pairing run binds to (decision §8.2). Nil before
    /// establishment and in insecure mode (nothing to pair against).
    public var handshakeHash: [UInt8]? { transport?.handshakeHash }

    private var channel: VideoChannel!
    /// HS-15: the audio channel's framer — 5 ms Opus packets → 4+2 RS
    /// groups → chan-1 envelopes. The session owns the seal and the
    /// pacer enqueue; the framer owns the audio seq/packet numbering.
    private var audio: AudioFramer!
    /// Nil until the handshake completes; always nil in insecure mode.
    private var transport: NoiseTransport?

    private var ctrlSeq = ChannelSeq(rawValue: 0)
    private var nextVideoFrameNumber = FrameNumber(rawValue: 0)
    /// Last frame admitted to packetization (nil before the first).
    public private(set) var lastAdmittedVideoFrameNumber: FrameNumber?

    /// The reliable CTRL sublayer (HS-8). Host clock domain: the
    /// endpoint's instants derive from the loop's monotonic `now`
    /// (µs = ns/1000) — the same CLOCK_MONOTONIC family the host-µs
    /// beacon/envelope domain bottoms out in on Linux.
    private var arq: ArqEndpoint<HostClock>
    /// The endpoint's next PTO deadline, in the `now` ns domain.
    private var nextArqWakeNS: UInt64?
    /// The session's CTRL plaintext ceiling: 1101 B with the conn-id
    /// TLV block and the AEAD tag both on every datagram (the HS-7
    /// accounting fix). ARQ poll output repacks to this.
    private let arqPayloadBudget: Int

    /// F-3: the bulk channel's OWN reliable sublayer (design record
    /// 20260728-053300 §2 — chan 8 runs its own ArqEndpoint, never the
    /// CTRL stream, so a file can never head-of-line-block a
    /// keystroke). Nil when the standing consent toggle left key 11
    /// undeclared: a toggle-off host owns no bulk machinery at all.
    private var bulkArq: ArqEndpoint<HostClock>?
    /// The bulk endpoint's next PTO deadline, in the `now` ns domain.
    private var nextBulkArqWakeNS: UInt64?
    /// Chan 8's envelope seq space (each channel numbers its own).
    private var bulkSeq = ChannelSeq(rawValue: 0)

    /// Message-1 admissions, consulted before any handshake allocation.
    private var handshakeGate: HandshakeGate
    /// The last require-cookie posture observed, so a flip surfaces as
    /// exactly one `.handshakeCookieModeChanged` (HS-21).
    private var lastCookieMode = false

    /// Whether the flood dial currently demands a retry cookie (HS-21) —
    /// surfaced for the shell's live log.
    public var handshakeCookieMode: Bool { handshakeGate.cookieMode }

    private var beaconSeq: UInt32 = 0
    private var nextBeaconAt: UInt64?
    private var lastEcho: ClockBeacon.LastEcho?
    private var clientKeyframePending = false

    // MARK: HS-11 lifecycle + W7 capabilities state

    /// The W4b machine, mediaSender role — nil until establishment
    /// (the machine "begins at establishment, in ACTIVE").
    private var machine: SessionStateMachine<HostClock>?
    /// The machine's next poll deadline, in the `now` ns domain.
    private var machineDeadlineNS: UInt64?
    /// The W7 negotiation machine, host role.
    private var negotiator: CapabilityNegotiator
    private var capabilitiesDeclared = false
    /// FROZEN's freezeDatagramSends: video ingest suppressed until
    /// RECOVERY's resume.
    private var videoFrozen = false
    /// A machine-demanded IDR (WAKE's arm or RECOVERY's force), merged
    /// into `takeFreshKeyframeRequest`. The estimator turned the
    /// policy into a number and re-paced the wire the moment the
    /// machine demanded it (HS-16).
    private var machineIdrPacing: IdrPacing?
    /// HS-25: an unprotectable frame was dropped at ingest — the next
    /// encoder poll owes a fresh IDR (merged into
    /// `takeFreshKeyframeRequest`) so the reference chain re-anchors.
    private var unprotectableKeyframePending = false
    /// HS-17's stale-NACK arm, split from the client-0x10 latch so the
    /// IDR books (the estimator-ramp hunt) can name which one minted a
    /// keyframe. Merged into the same poll; behavior unchanged.
    private var staleNackKeyframePending = false
    /// Last peer-driven `.unavailable` arm. Budget-stale NACKs are tied
    /// to real retained frames and remain unthrottled; only arbitrary
    /// unknown frame numbers can manufacture this pressure.
    private var lastUnknownFrameIdrArmAtNS: UInt64?
    /// The fall-repricing purge's arm: queued video was dropped
    /// mid-flight at a fall, so the next encoder poll owes a fresh
    /// IDR (merged into `takeFreshKeyframeRequest`).
    private var fallPurgeKeyframePending = false
    /// HS-32: EWMA (α = 1/8) of feedback-report inter-arrival, each
    /// sample clamped to the wire-pinned 25–50 ms cadence range; nil
    /// before the second parsed report (the derived budget then uses
    /// the 50 ms documented worst case).
    private var feedbackCadenceEwmaNS: UInt64?
    private var lastFeedbackParsedAtNS: UInt64?
    /// HS-32: sticky once a feedback report shows every video datagram
    /// through the opening IDR's group delivered (missing 0, received
    /// ≥ its shard count) — the host-visible proxy for "a frame
    /// plausibly completed at the client". Conservative-armed: any
    /// early loss keeps the opening exemption alive, which its
    /// attempt/byte bounds make safe.
    private var clientGlassEvidence = false
    private var openingIdrShardTotal: Int?
    private var openingExemptAttempts = 0
    private var openingExemptBytes = 0
    /// The converged ratchet frame awaiting its one-shot ride.
    private var convergedFrame:
        (annexB: [UInt8], frame: FrameNumber, captureMicros: UInt64)?
    /// HS-22: when the last damage note arrived — the idle-flip quiet
    /// clock. Nil until the first damage (convergence with no damage
    /// history flips immediately, the pre-HS-22 shape).
    private var lastDamageNoteAt: UInt64?
    /// HS-22: a convergence waiting out `idleFlipQuietNS`. The machine
    /// has NOT heard `.ratchetConverged` yet; `advance` feeds it once
    /// damage stays quiet, and fresh damage simply drops it (the
    /// session never leaves ACTIVE — no aborted handoff, no WAKE IDR
    /// owed on the next tick of a desktop metronome).
    private var pendingIdleFlipAt: UInt64?
    /// The in-flight final-frame one-shot; its full acknowledgment is
    /// the machine's `.finalFrameAcknowledged`.
    private var finalFrameGroup: ArqGroupId?
    /// One-shot group ids are session-allocated, serially ascending.
    private var nextOneShotGroup: UInt16 = 1
    /// The HS-16 congestion estimator: send ledger + delivery-rate/
    /// queuing-delay/loss evidence → the pacer's setRate seam, W4b's
    /// RECOVERY window verdicts, and the IdrPacing numbers.
    private let estimator: RateEstimator
    /// The `now` of the pump pass currently draining the pacer — the
    /// send instant the estimator's ledger records (the sink closure
    /// has no clock of its own; sans-IO means the caller's `now` is
    /// the only truth).
    private var pumpNowNS: UInt64
    private let sendAccounting: SessionSendAccounting
    /// Datagrams released by the pacer but not yet accepted by the socket.
    /// Their release pace is retained for honest train classification;
    /// video frames remain backlog/NACK-recused until confirmation.
    private var socketPendingPaces: [UInt32: Int] = [:]
    private var socketPendingVideo:
        [UInt32: (datagrams: Int, bytes: Int)] = [:]

    // MARK: HS-13 input state

    /// The seq of the last input event the shell REPORTED injected —
    /// stamped on every subsequent video frame's shards as TLV 0x03
    /// (the overview's "stamps lastInputSeq into the next frame"),
    /// which is what lets the client close per-keystroke
    /// input-to-photon. Nil until the first injection; never cleared.
    public private(set) var lastInputSeq: UInt32?
    /// Echo tuples awaiting their 0x17 ride; flushed on `advance` (and
    /// eagerly once a full message accumulates).
    private var pendingEchoTuples: [InputEchoTuple] = []

    /// The lifecycle machine's state; nil before establishment.
    public var lifecycleState: SessionState? { machine?.state }
    /// The wire mode beneath any overlay; nil before establishment.
    public var wireMode: SessionWireMode? { machine?.wireMode }
    /// Why the session closed, once it has.
    public var sessionCloseReason: SessionCloseReason? { machine?.closeReason }
    /// The agreed capability set; nil until the client's declaration
    /// lands (the CL-7 client does not send one yet — nil is the
    /// grandfathered pre-W7 posture, not an error).
    public var agreedCapabilities: Capabilities? { negotiator.agreed }
    /// HS-18: true when hostAudioRouting (key 9) survived the
    /// intersection — both ends declared it byte-equal. Gates 0x18
    /// consumption and 0x19 emission.
    public var agreedHostAudioRouting: Bool {
        negotiator.agreed?.hostAudioRouting == true
    }
    /// The tripwire's gate: true when audioQuietPosture (key 15)
    /// survived the intersection. The audio leg gates transmission
    /// ONLY under this agreement — a legacy client keeps the
    /// always-on contract, silence included.
    public var agreedAudioQuietPosture: Bool {
        negotiator.agreed?.audioQuietPosture == true
    }
    /// The video ladder's gate: true when videoQuietPosture (key 16)
    /// survived the intersection — the keepalive backs off only under
    /// this agreement.
    public var agreedVideoQuietPosture: Bool {
        negotiator.agreed?.videoQuietPosture == true
    }
    /// CL-15: true when clipboardText (key 10) survived the
    /// intersection. Gates 0x1A consumption and 0x1B emission.
    public var agreedClipboardText: Bool {
        negotiator.agreed?.clipboardText == true
    }
    /// F-3: true when bulkTransfer (key 11) survived the intersection.
    /// Gates chan-8 ingest and `sendBulk` — declaration is dialect,
    /// consent is the standing toggle that decided whether key 11 was
    /// declared at all (design record 20260728-053300 §6).
    public var agreedBulkTransfer: Bool {
        negotiator.agreed?.bulkTransfer == true
    }
    /// P-1: true when the image gate (keys 10 ∧ 12) survived the
    /// intersection. Gates 0x22 consumption and image cargo emission.
    /// Key 11 is deliberately not consulted — the file-drop consent
    /// must not couple to the clipboard tier.
    public var agreedClipboardImages: Bool {
        negotiator.agreed?.clipboardImagesAgreed == true
    }
    /// E3: true when cursorShape (key 13) survived the intersection.
    /// Gates 0x24 emission — only the direct eye declares the key,
    /// and only a shape-capable client answers it.
    public var agreedCursorShape: Bool {
        negotiator.agreed?.cursorShape == true
    }

    /// CL-15: the loop-prevention/dedupe books (design doc §5) — one
    /// per session, shared by the 0x1A consume path (pre-arms echo
    /// suppression) and `noteHostClipboardChanged` (judges the leaf's
    /// change signals). P-1 keys images into the SAME book (0xFF ‖
    /// sha256 — disjoint from any text's UTF-8 by construction), so
    /// cross-modal moves stay honest.
    private var clipboardBook = ClipboardSyncBook()
    /// E3: the last 0x24 actually sent — the dedupe slot (nil until
    /// the first send, so a fresh session always passes the eye's
    /// standing shape through).
    private var lastSentCursorShape: CursorShape?

    /// P-1: the clipboard-image lane — F-2's engines driven with
    /// memory-backed cargo, one per session. Inert unless the image
    /// gate (keys 10 ∧ 12) agreed: every entry point checks first.
    private var clipboardImageChannel = ClipboardImageChannel()
    /// Id mint for image cargo (sans-IO: the init's injected
    /// generator, boxed so the stored property stays concrete).
    private var imageRng: BoxedRng

    /// P-1: the image lane's own books (share/apply/refuse verdicts).
    public var clipboardImageCounters: ClipboardImageChannelCounters {
        clipboardImageChannel.counters
    }

    /// - Parameters:
    ///   - clientTuple: the peer's 4-tuple at session start — the
    ///     validator's initial (trusted) path. In Noise mode this is
    ///     where message 1 arrived from; in insecure mode the fixed
    ///     configured peer.
    ///   - send: receives every outbound datagram in pacer order. The
    ///     loop maps `pacerClass` → TOS and `destination` (nil = the
    ///     primary path) → the socket call.
    public init(
        config: SessionConfig,
        clientTuple: FourTuple,
        now: UInt64,
        rng: some RandomNumberGenerator = SystemRandomNumberGenerator(),
        sendAccounting: SessionSendAccounting = .pacerRelease,
        send: @escaping (VideoChannelDatagram) -> Void
    ) {
        var rng = rng
        self.config = config
        self.connectionId = ConnectionId.random(using: &rng)
        // Every session datagram carries the conn-id TLV (11 B) and
        // reserves the AEAD tag (16 B) — insecure mode included, the
        // §4.2 geometry rule — so the reliable sublayer's segments must
        // fit 1101 B, not the bare table's 1112 B.
        self.arqPayloadBudget = min(
            WireBudget.maxPlaintextShardByteCount,
            WireBudget.maxWirePayloadByteCount
                - WireBudget.aeadTagByteCount
                - (1 + 2 + ConnectionId.byteCount)
        )
        var arqConfig = config.arq
        arqConfig.maxSegmentBodyByteCount = min(
            arqConfig.maxSegmentBodyByteCount,
            arqPayloadBudget - ArqBounds.segmentHeaderByteCount
        )
        self.arq = ArqEndpoint(channel: .ctrl, config: arqConfig)
        // F-3/P-1: the bulk endpoint exists exactly when something
        // declared chan-8 carriage — key 11 (the standing file-drop
        // consent) or key 12 (the clipboard-image dialect; its cargo
        // rides the same stream). A host declaring neither has no
        // chan-8 machinery to confuse. Same clamped config as CTRL:
        // the default 262,144 B message budget clears a max chunk
        // message (17 B + 128 KiB) with 2× headroom.
        self.bulkArq = (config.capabilities.bulkTransfer
            || config.capabilities.clipboardImages)
            ? ArqEndpoint(channel: .bulkTransfer, config: arqConfig)
            : nil
        self.imageRng = BoxedRng(base: rng)
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
        self.negotiator = CapabilityNegotiator(
            role: .host, local: config.capabilities
        )
        self.validator = PathValidator(
            connectionId: connectionId,
            initialPath: clientTuple,
            now: now,
            config: config.path,
            rng: rng
        )
        switch config.crypto {
        case .noise:
            self.phase = .awaitingHandshake
        case .insecure:
            // No handshake to wait for; the session-start beacon (and
            // the capability declaration) leave on the first `advance`.
            self.phase = .established
            self.nextBeaconAt = now
            self.machine = SessionStateMachine(
                role: .mediaSender,
                config: config.lifecycle,
                now: HostTimestamp(microseconds: now / 1_000)
            )
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
            // The estimator's send ledger taps the sink: every datagram
            // the pacer releases is recorded (channel, seq) →
            // (instant, wire bytes) so the client's dispersion samples
            // can be matched back to their trains (HS-16). The send
            // instant is the pump pass's `now` — the sink has no clock.
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

        let envelope: Envelope
        let payload: ArraySlice<UInt8>
        do {
            (envelope, payload) = try Envelope.decode(datagram)
        } catch {
            counters.dropped += 1
            return [.dropped(.malformedEnvelope)]
        }
        guard !envelope.channel.isReserved else {
            counters.dropped += 1
            return [.dropped(.reservedChannel(envelope.channel.rawValue))]
        }

        let claimed: ConnectionId?
        do {
            claimed = try ConnectionId.decode(extensions: envelope.extensions)
        } catch {
            counters.dropped += 1
            return [.dropped(.duplicateConnectionIdTlv)]
        }

        // The HS-12 demux trigger fires on the raw arrival, before any
        // unseal — path probing must work exactly when decryption of a
        // migrated datagram would (the challenge, not the AEAD, proves
        // the address).
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

        if phase == .awaitingHandshake {
            guard case .noise(let hostStatic) = config.crypto else {
                counters.dropped += 1 // unreachable: insecure never waits
                events.append(.dropped(.notEstablished(envelope.channel.rawValue)))
                return events
            }
            // Two admissible first words: a bare Noise message 1 (0x05)
            // or a RetryHandshake1 (0x14) echoing a cookie the host
            // minted under flood (HS-21/W8). Anything else is
            // pre-establishment noise.
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
                    events.append(.dropped(.malformedCtrl))
                    return events
                }
                presentedCookie = resubmission.cookie[...]
                message1 = resubmission.message1[...]
            default:
                counters.dropped += 1
                events.append(.dropped(.notEstablished(envelope.channel.rawValue)))
                return events
            }

            let admission = handshakeGate.admitMessage1(
                presentedCookie: presentedCookie,
                clientTuple: Self.cookieTuple(tuple),
                message1: message1,
                now: now
            )
            events += noteCookieModeTransition()
            switch admission {
            case .admit:
                events += completeHandshake(
                    message1: message1,
                    hostStatic: hostStatic,
                    now: now,
                    hostMicroseconds: hostMicroseconds
                )
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
            if presentedCookie != nil, case .admit = admission {
                counters.handshakeCookiesVerified += 1
            }
            return events
        }

        // Established: exact received header bytes as AAD, then unseal.
        let aad = datagram[datagram.startIndex..<payload.startIndex]
        let plaintext: [UInt8]
        do {
            plaintext = try unsealPayload(payload, aad: aad, envelope: envelope)
        } catch {
            counters.unsealFailures += 1
            events.append(.dropped(.unsealFailed(envelope.channel.rawValue)))
            return events
        }

        switch envelope.channel {
        case .ctrl:
            // Any authenticated CTRL arrival is liveness/FROZEN-exit
            // evidence, but deliberately NOT the 350 ms detector's
            // (W4b: 1 Hz beacons cannot drive a 350 ms detector).
            events += runMachine(
                .ctrlEvidence, now: now, hostMicroseconds: hostMicroseconds
            )
            events += dispatchCtrl(
                plaintext, from: tuple,
                now: now, hostMicroseconds: hostMicroseconds
            )
        case .feedback:
            counters.feedbackDatagrams += 1
            // The media-path proof stream: feeds the blackout detector
            // (any authenticated chan-3 arrival — a malformed interior
            // is still an arrival on the media path).
            events += runMachine(
                .mediaPathEvidence, now: now, hostMicroseconds: hostMicroseconds
            )
            events += ingestFeedback(
                plaintext, now: now, hostMicroseconds: hostMicroseconds
            )
        case .bulkTransfer:
            // Liveness evidence like CTRL (an authenticated arrival
            // proves the peer), deliberately NOT the 350 ms detector's.
            events += runMachine(
                .ctrlEvidence, now: now, hostMicroseconds: hostMicroseconds
            )
            // The W7 rule-3 gate (F-3/P-1): chan-8 traffic outside
            // BOTH agreements (key 11 files, keys 10∧12 images) is a
            // peer using a superpower it never negotiated — dropped
            // loud. Message-level routing separates the two lanes.
            guard agreedBulkTransfer || agreedClipboardImages,
                  bulkArq != nil else {
                counters.dropped += 1
                events.append(.dropped(.bulkNotNegotiated))
                return events
            }
            events += absorbBulkArq(
                bulkArq!.ingest(
                    payload: plaintext[...], now: arqInstant(now)
                ),
                now: now, hostMicroseconds: hostMicroseconds
            )
            events += serviceBulkArq(
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

    // MARK: Video

    /// One encoded frame into the sealed, paced, conn-id-tagged stream.
    /// The session owns frame numbering (from 0). Throws
    /// `SessionError.notEstablished` before the transport exists, and
    /// whatever the packetize/seal path throws — loud, per W2.
    @discardableResult
    public func ingestVideoFrame(
        _ annexB: [UInt8],
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        interleave: (() -> Void)? = nil,
        now: UInt64
    ) throws -> Int {
        try ingestVideoFrameBytes(
            annexB, captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, interleave: interleave, now: now,
            isBorrowed: false)
    }

    /// Borrowed encoder-buffer ingress. The pointer is consumed
    /// synchronously and is never retained past this call.
    @discardableResult
    public func ingestVideoFrame(
        _ annexB: UnsafeBufferPointer<UInt8>,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        interleave: (() -> Void)? = nil,
        now: UInt64
    ) throws -> Int {
        try ingestVideoFrameBytes(
            annexB, captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe, interleave: interleave, now: now,
            isBorrowed: true)
    }

    private func ingestVideoFrameBytes<C>(
        _ annexB: C,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        interleave: (() -> Void)?,
        now: UInt64,
        isBorrowed: Bool
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
            interleave: interleave,
            now: now,
            isBorrowed: isBorrowed
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
        // FROZEN's freezeDatagramSends (and the terminal state): the
        // encoder may keep producing, the wire goes quiet. Suppressed
        // frames are counted, never thrown — the loop must not die
        // because the path did.
        if videoFrozen || machine?.state == .closed {
            counters.videoFramesSuppressed += 1
            return nil
        }
        // HS-25: a frame beyond what one FEC group can protect is
        // UNSHIPPABLE (the 255-shard GF(2⁸) block; the fec field binds
        // one group per frame number, so splitting is a wire-contract
        // change, not an option here). Throwing killed the live session
        // — the 279-shard IDR at the 50 Mbps/p4 recipe — so the frame
        // is dropped instead: counted, its frame number unconsumed (the
        // client sees no numbering gap), and a fresh IDR armed through
        // the same coalesced latch client 0x10s pull, because whatever
        // referenced the dropped frame must be re-anchored. The shell's
        // opening VBV cap makes the re-encode fit by construction.
        let ceiling = channel.maxProtectableFrameByteCount(
            hasLastInputSeq: lastInputSeq != nil
        )
        guard encodedByteCount <= ceiling else {
            counters.videoFramesUnprotectable += 1
            unprotectableKeyframePending = true
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

    /// Ordered locked half. Channel seq allocation, Noise sealing, enqueue,
    /// repair retention, and frame-number advancement remain one critical
    /// section with every other Session mutation.
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
        if videoFrozen || machine?.state == .closed {
            counters.videoFramesSuppressed += 1
            return 0
        }
        guard context.frameNumber == nextVideoFrameNumber else {
            throw SessionError.staleVideoPreparation
        }
        let shards = try channel.ingestPrepared(
            prepared,
            frameNumber: context.frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            lastInputSeq: context.lastInputSeq,
            interleave: interleave,
            now: now,
            isBorrowed: isBorrowed
        )
        // HS-32: the opening exemption's glass proxy needs the first
        // IDR's group size — "received everything through this group"
        // is the evidence that something plausibly decoded.
        if prepared.isKeyframe, openingIdrShardTotal == nil {
            openingIdrShardTotal = shards
        }
        lastAdmittedVideoFrameNumber = context.frameNumber
        nextVideoFrameNumber = nextVideoFrameNumber.next
        return shards
    }

    // MARK: Audio (HS-15)

    /// One 5 ms Opus packet onto the sealed, paced, conn-id-tagged
    /// audio channel: the AudioFramer cuts it into chan-1 datagrams
    /// (its own data shard now; the group's 2 parity shards behind the
    /// 4th packet), each sealed with the exact header bytes as AAD —
    /// the same discipline as every other datagram — and enqueued at
    /// PacerClass.audio, structurally above every video class.
    ///
    /// Lifecycle ruling, deliberate and pinned by the gate tests:
    /// audio flows in ACTIVE, IDLE, FROZEN, and RECOVERY — W4b's
    /// FROZEN is "datagram VIDEO stops, audio continues as the path
    /// probe", and the overview's idle silence is "audio and the
    /// beacon keep flowing". The continuous 5 ms cadence is what lets
    /// the client's blackout detector tighten to 350 ms (CL-8's
    /// deviation note) and is the always-on queue-delay sensor
    /// (resiliency §2), so `videoFrozen` is consulted nowhere here.
    /// Only `closed` suppresses (counted, never thrown — the audio
    /// thread must not die because the session did). Throws
    /// `SessionError.notEstablished` before the transport exists, and
    /// what the framer/seal path throws — loud, per W2.
    @discardableResult
    public func ingestAudioPacket(
        _ packet: [UInt8],
        captureTimestampMicroseconds: UInt64,
        now: UInt64
    ) throws -> Int {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        if machine?.state == .closed {
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
        return datagrams.count
    }

    /// Header bytes are the AAD and then become the final datagram buffer.
    /// Noise still owns and advances its sequence exactly once in
    /// `sealPayload`; only the post-seal assembly changes.
    private func encodeSealedAudio(
        envelope: Envelope, plaintext: [UInt8]
    ) throws -> [UInt8] {
        var header = try envelope.encode(payload: [])
        header.reserveCapacity(
            header.count + plaintext.count + WireBudget.aeadTagByteCount
        )
        let sealed = try sealPayload(
            plaintext[...], aad: header[...], envelope: envelope
        )
        guard sealed.count <= WireBudget.maxWirePayloadByteCount else {
            throw WireError.payloadOverBudget(sealed.count)
        }
        let total = header.count + sealed.count
        guard total <= WireBudget.maxDatagramByteCount else {
            throw WireError.datagramOverBudget(total)
        }
        header.append(contentsOf: sealed)
        counters.audioSealedDatagramsAssembledInPlace += 1
        return header
    }

    /// Audio datagrams still waiting in the shared pacer — the audio
    /// thread's bounded "make sure it left" loop reads this (HS-15).
    public var queuedAudioDatagramCount: Int {
        channel.queuedCount(.audio)
    }

    /// Video-class bytes (fresh + repair tail) still waiting in the
    /// shared pacer — the capture loop's backpressure gate reads this
    /// (the fps-ceiling fix): at 8×this/pacerRate of standing wire
    /// time, encoding another capture frame only deepens the queue,
    /// so the frame is skipped pre-encode instead (the same drop that
    /// used to happen invisibly at the PipeWire buffer pool while the
    /// loop thread sat inside a synchronous drain).
    public var queuedVideoBytes: Int {
        channel.queuedBytes(.freshVideo) + channel.queuedBytes(.videoTail)
            + socketPendingVideo.values.reduce(0) { $0 + $1.bytes }
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

    /// The encoder-loop poll (one per tick, before encoding): true when
    /// a fresh IDR is owed — HS-12's path promotion, a client 0x10 IDR
    /// request, or the lifecycle machine's demand (WAKE's
    /// armNextDamageAsIdr, RECOVERY's forceIdr). Clears every source;
    /// fires once per demand.
    public func takeFreshKeyframeRequest() -> Bool {
        !takeFreshKeyframeDemand().isEmpty
    }

    /// The same poll with its causes attached — the estimator-ramp
    /// hunt's IDR books need to NAME why each keyframe was minted, not
    /// just that one was owed. Clears every source; a demand may carry
    /// several causes (they coalesced into the one frame).
    public func takeFreshKeyframeDemand() -> FreshKeyframeDemand {
        var demand: FreshKeyframeDemand = []
        if validator.takeFreshKeyframeRequest() {
            demand.insert(.pathPromotion)
        }
        if clientKeyframePending { demand.insert(.clientRequest) }
        switch machineIdrPacing {
        case .lastGoodRate: demand.insert(.machineWake)
        case .halfStaleEstimate: demand.insert(.machineRecovery)
        case nil: break
        }
        if staleNackKeyframePending { demand.insert(.staleNackArm) }
        if unprotectableKeyframePending {
            demand.insert(.unprotectableDrop)
        }
        if fallPurgeKeyframePending { demand.insert(.fallPurge) }
        clientKeyframePending = false
        machineIdrPacing = nil
        staleNackKeyframePending = false
        unprotectableKeyframePending = false
        fallPurgeKeyframePending = false
        return demand
    }

    // MARK: Lifecycle inputs (HS-11)

    /// The encoder loop's damage note: call when a FRESH damage frame
    /// arrives from capture, BEFORE encoding it. In IDLE this is the
    /// WAKE — mode=active leaves on the reliable stream and the damage
    /// frame is owed as an IDR (`takeFreshKeyframeRequest` turns true,
    /// paced at the healthy-path rate once HS-16 owns numbers). In
    /// ACTIVE it aborts a pending idle flip: new damage during the
    /// convergence handoff means the session never left ACTIVE.
    public func noteDamage(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        convergedFrame = nil
        lastDamageNoteAt = now
        pendingIdleFlipAt = nil
        return runMachine(.damage, now: now, hostMicroseconds: hostMicroseconds)
    }

    /// The HS-13 seam, now wired: an injected input event pre-arms the
    /// wake IDR before its damage exists (W4b's pre-arm rule — a
    /// keypress during a blackout persists through FROZEN and is
    /// consumed exactly once by RECOVERY's IDR). `consumeReliable`'s
    /// 0x16 arm calls this on every delivered input event; it stays
    /// public for shells with input paths of their own.
    public func notePreArmInput(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        runMachine(.preArmInput, now: now, hostMicroseconds: hostMicroseconds)
    }

    /// The shell's injection report (HS-13): the event with `seq` was
    /// handed to the desktop session at `injectedAtMicroseconds` (host
    /// µs, the beacon domain). Buffers one echo tuple — flushed as 0x17
    /// messages (≤ 32 tuples each) on the next `advance` — and moves
    /// the lastInputSeq stamp every later video frame carries.
    /// Buffering only, no sends: safe to call while iterating the very
    /// events that delivered the input.
    public func noteInputInjected(
        seq: UInt32,
        receivedAtMicroseconds: UInt64,
        injectedAtMicroseconds: UInt64
    ) {
        lastInputSeq = seq
        pendingEchoTuples.append(InputEchoTuple(
            seq: seq,
            receivedMicroseconds: receivedAtMicroseconds,
            injectedMicroseconds: injectedAtMicroseconds
        ))
    }

    /// Pending tuples onto the reliable stream, ≤ maxTupleCount per
    /// 0x17 message. A refused send is loud, not fatal, and the tuples
    /// stay queued for the next flush.
    private func flushInputEchoes(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard phase == .established, !pendingEchoTuples.isEmpty else {
            return []
        }
        var events: [SessionEvent] = []
        while !pendingEchoTuples.isEmpty {
            let batch = Array(
                pendingEchoTuples.prefix(InputEcho.maxTupleCount)
            )
            do {
                try sendReliable(
                    InputEcho(tuples: batch).encode(),
                    now: now, hostMicroseconds: hostMicroseconds
                )
            } catch {
                events.append(.sendFailed("input echo: \(error)"))
                break
            }
            pendingEchoTuples.removeFirst(batch.count)
            counters.inputEchoTuplesSent += batch.count
        }
        return events
    }

    /// HS-18: the shell's report that the audio leaf is now RUNNING in
    /// `mode` — at session start (once capabilities agree) and after
    /// every applied 0x18 flip. Emits the 0x19 status the client's
    /// control strip renders. Silently a no-op unless the agreed set
    /// carries hostAudioRouting: a legacy client neither asked for the
    /// key nor knows the byte, so the status would be noise (the same
    /// absence-is-unsupported rule that hides the client's button).
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

    /// The tripwire's announcement: quiet when the gate closes and on
    /// every ~5 s still-quiet check-in, active the instant it fires
    /// (immediately before the pre-roll burst). Silently a no-op
    /// unless key 15 survived intersection — the noteAudioRoutingApplied
    /// rule: a legacy client neither asked for the key nor knows the
    /// byte.
    public func noteAudioTrackState(
        _ state: AudioTrackState.State, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedAudioQuietPosture else { return [] }
        do {
            try sendReliable(
                AudioTrackState(state: state).encode(),
                now: now, hostMicroseconds: hostMicroseconds
            )
            counters.audioTrackStatesSent += 1
            return [.audioTrackStateSent(state)]
        } catch {
            return [.sendFailed("audio track state: \(error)")]
        }
    }

    /// The video posture's announcement: one 0x26 per ladder step and
    /// one on the wake back to active. Silently a no-op unless key 16
    /// survived intersection (the noteAudioRoutingApplied rule).
    public func noteVideoPostureState(
        _ state: VideoPostureState, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedVideoQuietPosture else { return [] }
        do {
            try sendReliable(
                state.encode(), now: now, hostMicroseconds: hostMicroseconds
            )
            counters.videoPostureStatesSent += 1
            return [.videoPostureStateSent(state)]
        } catch {
            return [.sendFailed("video posture state: \(error)")]
        }
    }

    /// CL-15: the shell's report that the OS clipboard changed (the
    /// HostClipboardLeaf's onLocalChange, both genuine host copies AND
    /// the echoes of our own client-set applies — the book tells them
    /// apart). Judges the agreement, the book, and the ceiling before
    /// a 0x1B leaves. Silently a no-op unless the agreed set carries
    /// clipboardText (the noteAudioRoutingApplied rule: a legacy
    /// client neither asked for the key nor knows the byte) or when
    /// the leaf reports an empty clipboard (v1 does not sync
    /// clearing). Payloads never appear in events or logs — byte
    /// counts only.
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
            // Over the v1 ceiling: routine weather (a huge host copy),
            // suppressed and counted, never an error.
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

    /// E3: the eye's report that the hardware cursor plane changed —
    /// a content-cropped BGRA shape or the hidden state. Judges the
    /// agreement, the dedupe slot, and the wire contract before a
    /// 0x24 leaves. Silently a no-op unless the agreed set carries
    /// cursorShape (the noteAudioRoutingApplied rule: a legacy or
    /// portal-era peer neither asked for the key nor knows the
    /// byte). Pixels never appear in events or logs — counts only.
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
            // An over-ceiling crop or hostile geometry from the eye:
            // suppressed and counted — the client keeps wearing the
            // previous shape, never an error.
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

    /// P-1: the shell's report that the OS clipboard now holds an
    /// image — the leaf's PNG read (genuine host copies AND the
    /// echoes of our own applies; the shared book tells them apart,
    /// keyed 0xFF ‖ sha256). Judges the gate, the book, the send
    /// lane, and the 32 MiB ceiling before cargo leaves on chan 8.
    /// Silently a no-op unless the image gate (keys 10 ∧ 12)
    /// survived intersection. Payloads never appear in events or
    /// logs — byte counts only.
    public func noteHostClipboardImageChanged(
        _ data: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard agreedClipboardImages, phase == .established else {
            return []
        }
        let channelEvents = clipboardImageChannel.shareLocalImage(
            data, sha256: Sha256.digest(data),
            book: &clipboardBook, rng: &imageRng
        )
        var events = processImageEvents(channelEvents, now: now)
        events += serviceBulkArq(
            now: now, hostMicroseconds: hostMicroseconds
        )
        return events
    }

    /// The ratchet's all-skip stop (HS-3's detector via HS-11): retains
    /// the final converged frame and starts the idle handoff — the
    /// frame rides a reliable one-shot group, and ONLY its full
    /// acknowledgment flips the wire mode to IDLE (the receiver must
    /// hold the converged frame before it learns the session went
    /// idle). When the agreed capabilities say the client does not
    /// speak idle silence, the session stays ACTIVE.
    ///
    /// HS-22: the handoff additionally waits out `idleFlipQuietNS`
    /// from the LAST damage note (the machine hears `.ratchetConverged`
    /// from `advance` once the quiet holds; fresh damage meanwhile
    /// drops the pending flip). A desktop metronome — a 1 Hz clock, a
    /// blinking cursor — used to converge, flip to IDLE, and pay a
    /// full-frame WAKE IDR on its next beat, every beat: the owner's
    /// "1 Hz blur while paused". The idle→active-restarts-with-an-IDR
    /// decision of record is untouched; the session just refuses to
    /// enter IDLE between the beats of a ticker.
    public func noteRatchetConverged(
        finalFrame annexB: [UInt8],
        captureTimestampMicroseconds: UInt64,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        if let agreed = negotiator.agreed, !agreed.idleSilence { return [] }
        guard !annexB.isEmpty, nextVideoFrameNumber.rawValue > 0 else {
            return []
        }
        convergedFrame = (
            annexB,
            FrameNumber(rawValue: nextVideoFrameNumber.rawValue &- 1),
            captureTimestampMicroseconds
        )
        if let damagedAt = lastDamageNoteAt,
           now &- damagedAt < config.idleFlipQuietNS {
            pendingIdleFlipAt = damagedAt &+ config.idleFlipQuietNS
            return []
        }
        pendingIdleFlipAt = nil
        return runMachine(
            .ratchetConverged, now: now, hostMicroseconds: hostMicroseconds
        )
    }

    /// An orderly local close: the typed SessionTeardown leaves on the
    /// reliable stream and the machine closes. The teardown segment
    /// retransmits until acknowledged — keep servicing `advance` until
    /// `arqIsQuiescent` (or patience runs out) before exiting.
    public func beginTeardown(
        reason: SessionTeardownReason, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        runMachine(
            .teardownRequest(reason),
            now: now, hostMicroseconds: hostMicroseconds
        )
    }

    // MARK: Reliable CTRL (HS-8)

    /// Queues one message on the reliable ordered CTRL stream (ARQ
    /// group 0): exactly-once, in-order delivery, RTT-adaptive
    /// retransmit until acknowledged. The message must start with its
    /// own CTRL type byte (the registry rule). Throws
    /// `SessionError.notEstablished` before the transport exists —
    /// reliable CTRL is sealed traffic — and `ArqSendError` for an
    /// empty or over-budget message.
    public func sendReliable(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) throws {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        try arq.send(message: message, now: arqInstant(now))
        _ = serviceArq(now: now, hostMicroseconds: hostMicroseconds)
    }

    /// Queues one one-shot group's single message (non-zero, serially
    /// ascending group ids — caller-allocated). The group retransmits
    /// independently of the ordered stream and of every other one-shot;
    /// full acknowledgment surfaces as `.reliableOneShotAcknowledged`.
    public func sendReliableOneShot(
        _ message: [UInt8],
        group: ArqGroupId,
        now: UInt64,
        hostMicroseconds: UInt64
    ) throws {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        try arq.sendOneShot(message: message, group: group, now: arqInstant(now))
        _ = serviceArq(now: now, hostMicroseconds: hostMicroseconds)
    }

    /// True when the reliable sublayers (CTRL and, when it exists, the
    /// bulk channel's) have nothing left to send, retransmit, or
    /// acknowledge (the W-G4 termination property, exposed for the
    /// loop's idle accounting and the gate tests). The teardown drain
    /// waits on both: a final bulk ack/abort deserves its retransmits
    /// exactly like the teardown message itself.
    public var arqIsQuiescent: Bool {
        arq.isQuiescent && (bulkArq?.isQuiescent ?? true)
    }

    // MARK: The bulk channel (F-3)

    /// Queues one bulk message (the 0x1C–0x21 sextet's bytes — the
    /// shell's accept/ack/complete/abort answers) on chan 8's ARQ
    /// ordered stream. Exactly-once, in-order, RTT-adaptive
    /// retransmit, on the bulk channel's OWN endpoint — never CTRL.
    /// Throws `SessionError.notEstablished` before the transport
    /// exists and `SessionError.bulkNotNegotiated` unless key 11
    /// survived intersection (the shell never legitimately speaks
    /// before an offer arrived, and offers only arrive negotiated).
    public func sendBulk(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) throws {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        guard agreedBulkTransfer, bulkArq != nil else {
            throw SessionError.bulkNotNegotiated
        }
        try bulkArq!.send(message: message, now: arqInstant(now))
        _ = serviceBulkArq(now: now, hostMicroseconds: hostMicroseconds)
    }

    /// Chan-8 ingest events → session events: delivered messages
    /// decode through the frozen codecs; the 0x22 marker and
    /// clipboard-claimed bulk messages feed the image lane (P-1),
    /// everything else surfaces as `.bulkMessageReceived` for the
    /// shell's BulkReceiveShell.
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
            case .ignored(let reason):
                counters.arqIgnored += 1
                events.append(.arqIgnored(reason))
            }
        }
        return events
    }

    /// One chan-8 ARQ-delivered message through the P-1 routing
    /// question: marker → image lane; claimed id → image lane;
    /// everything else → the file lane (which still demands its own
    /// key-11 agreement — the two lanes' gates are independent).
    private func consumeBulkStreamMessage(
        _ bytes: [UInt8], now: UInt64
    ) -> [SessionEvent] {
        if bytes.first == CtrlMessageType.clipboardImageCargo {
            guard let cargo = try? ClipboardImageCargo.decode(bytes)
            else {
                counters.dropped += 1
                return [.dropped(.malformedBulk)]
            }
            // The W7 rule-3 gate, keys 10 ∧ 12 (P-1): image cargo
            // outside the agreement is a peer using a superpower it
            // never negotiated. Dropped loud, never fatal.
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
                clipboardImageChannel.ingest(
                    message, book: &clipboardBook,
                    sha256: Sha256.digest
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

    /// Image-lane channel events → chan-8 sends + session events.
    /// Callers owe a `serviceBulkArq` pass afterward (the receive
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
                    try bulkArq?.send(
                        message: bytes, now: arqInstant(now)
                    )
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

    /// Polls the bulk endpoint and puts its output on the wire —
    /// `serviceArq`'s shape on chan 8: repack to the session's real
    /// plaintext budget, seal with the exact header bytes as AAD, and
    /// enqueue at the pacer's `.bulk` class, the ladder's tail.
    private func serviceBulkArq(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard phase == .established, bulkArq != nil else { return [] }
        let (payloads, deadline) = bulkArq!.poll(now: arqInstant(now))
        nextBulkArqWakeNS = deadline.map { $0.microseconds &* 1_000 }
        guard !payloads.isEmpty else { return [] }

        var events: [SessionEvent] = []
        do {
            for payload in try repackArq(payloads) {
                try sendBulkDatagram(
                    body: payload,
                    now: now, hostMicroseconds: hostMicroseconds
                )
                counters.bulkArqDatagramsSent += 1
            }
        } catch {
            // Segments the poll marked sent stay armed on their PTO
            // timers — a refused send heals like a lost datagram.
            events.append(.sendFailed("bulk arq: \(error)"))
        }
        return events
    }

    /// One chan-8 body onto the wire: conn-id-tagged envelope, header
    /// bytes as AAD, sealed under the transport, then the pacer's
    /// `.bulk` class of the shared schedule.
    private func sendBulkDatagram(
        body: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) throws {
        let envelope = Envelope(
            channel: .bulkTransfer,
            seq: bulkSeq,
            frame: FrameNumber(rawValue: 0),
            timestamp: hostMicroseconds,
            fec: 0,
            extensions: [connectionId.wireExtension]
        )
        let header = try envelope.encode(payload: [])
        let payload = try sealPayload(
            body[...], aad: header[...], envelope: envelope
        )
        let bytes = try envelope.encode(payload: payload)
        bulkSeq = bulkSeq.next
        channel.enqueueBulk(bytes, seq: envelope.seq, now: now)
    }

    private func arqInstant(_ now: UInt64) -> HostTimestamp {
        HostTimestamp(microseconds: now / 1_000)
    }

    /// Ingest events → session events, with the counters kept honest.
    /// Lifecycle (0x09/0x0A) and capability (0x0F/0x11/0x12) messages
    /// are consumed here — the session IS their registered consumer
    /// (the HS-9 dispatch pattern, one layer down); everything else
    /// (the pairing quartet, future types) surfaces as `.reliableCtrl`
    /// for the shell.
    private func absorbArq(
        _ arqEvents: [ArqEvent], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for event in arqEvents {
            switch event {
            case .message(let group, let bytes):
                counters.arqMessages += 1
                if let consumed = consumeReliable(
                    bytes, now: now, hostMicroseconds: hostMicroseconds
                ) {
                    events += consumed
                } else {
                    events.append(.reliableCtrl(group: group, message: bytes))
                }
            case .oneShotAcknowledged(let group):
                events.append(.reliableOneShotAcknowledged(group))
                if group == finalFrameGroup {
                    // The converged frame landed: this ack IS the
                    // idle-flip signal (W4b's ordering rule).
                    finalFrameGroup = nil
                    convergedFrame = nil
                    events += runMachine(
                        .finalFrameAcknowledged,
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                }
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
            return runMachine(
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
            // Pre-arm BEFORE the shell injects: the wake/pre-arm
            // semantics belong to the event's arrival, not to the
            // injection call's success (W4b — a keypress during a
            // blackout must persist even if injection is deferred).
            var events = runMachine(
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
            // The W7 rule-3 gate: a capability is enabled only when
            // BOTH ends declared it — the byte-equal key-9 entry
            // surviving intersection IS that AND (HS-18). A request
            // outside the agreement is a peer using a superpower it
            // never negotiated: dropped loud, never fatal.
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
            // The W7 rule-3 gate, key 10 (CL-15): a set outside the
            // agreement is a peer using a superpower it never
            // negotiated — dropped loud, never fatal.
            guard agreedClipboardText else {
                counters.dropped += 1
                return [.dropped(.clipboardNotNegotiated)]
            }
            counters.clipboardSetsReceived += 1
            // Pre-arm the book BEFORE the shell applies: the leaf's
            // change signal for this very apply must suppress, not
            // boomerang (design doc §5's proof obligation).
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
            // The bulk sextet rides chan 8's ordered stream, never
            // CTRL (the W10 carriage rule) — a chunk on the input
            // stream is exactly the head-of-line blocking F-2 exists
            // to prevent. Hostile or confused; dropped loud.
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
            events += runMachine(
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

    // MARK: The lifecycle machine's runner (HS-11)

    /// Applies one input (nil = timers only), polls, executes the
    /// resulting actions, and surfaces state changes. The machine's own
    /// doctrine: apply never fires timers, so poll always follows.
    private func runMachine(
        _ input: SessionInput?, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard machine != nil else { return [] }
        let before = machine!.state
        var actions: [SessionAction] = []
        if let input {
            actions += machine!.apply(input, now: arqInstant(now))
        }
        let (polled, deadline) = machine!.poll(now: arqInstant(now))
        actions += polled
        machineDeadlineNS = deadline.map { $0.microseconds &* 1_000 }
        var events: [SessionEvent] = []
        if machine!.state != before {
            events.append(.lifecycleChanged(machine!.state))
        }
        events += execute(actions, now: now, hostMicroseconds: hostMicroseconds)
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
                events += sendFinalFrame(
                    now: now, hostMicroseconds: hostMicroseconds
                )
            case .armNextDamageAsIdr(let pacing), .forceIdr(let pacing):
                machineIdrPacing = pacing
                // The machine names the policy; the estimator owns the
                // numbers (HS-16): min(btlRate, lastGoodRate) for a
                // WAKE, max(floor, 0.5 × stale estimate) for RECOVERY.
                // Applied to the pacer immediately — the IDR this arms
                // is the first thing that pace carries.
                let rate = estimator.applyIdrPacing(pacing, now: now)
                channel.setRate(bitsPerSecond: rate, now: now)
                counters.rateChanges += 1
                events.append(.rateChanged(
                    bitsPerSecond: rate, reason: .idrPacing(pacing)
                ))
            case .freezeDatagramSends:
                videoFrozen = true
            case .resumeDatagramSends:
                videoFrozen = false
            case .sessionClosed(let reason):
                events.append(.sessionClosed(reason))
            }
        }
        return events
    }

    /// The converged frame onto its one-shot group. A refused send is
    /// loud, not fatal: the pending flip simply never completes, and
    /// the next damage/convergence cycle starts fresh.
    private func sendFinalFrame(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard let converged = convergedFrame else {
            return [.sendFailed("final frame: no converged frame retained")]
        }
        let message = IdleFrame(
            frame: converged.frame,
            captureTimestampMicroseconds: converged.captureMicros,
            annexB: converged.annexB
        ).encode()
        let group = ArqGroupId(rawValue: nextOneShotGroup)
        do {
            try sendReliableOneShot(
                message, group: group,
                now: now, hostMicroseconds: hostMicroseconds
            )
            nextOneShotGroup &+= 1
            if nextOneShotGroup == 0 { nextOneShotGroup = 1 }
            finalFrameGroup = group
            return [.finalFrameSent(group)]
        } catch {
            return [.sendFailed("final frame one-shot: \(error)")]
        }
    }

    /// The W7 declaration: the session's first ARQ-carried message.
    private func declareCapabilities(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard !capabilitiesDeclared else { return [] }
        capabilitiesDeclared = true
        do {
            try sendReliable(
                try negotiator.start().encode(),
                now: now, hostMicroseconds: hostMicroseconds
            )
            return []
        } catch {
            return [.sendFailed("capability declaration: \(error)")]
        }
    }

    // MARK: The HS-16 estimator's diet

    /// The send-sink tap: one released datagram into the estimator's
    /// ledger. PacerClass → envelope channel is a fixed mapping (the
    /// TOS mapping's sibling): control datagrams ride chan 0, audio
    /// chan 1, every video class chan 2 — the channels the client's
    /// dispersion samples will name. Off-primary challenges are
    /// excluded (they travel an unvalidated tuple; their arrivals
    /// measure a different path).
    private func datagramKey(_ datagram: VideoChannelDatagram) -> UInt32 {
        let channel: ChannelId
        switch datagram.pacerClass {
        case .control: channel = .ctrl
        case .audio: channel = .audio
        case .bulk: channel = .bulkTransfer
        case .freshVideo, .videoTail, .refinement, .telemetry:
            channel = .videoActive
        }
        return UInt32(channel.rawValue) << 16 | UInt32(datagram.seq.rawValue)
    }

    private func noteSocketPending(_ datagram: VideoChannelDatagram) {
        guard datagram.destination == nil else { return }
        socketPendingPaces[datagramKey(datagram)] =
            estimator.rateBitsPerSecond
        guard datagram.pacerClass == .freshVideo
                || datagram.pacerClass == .videoTail
                || datagram.pacerClass == .refinement
        else { return }
        let key = datagram.frameNumber.rawValue
        var pending = socketPendingVideo[key] ?? (0, 0)
        pending.datagrams += 1
        pending.bytes += datagram.bytes.count
        socketPendingVideo[key] = pending
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
        let key = datagramKey(datagram)
        let pace = socketPendingPaces.removeValue(forKey: key)
        noteSent(datagram, now: now, paceBitsPerSecond: pace)
        guard datagram.pacerClass == .freshVideo
                || datagram.pacerClass == .videoTail
                || datagram.pacerClass == .refinement
        else { return }
        guard var pending =
                socketPendingVideo[datagram.frameNumber.rawValue]
        else { return }
        pending.datagrams -= 1
        pending.bytes -= datagram.bytes.count
        if pending.datagrams <= 0 {
            socketPendingVideo.removeValue(
                forKey: datagram.frameNumber.rawValue)
        } else {
            socketPendingVideo[datagram.frameNumber.rawValue] = pending
        }
    }

    /// Removes one socket-pending datagram without presenting it as path
    /// evidence. Used when fall repricing purges the executable's unsent
    /// EAGAIN outbox alongside the core pacer queue.
    public func discardPendingDatagram(_ datagram: VideoChannelDatagram) {
        guard sendAccounting == .socketConfirmed,
              datagram.destination == nil else { return }
        socketPendingPaces.removeValue(forKey: datagramKey(datagram))
        guard datagram.pacerClass == .freshVideo
                || datagram.pacerClass == .videoTail
                || datagram.pacerClass == .refinement
        else { return }
        guard var pending =
                socketPendingVideo[datagram.frameNumber.rawValue]
        else { return }
        pending.datagrams -= 1
        pending.bytes -= datagram.bytes.count
        if pending.datagrams <= 0 {
            socketPendingVideo.removeValue(
                forKey: datagram.frameNumber.rawValue)
        } else {
            socketPendingVideo[datagram.frameNumber.rawValue] = pending
        }
    }

    public func noteKernelPressureFreshVideoShed(
        datagrams: Int, bytes: Int
    ) {
        guard datagrams > 0 else { return }
        counters.kernelPressureShedFrames += 1
        counters.kernelPressureShedDatagrams += datagrams
        counters.kernelPressureShedBytes += bytes
        fallPurgeKeyframePending = true
    }

    private func noteSent(
        _ datagram: VideoChannelDatagram,
        now: UInt64,
        paceBitsPerSecond: Int? = nil
    ) {
        guard datagram.destination == nil else { return }
        let channel: ChannelId
        switch datagram.pacerClass {
        case .control: channel = .ctrl
        case .audio: channel = .audio
        case .bulk: channel = .bulkTransfer
        case .freshVideo, .videoTail, .refinement, .telemetry:
            channel = .videoActive
        }
        let deliveryFrame: FrameNumber? =
            datagram.pacerClass == .freshVideo
                ? datagram.frameNumber : nil
        estimator.noteSent(
            channel: channel, seq: datagram.seq,
            bytes: datagram.bytes.count, now: now,
            deliveryFrame: deliveryFrame,
            paceBitsPerSecond: paceBitsPerSecond
        )
    }

    /// One authenticated chan-3 payload: parse, feed the estimator,
    /// apply its rate (and any FEC-regime step) to the shared channel,
    /// answer the NACK section through the HS-17 retransmit gate, and
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
        // HS-32: the derived freeze budget's cadence evidence — an
        // EWMA of report inter-arrival, each sample clamped to the
        // wire-pinned 25–50 ms cadence range so out-of-cadence NACK
        // flushes and lost reports never masquerade as the cadence.
        if let last = lastFeedbackParsedAtNS {
            let sample = min(max(now &- last, 25_000_000), 50_000_000)
            feedbackCadenceEwmaNS = feedbackCadenceEwmaNS.map {
                ($0 * 7 &+ sample) / 8
            } ?? sample
        }
        lastFeedbackParsedAtNS = now
        // HS-32: the opening exemption's glass proxy — a report
        // showing every video datagram through the opening IDR's
        // group delivered means a frame plausibly completed; the
        // exemption dies for good.
        if !clientGlassEvidence, let total = openingIdrShardTotal {
            for block in report.channels
            where block.channel == .videoActive
                && block.missing == 0
                && block.received >= UInt32(total) {
                clientGlassEvidence = true
            }
        }
        // The video-class backlog rides along (HS-22c): while the
        // pacer holds a standing queue, delivery trains measure our
        // own pacing — the estimator's self-reference gate needs to
        // know when that is the case.
        let verdict = estimator.ingest(
            report, now: now, inRecovery: machine?.state == .recovery,
            pacerBacklogBytes: queuedVideoBytes,
            // HS-28: NACKs against frames we have not finished sending
            // are the client's completion presumption expiring
            // mid-drain — self-inflicted, recused from path evidence.
            recusedNackFrames: channel.framesWithQueuedShards()
                .union(socketPendingVideo.keys)
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
            // The fall-repricing purge: a genuine fall (never plain
            // evidence decay) reprices bytes already admitted at the
            // pre-fall rate. Backlog that would now serialize past the
            // threshold is stale wire — video the glass renders late
            // or never (80–895 ms measured before this existed). Drop
            // it and re-anchor through the same coalesced latch every
            // other mid-flight loss uses; the IDR supersedes whatever
            // the dropped shards would have completed.
            if reason != .evidence {
                let backlog = queuedVideoBytes
                let staleWireNS = UInt64(
                    Double(backlog) * 8e9 / Double(rate))
                if staleWireNS > videoQueueBudgetNS {
                    let purged = channel.purgeQueuedVideo()
                    let socketDatagrams = socketPendingVideo.values.reduce(0) {
                        $0 + $1.datagrams
                    }
                    let socketBytes = socketPendingVideo.values.reduce(0) {
                        $0 + $1.bytes
                    }
                    fallPurgeKeyframePending = true
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
            // The estimator's rung-3 step verdict lands on the
            // packetizing seam: the NEXT frame's geometry draws from
            // the new §5.2 column.
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
            events += runMachine(
                .feedbackWindow(clean: clean),
                now: now, hostMicroseconds: hostMicroseconds
            )
        }
        return events
    }

    /// HS-32: the freeze budget actually in force — the config
    /// override when set, otherwise the derivation documented on
    /// `repairFreezeBudgetOverrideNS` (multiplier × observed cadence
    /// + jitter allowance; 50 ms worst-case cadence before evidence).
    public var repairFreezeBudgetNS: UInt64 {
        if let override = config.repairFreezeBudgetOverrideNS {
            return override
        }
        let cadenceNS = feedbackCadenceEwmaNS ?? 50_000_000
        let scaled = UInt64(
            config.repairBudgetCadenceMultiplier * Double(cadenceNS)
        )
        return scaled &+ config.repairBudgetJitterAllowanceNS
    }

    /// The HS-17 NACK responder: resiliency §1.1 rules 3–4 over the
    /// channel's repair store.
    ///
    ///   honor iff SRTT + retxSerialization < remainingFreezeBudget
    ///         AND the frame is newer than the last IDR;
    ///   one attempt per shard, no retransmission of retransmissions;
    ///   otherwise the IDR alternative: stale verdicts that leave the
    ///   client stuck (budget gone, bytes gone) arm the SAME coalesced
    ///   keyframe latch client 0x10 requests pull — the next
    ///   `takeFreshKeyframeRequest` poll answers with a fresh IDR.
    ///
    /// HS-32 grew two things. (1) Refusals the client can act on are
    /// EXPLICIT: budget-gone, older-than-IDR, and store-gone verdicts
    /// each send one 0x23 RepairRefusal (sealed, ARQ-exempt,
    /// fire-and-forget — a lost refusal degrades to the client's own
    /// deadline), so the client stops blind-waiting 250 ms on repairs
    /// that were never coming. Already-repaired stays silent (repairs
    /// may be in flight; a refusal would double-heal into an IDR) and
    /// FROZEN/closed stays silent (the path is dark). (2) The
    /// opening-IDR exemption: while nothing has plausibly reached the
    /// client's glass, an ask naming the LAST IDR is honored
    /// regardless of the budget — bounded by attempts and bytes.
    ///
    /// FROZEN suppresses retransmits with the rest of datagram video
    /// (§4's freeze protocol) — RECOVERY's forced IDR is the heal
    /// there, so the latch is deliberately NOT armed.
    private func respondToNack(
        _ nack: FeedbackReport.NackEntry,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        counters.nackEntriesReceived += 1

        func stale(
            _ reason: NackStaleReason, armIdr: Bool
        ) -> [SessionEvent] {
            counters.nacksJudgedStale += 1
            if armIdr {
                let mayArm: Bool
                if reason == .unavailable {
                    mayArm = lastUnknownFrameIdrArmAtNS.map {
                        now &- $0 >= config.unknownFrameIdrArmIntervalNS
                    } ?? true
                } else {
                    mayArm = true
                }
                if mayArm {
                    staleNackKeyframePending = true
                    counters.idrArmedOnStaleNack += 1
                    if reason == .unavailable {
                        lastUnknownFrameIdrArmAtNS = now
                    }
                } else {
                    counters.unknownFrameIdrArmsThrottled += 1
                }
            }
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

        if videoFrozen || machine?.state == .closed {
            return stale(.sendsSuppressed, armIdr: false)
        }
        // "The frame is newer than the last IDR": a frame BEHIND the
        // last IDR is a dead reference — the IDR re-anchored the chain
        // past it. The IDR itself stays repairable (§5.2's rationale:
        // burst loss ON an IDR is handled by retransmit or re-issue).
        // No IDR arm on refusal: the newer IDR IS the heal, in flight
        // or delivered (and if IT died, the client names it too).
        if let lastIdr = channel.lastKeyframeNumber, nack.frame < lastIdr {
            return stale(.olderThanIdr, armIdr: false)
        }
        // A fall purge already armed the one replacement IDR. Treat
        // later NACKs for any purged frame as superseded: resurrecting
        // its stored shards would rebuild the stale tail, while arming
        // another IDR would turn one capacity cliff into an avalanche.
        if channel.wasPurged(nack.frame) {
            return stale(.olderThanIdr, armIdr: false)
        }
        guard let ingestedAt = channel.repairAnchor(for: nack.frame) else {
            return stale(.unavailable, armIdr: true)
        }
        let repairBytes = channel.repairByteCount(
            frame: nack.frame, shardIndices: nack.missingShards
        )
        guard repairBytes > 0 else {
            // Everything named already rode its one attempt. The
            // repairs may still be in flight — arming an IDR here
            // would double-heal; the client's own coalescing
            // requester escalates if the frame stays incomplete
            // (rule 4's client half).
            return stale(.alreadyRepaired, armIdr: false)
        }
        // HS-32: the opening-IDR exemption. While nothing has
        // plausibly reached the client's glass, an ask naming the
        // LAST IDR skips the budget gate entirely (SRTT may not even
        // exist yet at session open — the first beacon echo is up to
        // 1 s away): a black glass is the one case where a late
        // repair beats a re-minted IDR that starts even later.
        // Attempt/byte-bounded so it can never amplify congestion.
        let openingExempt = !clientGlassEvidence
            && channel.lastKeyframeNumber == nack.frame
            && openingExemptAttempts < config.openingRepairMaxAttempts
            && openingExemptBytes + repairBytes
                <= config.openingRepairMaxBytes
        if !openingExempt {
            // Rule 3's gate. The budget clock started when the frame's
            // flight completed (the client cannot judge it
            // FEC-impossible earlier); the NACK's propagation up is
            // already inside the elapsed time. No RTT evidence means
            // no honest promise the repair lands in budget — stale.
            // The RTT term is SRTT capped at 2 × min-RTT: the
            // beacon-echo SRTT double-counts both ends' receive-loop
            // wake latency (measured 7–13 ms on a 0.3 ms loopback),
            // which a repair datagram — straight onto the pacer, no
            // beacon service point — never pays; genuine path queueing
            // moves min-RTT with it and still governs.
            let elapsedNS = now &- ingestedAt
            let budgetNS = repairFreezeBudgetNS
            guard elapsedNS < budgetNS,
                  let srttMicros = estimator.srttMicroseconds
            else {
                return stale(.budgetExceeded, armIdr: true)
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
                return stale(.budgetExceeded, armIdr: true)
            }
        }

        let enqueued: Int
        do {
            enqueued = try channel.enqueueRepair(
                frame: nack.frame,
                shardIndices: nack.missingShards,
                now: now
            )
        } catch {
            return [.sendFailed("repair frame \(nack.frame.rawValue): \(error)")]
        }
        guard enqueued > 0 else {
            return stale(.unavailable, armIdr: true)
        }
        if openingExempt {
            openingExemptAttempts += 1
            openingExemptBytes += repairBytes
            counters.openingExemptRepairsHonored += 1
        }
        counters.nacksHonored += 1
        counters.repairDatagramsEnqueued += enqueued
        return [.repairEnqueued(frame: nack.frame, shards: enqueued)]
    }

    /// Polls the endpoint and puts its output on the wire: repack to
    /// the session's 1101 B plaintext budget (poll packs to the bare
    /// 1112 B table — exact only without TLV + tag; frames are
    /// self-delimiting, so re-cutting datagram boundaries is
    /// protocol-neutral), then each datagram sealed through the
    /// control class like every other CTRL send. Re-arms the PTO wake.
    private func serviceArq(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard phase == .established else { return [] }
        let (payloads, deadline) = arq.poll(now: arqInstant(now))
        nextArqWakeNS = deadline.map { $0.microseconds &* 1_000 }
        guard !payloads.isEmpty else { return [] }

        var events: [SessionEvent] = []
        do {
            for payload in try repackArq(payloads) {
                try sendCtrl(
                    body: payload, sealed: true,
                    now: now, hostMicroseconds: hostMicroseconds
                )
                counters.arqDatagramsSent += 1
            }
        } catch {
            // Segments the poll marked sent stay armed on their PTO
            // timers — a refused send here heals like a lost datagram.
            events.append(.sendFailed("arq: \(error)"))
        }
        return events
    }

    /// Re-cuts the endpoint's datagram payloads at the session's real
    /// budget. Every frame fits alone by construction: segment bodies
    /// were clamped at init (≤ budget − 8) and an ACK frame's ceiling
    /// (3 + 16·38 B) is far below it.
    private func repackArq(_ payloads: [[UInt8]]) throws -> [[UInt8]] {
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        for payload in payloads {
            if payload.count <= arqPayloadBudget {
                // Already within budget — keep the endpoint's packing
                // (ACK piggybacked ahead of segments) byte-verbatim.
                if !current.isEmpty {
                    out.append(current)
                    current = []
                }
                out.append(payload)
                continue
            }
            for frame in try ArqFrame.decodeAll(payload) {
                let bytes = frame.encode()
                if !current.isEmpty,
                   current.count + bytes.count > arqPayloadBudget {
                    out.append(current)
                    current = []
                }
                current.append(contentsOf: bytes)
            }
        }
        if !current.isEmpty {
            out.append(current)
        }
        return out
    }

    // MARK: Timers and pumping

    /// Clock advance with no datagram — the loop's timer wake. Emits due
    /// beacons, services the ARQ's retransmit timers, runs the
    /// lifecycle machine's timers (the 350 ms blackout detector, the
    /// 30 s liveness clock), and runs the validator's expiries.
    public func advance(now: UInt64, hostMicroseconds: UInt64) -> [SessionEvent] {
        var events = process(
            validator.advance(now: now),
            now: now, hostMicroseconds: hostMicroseconds
        )
        guard phase == .established else { return events }
        // Insecure mode reaches establishment without a handshake; the
        // declaration leaves on the first wake (Noise mode declared at
        // `completeHandshake`, so this is a no-op there).
        if !capabilitiesDeclared {
            events += declareCapabilities(
                now: now, hostMicroseconds: hostMicroseconds
            )
        }
        if let due = nextBeaconAt, now >= due {
            events += emitBeacon(now: now, hostMicroseconds: hostMicroseconds)
            // Re-arm from the due instant so cadence does not drift; a
            // stalled loop emits one catch-up beacon, never a burst.
            var next = due + config.beaconIntervalNS
            if next <= now { next = now + config.beaconIntervalNS }
            nextBeaconAt = next
        }
        events += flushInputEchoes(now: now, hostMicroseconds: hostMicroseconds)
        // HS-22: a convergence that waited out the idle-flip quiet —
        // damage stayed silent, the handoff may start now.
        if let due = pendingIdleFlipAt, now >= due, convergedFrame != nil {
            pendingIdleFlipAt = nil
            events += runMachine(
                .ratchetConverged, now: now, hostMicroseconds: hostMicroseconds
            )
        }
        if let due = nextArqWakeNS, now >= due {
            events += serviceArq(now: now, hostMicroseconds: hostMicroseconds)
        }
        if let due = nextBulkArqWakeNS, now >= due {
            events += serviceBulkArq(
                now: now, hostMicroseconds: hostMicroseconds
            )
        }
        if let machine, machine.state != .closed,
           machineDeadlineNS.map({ now >= $0 }) ?? true {
            events += runMachine(
                nil, now: now, hostMicroseconds: hostMicroseconds
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
        var control: [VideoChannelDatagram] = []
        var audio: [VideoChannelDatagram] = []
        var remaining: [VideoChannelDatagram] = []
        control.reserveCapacity(datagrams.count)
        audio.reserveCapacity(datagrams.count)
        remaining.reserveCapacity(datagrams.count)
        for datagram in datagrams {
            switch datagram.pacerClass {
            case .control: control.append(datagram)
            case .audio: audio.append(datagram)
            default: remaining.append(datagram)
            }
        }
        return control + audio + remaining
    }

    /// The earliest instant anything here has work: the pacer's wake,
    /// the next beacon, the ARQ's retransmit deadline, or a validator
    /// deadline. The loop sleeps until this (Pacer semantics).
    public func nextWake(now: UInt64) -> UInt64? {
        var wake = channel.nextWake(now: now)
        for candidate in [
            nextBeaconAt, nextArqWakeNS, nextBulkArqWakeNS,
            machineDeadlineNS, validator.nextDeadline, pendingIdleFlipAt,
        ] {
            guard let candidate else { continue }
            wake = wake.map { min($0, candidate) } ?? candidate
        }
        return wake
    }

    public var isIdle: Bool { channel.isIdle }

    /// The HS-16 seam, passed through to the shared pacer. The
    /// estimator now drives this from feedback evidence; the manual
    /// entry point stays for shells and tests that want to force a
    /// rate (the estimator's next verdict will move it again).
    public func setRate(bitsPerSecond: Int, now: UInt64) {
        channel.setRate(bitsPerSecond: bitsPerSecond, now: now)
    }

    // MARK: HS-16 estimator surfaces

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

    /// HS-28: the estimator's capacity belief — what it honestly
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

    /// The HS-6 frame ceiling at the LIVE estimate: R×B/8 −
    /// higherClassBytes(B), B = min(2/fps, 25 ms) — the single-frame
    /// VBV cap the encoder should enforce (the "IdrPacing numbers"
    /// deferred item, now derived from evidence instead of config).
    public func frameByteCeiling(fps: Int) -> Int {
        estimator.frameByteCeiling(fps: fps)
    }

    /// HS-25: the largest frame the CURRENT regime and TLV posture can
    /// ship as one protected FEC group — the ingest guard's live bound
    /// (logs and tests read it here).
    public var protectableFrameByteCeiling: Int {
        channel.maxProtectableFrameByteCount(
            hasLastInputSeq: lastInputSeq != nil
        )
    }

    /// HS-25: that ceiling's session-static worst case (lossy regime,
    /// input stamp riding) — what the shell caps the encoder's opening
    /// VBV to, so no reachable posture can mint an unshippable frame.
    public var worstCaseProtectableFrameByteCeiling: Int {
        channel.worstCaseProtectableFrameByteCount
    }

    /// The rate the shared pacer is actually running at.
    public var pacerRateBitsPerSecond: Int { channel.rateBitsPerSecond }

    public var pacerTelemetry: PacerTelemetry { channel.pacerTelemetry }
    public var videoCounters: VideoChannelCounters { channel.counters }

    // MARK: HS-17 repair surfaces

    /// The §5.2 regime column the packetizing seam is drawing from.
    public var fecRegime: FecRegime { channel.regime }

    /// The retransmit gate's smoothed RTT; nil before beacon evidence.
    public var srttMicroseconds: Int64? { estimator.srttMicroseconds }

    /// Bytes retained for repair (the ≥4 s ring's live size).
    public var repairStoreBytes: Int { channel.repairStoreBytes }

    public func takeFrameTransmitTelemetry() -> [VideoFrameTransmitTelemetry] {
        channel.takeFrameTransmitTelemetry()
    }

    // MARK: Handshake (responder)

    /// The opaque bytes the retry cookie binds address ownership to
    /// (HS-21): the client's source address ‖ port, the host's own
    /// serialization. Only the host ever parses it (sans-IO: it is
    /// opaque to the cookie crypto), and it stays inside RetryCookie's
    /// 1…255-byte tuple bound — an "255.255.255.255:65535" is 21 bytes,
    /// an IPv6 literal with a port comfortably under the ceiling.
    static func cookieTuple(_ tuple: FourTuple) -> [UInt8] {
        Array("\(tuple.remoteAddress):\(tuple.remotePort)".utf8)
    }

    /// Emits one `.handshakeCookieModeChanged` per genuine flip of the
    /// require-cookie dial (HS-21). Called right after every
    /// `admitMessage1`, whose flood-window update is what moves it.
    private func noteCookieModeTransition() -> [SessionEvent] {
        let mode = handshakeGate.cookieMode
        guard mode != lastCookieMode else { return [] }
        lastCookieMode = mode
        return [.handshakeCookieModeChanged(requireCookie: mode)]
    }

    private func completeHandshake(
        message1: ArraySlice<UInt8>,
        hostStatic: NoiseKeyPair,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        // Fresh responder state per attempt: a failed message 1 (bad
        // version, wrong static, garbage) burns nothing — the client's
        // retry meets a clean slate.
        var responder: NoiseSession
        do {
            responder = try NoiseSession(role: .responder, staticKeys: hostStatic)
            _ = try responder.readMessage1(message1)
        } catch {
            counters.dropped += 1
            return [.dropped(.handshakeFailed(String(describing: error)))]
        }
        if let allowed = config.allowedClientStaticPublicKeys,
           let remote = responder.remoteStaticPublicKey,
           !allowed.contains(remote) {
            counters.dropped += 1
            return [.dropped(.handshakeFailed("client static not in the paired set"))]
        }
        do {
            let message2 = try responder.writeMessage2()
            try sendCtrl(
                body: [CtrlMessageType.noiseHandshake2] + message2,
                sealed: false,
                now: now, hostMicroseconds: hostMicroseconds
            )
            transport = try responder.makeTransport()
        } catch {
            return [.dropped(.handshakeFailed(String(describing: error)))]
        }
        phase = .established
        var events: [SessionEvent] = [.handshakeCompleted(
            remoteStaticPublicKey: responder.remoteStaticPublicKey ?? []
        )]
        // "1 Hz plus session start" (§4.6): message 2 is already queued
        // ahead of this beacon in the control FIFO, so the client can
        // derive its transport before the first sealed datagram lands.
        events += emitBeacon(now: now, hostMicroseconds: hostMicroseconds)
        nextBeaconAt = now + config.beaconIntervalNS
        // The machine begins at establishment, in ACTIVE (W4b), and the
        // capability declaration is the first ARQ-carried word (W7) —
        // beacons are ARQ-exempt, so it is first on the reliable stream
        // by construction.
        machine = SessionStateMachine(
            role: .mediaSender,
            config: config.lifecycle,
            now: arqInstant(now)
        )
        events += declareCapabilities(
            now: now, hostMicroseconds: hostMicroseconds
        )
        events += runMachine(nil, now: now, hostMicroseconds: hostMicroseconds)
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
            // The one-byte peek: a payload starting with either ARQ
            // byte is wholly ARQ — a sequence of self-delimiting
            // frames. Ingest, then poll immediately: the ACK the
            // ingest owes (and any fast retransmit it triggered)
            // leaves in this same service pass.
            var events = absorbArq(
                arq.ingest(payload: payload[...], now: arqInstant(now)),
                now: now, hostMicroseconds: hostMicroseconds
            )
            events += serviceArq(now: now, hostMicroseconds: hostMicroseconds)
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
            clientKeyframePending = true
            counters.idrRequests += 1
            return [.idrRequested(request)]
        default:
            counters.dropped += 1
            return [.dropped(.unexpectedCtrlType(type))]
        }
    }

    private func accept(
        echo: BeaconEcho, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let hostReceive = HostTimestamp(microseconds: hostMicroseconds)
        let sample = echo.clockSample(hostReceive: hostReceive)
        clock.samples += 1
        clock.lastOffsetMicroseconds = sample.offsetMicroseconds
        clock.lastRttMicroseconds = sample.rttMicroseconds
        if clock.minRttMicroseconds.map({ sample.rttMicroseconds < $0 }) ?? true {
            clock.minRttMicroseconds = sample.rttMicroseconds
            clock.minRttOffsetMicroseconds = sample.offsetMicroseconds
        }
        // W4a's mirror: the next beacon reports this echo's t3 verbatim
        // and our locally measured t4.
        lastEcho = ClockBeacon.LastEcho(
            beaconSeq: echo.beaconSeq,
            clientSend: echo.clientSend,
            hostReceive: hostReceive
        )
        counters.beaconEchoes += 1
        // RTT evidence into the estimator (telemetry + the future
        // HS-17 retransmit gate; the rate law runs on dispersion).
        estimator.noteRtt(microseconds: sample.rttMicroseconds)
        return [.beaconEchoAccepted(
            beaconSeq: echo.beaconSeq,
            offsetMicroseconds: sample.offsetMicroseconds,
            rttMicroseconds: sample.rttMicroseconds
        )]
    }

    // MARK: Outbound plumbing

    private func emitBeacon(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let beacon = ClockBeacon(
            beaconSeq: beaconSeq,
            hostSend: HostTimestamp(microseconds: hostMicroseconds),
            lastEcho: lastEcho
        )
        do {
            try sendCtrl(
                body: beacon.encode(), sealed: true,
                now: now, hostMicroseconds: hostMicroseconds
            )
        } catch {
            return [.sendFailed("beacon \(beaconSeq): \(error)")]
        }
        counters.beaconsSent += 1
        defer { beaconSeq &+= 1 }
        return [.beaconSent(beaconSeq: beaconSeq)]
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
        let envelope = Envelope(
            channel: .ctrl,
            seq: ctrlSeq,
            frame: FrameNumber(rawValue: 0),
            timestamp: hostMicroseconds,
            fec: 0,
            extensions: [connectionId.wireExtension]
        )
        let payload: [UInt8]
        if sealed {
            let header = try envelope.encode(payload: [])
            payload = try sealPayload(body[...], aad: header[...], envelope: envelope)
        } else {
            payload = body
        }
        let bytes = try envelope.encode(payload: payload)
        ctrlSeq = ctrlSeq.next
        channel.enqueueControl(
            bytes, seq: envelope.seq, destination: destination, now: now
        )
    }

    // MARK: The crypto seam

    private func sealPayload(
        _ plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        switch config.crypto {
        case .insecure:
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
        case .insecure:
            return Array(wirePayload)
        case .noise:
            guard transport != nil else { throw SessionError.notEstablished }
            return try transport!.unseal(
                wirePayload: wirePayload, aad: aad, envelope: envelope
            )
        }
    }
}

/// A concrete `RandomNumberGenerator` boxing the init's injected
/// generator — a stored `some` isn't expressible, and P-1's image-id
/// mint (session-lifetime) shouldn't force Session generic. The
/// sans-IO injection seam survives intact.
struct BoxedRng: RandomNumberGenerator {
    var base: any RandomNumberGenerator
    mutating func next() -> UInt64 { base.next() }
}
