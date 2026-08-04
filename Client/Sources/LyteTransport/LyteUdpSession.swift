// LyteUdpSession (CL-8, absorbing CL-7's deferred session slice): the
// client's production Lyte-UDP session object — the thing behind the
// app's ConnectionModel and behind `lyte-cli wire-view`. It assembles
// the proven parts into one lifecycle:
//
//   Noise IK (persistent identity; W8 0x13→0x14 retry answer in the
//   dial path — NoiseTransportCrypto's leg)
//     → UdpReceiveEndpoint (bind, handshake, receive thread)
//     → ReceiveDemux / TransportSender (seal/unseal, header-as-AAD)
//     → ReliableCtrlEndpoint (CL-7's ARQ carriage)
//         → CapabilityNegotiator(client) — declaration 0x0F is the
//           FIRST reliable word each way; the intersection IS the
//           agreement (W7)
//         → SessionStateMachine(mediaReceiver) — mirrors ModeTransition
//           0x09, consumes SessionTeardown 0x0A, derives the FROZEN
//           pill (W4b)
//         → IdleFrame 0x15 → LyteVideoPipeline.ingestReliableFrame
//           (rendered through the SAME factory as datagram video; the
//           one-shot's ACK — the host's flip-to-IDLE gate — leaves in
//           the same ingest pass, nothing extra needed)
//     → LyteVideoPipeline (chan 2 datagram video), FeedbackSender,
//       BeaconEchoResponder → HostClockModel (CL-10), IdrRequester
//
// Split for the gate tests (the ReliableCtrlGateTests/PairingGateTests
// pattern): `LyteUdpSessionCore` is everything above the socket — it
// takes a demux, a sender, and an injected clock, so tests drive the
// REAL assembly through SimNet in virtual time against a LyteWire host
// build-up. `LyteUdpSession` is the thin production shell that binds
// the socket, runs the handshake, and owns the wall-clock timers.
//
// The client's silence detector — an honest deviation, documented:
// W4b's 350 ms detector is dimensioned for the media-path evidence
// stream (25–50 ms feedback for the host, 5 ms audio for the client).
// The client has no audio channel until H2, and an IDLE host sends
// only 1 Hz beacons — a 350 ms receiver detector would flap
// FROZEN↔IDLE between beacons forever. So the client (a) feeds EVERY
// authenticated host arrival to the detector (video shards, sealed
// CTRL, beacons — for the receiver they are all proof the host→client
// path moves), and (b) defaults the blackout threshold to 2.5 s,
// comfortably past the 1 Hz beacon cadence and still far under the
// 30 s liveness teardown. When H2's audio lands (the 5 ms path probe),
// the default tightens back to the pillar's 350 ms and the evidence
// split (media vs CTRL) becomes real. The machine's config is the
// injection point; nothing in Wire/ changes.

import LyteIO
import LyteCore
import Dispatch
import Foundation
import LyteWire
import Synchronization

// MARK: - Client-side audio-routing policy

/// The rule-3 gate, client side: asking for a flip the intersection
/// never agreed to is refused HERE, before a byte leaves — the host
/// would only drop it loud (`.audioRoutingNotNegotiated`). Client
/// session policy, not wire vocabulary — which is why it stayed behind
/// when the 0x18/0x19 codecs promoted into LyteWire.
public enum AudioRoutingAskError: Error, Equatable, Sendable {
    case notNegotiated
    /// streamOff asked against an intersection without key 14 — the
    /// mute-at-source dialect never survived, so the ask is refused
    /// before a byte leaves.
    case streamOffNotNegotiated
}

// MARK: - Client-side bulk-channel policy (F-4)

/// The rule-3 gate, bulk verse: a bulk send when key 11 never
/// survived intersection is refused before a byte leaves — the client
/// OFFERS ONLY into an agreed set (H3 §0 decision 1; the host's
/// standing consent toggle decides whether it declares).
public enum BulkChannelError: Error, Equatable, Sendable {
    case notNegotiated
}

// MARK: - Client-side clipboard policy (CL-15)

/// One local clipboard change's fate (the pasteboard watcher calls on
/// every changeCount bump while sharing is on; the verdict is policy,
/// counted, never thrown — a poller has nobody to catch for it).
public enum ClipboardShareOutcome: Equatable, Sendable {
    /// A 0x1A left on the ordered stream.
    case shared
    /// The pasteboard reporting our own host-announce apply back —
    /// the sync book's boomerang stop.
    case suppressedEcho
    /// Identical to the last text we shared — the host already holds it.
    case suppressedDuplicate
    /// P-1 (images only): the clipboard send lane already carries a
    /// transfer — v2 syncs latest-wins clipboards, so the superseded
    /// copy just drops. Text never reports this (0x1A has no lane).
    case suppressedBusy
    /// The session toggle (or per-host default) says clipboard
    /// sharing is off: nothing leaves.
    case sharingDisabled
    /// Key 10 never survived intersection — refused before a byte
    /// leaves (the rule-3 gate, the audio-routing ask's rule).
    case notNegotiated
    /// Past the 65,536-byte v1 ceiling (or empty) — suppressed
    /// weather, counted.
    case overBudget(Int)
    /// The reliable endpoint refused the send (teardown races).
    case sendRefused(String)
}

// MARK: - Events

/// Everything the session surfaces to its owner (the CLI's printer,
/// the app's ConnectionModel). Fired from receive/timer threads —
/// UI owners hop to the main actor themselves.
public enum LyteUdpSessionEvent: Sendable {
    /// The W7 exchange settled: this is the session's agreed set.
    case capabilitiesAgreed(Capabilities)
    /// The peer's declaration produced an unworkable intersection —
    /// the typed teardown followed automatically. TYPED since V-5:
    /// the app's chroma fallback keys on `.noCommonChromaMode`
    /// specifically (a Best declaration against a 4:2:0-only host
    /// auto-re-dials at Good — ChromaFallbackPolicy's verdict).
    case capabilitiesFailed(CapabilityNegotiationError)
    /// A host renegotiation proposal (0x11) was answered (0x12).
    case capabilityUpdateAnswered(accepted: Bool)
    /// The wire mode changed (a delivered ModeTransition, or RECOVERY
    /// re-entry semantics on the host's side reflected here).
    case modeChanged(SessionWireMode)
    /// The lifecycle state changed — `frozen` is the CL-8 pill.
    case stateChanged(SessionState)
    /// A reliable idle frame (0x15) arrived, with what became of it.
    case idleFrameReceived(frame: UInt32, outcome: ReliableFrameOutcome)
    /// A 0x19 applied-posture status arrived (CL-13): where the host's
    /// own speakers ACTUALLY stand — sent by the host at capability
    /// agreement and after every applied flip; a failed flip reports
    /// the OLD posture. Fires on every status, changed or not, so the
    /// UI can settle a pending toggle either way. Truth, not hope.
    case hostAudioRoutingStatus(HostAudioRoutingMode)
    /// A 0x1B clipboard announce arrived and passed every gate
    /// (negotiated, sharing enabled) — the glue applies `text` to the
    /// pasteboard (CL-15). The sync book is already pre-armed against
    /// the apply's changeCount echo. Never fires while sharing is off:
    /// content must not land on the pasteboard without consent.
    case hostClipboardChanged(String)
    /// E3: a 0x24 cursor shape arrived past the rule-3 gate (key 13
    /// agreed) — the direct eye's video carries no cursor, so the
    /// host streams the hardware cursor plane's image as metadata and
    /// the glue wears it as the local NSCursor over the video view.
    /// `.hidden` (zero-sized) means the host cursor is hidden. No
    /// consent toggle: a cursor shape is presentation state, not
    /// content — the audio-routing-status posture, not clipboard's.
    case hostCursorShapeChanged(CursorShape)
    /// P-1 (clipboard v2): a host clipboard IMAGE landed sha-verified
    /// off the chan-8 clipboard lane and passed every gate (keys 10∧12
    /// agreed, sharing on, images tier on) — the glue applies `data`
    /// (PNG in v2) to the pasteboard. The sync book is already
    /// pre-armed against the apply's changeCount echo. Never fires
    /// while sharing/images are off: an unwelcome marker draws the
    /// typed abort(declined) instead — the sender waits on a verdict,
    /// so images cannot use text's silent-deafness posture.
    case hostClipboardImageChanged(data: [UInt8], mime: String)
    /// One decoded chan-8 bulk message arrived (F-4): accept/ack/
    /// complete/abort answers for the client's sending role. Already
    /// through the rule-3 gate (key 11 agreed); the owner feeds it to
    /// its BulkSendCoordinator.
    case bulkMessageReceived(BulkMessage)
    /// Our typed teardown left on the ordered stream.
    case teardownSent(SessionTeardownReason)
    /// The session reached `closed` — peer teardown, local teardown,
    /// or the 30 s liveness timeout. The owner stops the session.
    case closed(SessionCloseReason)
    /// Protocol weather worth a log line, never fatal.
    case protocolNote(String)
}

/// The first dependency-breaking fact that opened a video recovery episode.
/// This is app telemetry/control vocabulary only; it never changes wire bytes.
public enum VideoRecoveryCause: String, Sendable, Codable, CaseIterable {
    case fecAssemblerDamage
    case hostPurgeInferredDamage
    case freshPresentationDebt
    case rendererFailure
    case rendererBackpressure
}

public struct VideoRecoveryTraceEvent: Sendable {
    public var kind: String
    public var frame: FrameNumber
    public var cause: VideoRecoveryCause?
    public var isRandomAccess: Bool?

    public init(
        kind: String,
        frame: FrameNumber,
        cause: VideoRecoveryCause? = nil,
        isRandomAccess: Bool? = nil
    ) {
        self.kind = kind
        self.frame = frame
        self.cause = cause
        self.isRandomAccess = isRandomAccess
    }
}

/// Session-level counters (the parts keep their own detailed stats;
/// these are the CL-8 dispatch layer's).
public struct LyteUdpSessionCounters: Sendable {
    public var modeTransitionsReceived: UInt64 = 0
    public var idleFramesReceived: UInt64 = 0
    public var capabilityUpdatesAnswered: UInt64 = 0
    public var unknownReliableTypes: UInt64 = 0
    public var malformedReliableMessages: UInt64 = 0
    /// 0x17 echo messages consumed (tuple-level books live on
    /// `InputSender`'s stats — CL-9).
    public var inputEchoMessagesReceived: UInt64 = 0
    /// Chan-1 datagrams routed to the audio receiver (CL-11).
    public var audioDatagramsReceived: UInt64 = 0
    /// 0x18 flip requests this end put on the ordered stream (CL-13),
    /// the session-start posture ask included.
    public var audioRoutingRequestsSent: UInt64 = 0
    /// 0x19 applied-posture statuses consumed (CL-13).
    public var audioRoutingStatusesReceived: UInt64 = 0
    /// Tripwire: 0x25 track-state announcements received (gate
    /// closes, still-quiet check-ins, and wakes all count here).
    public var audioTrackStatesReceived: UInt64 = 0
    /// Video posture: 0x26 announcements received (ladder steps and
    /// wakes).
    public var videoPostureStatesReceived: UInt64 = 0
    /// Loud audio-routing drops (CL-13): an unnegotiated 0x19, or a
    /// role-confused 0x18 arriving AT the client — the host's rule-3
    /// gate, mirrored.
    public var audioRoutingDropsLoud: UInt64 = 0
    /// 0x1A clipboard sets this end put on the ordered stream (CL-15).
    public var clipboardSharesSent: UInt64 = 0
    /// 0x1B announces consumed and applied (CL-15).
    public var clipboardAnnouncesReceived: UInt64 = 0
    /// 0x24 cursor shapes consumed and worn (E3).
    public var cursorShapesReceived: UInt64 = 0
    /// Local changes the sync book suppressed (echo or duplicate).
    public var clipboardLoopSuppressed: UInt64 = 0
    /// Announces that arrived while the session toggle was OFF —
    /// counted and ignored, never applied (the consent posture).
    public var clipboardIgnoredDisabled: UInt64 = 0
    /// Loud clipboard drops: an unnegotiated 0x1B, or a role-confused
    /// 0x1A arriving AT the client.
    public var clipboardDropsLoud: UInt64 = 0
    /// Bulk messages this end put on chan 8's ordered stream (F-4).
    public var bulkMessagesSent: UInt64 = 0
    /// Decoded chan-8 bulk messages surfaced to the owner (F-4).
    public var bulkMessagesReceived: UInt64 = 0
    /// Loud bulk drops: a chan-8 message without negotiated key 11,
    /// or bytes the bulk codecs refused.
    public var bulkDropsLoud: UInt64 = 0
}

// MARK: - Config

public struct LyteUdpSessionCoreConfig: Sendable {
    /// What this client declares (0x0F). The default is the wire
    /// default — HEVC, 4:2:0, idle silence on, 1152 B ceiling — plus
    /// capability key 9 (hostAudioRouting) on the W7 unknown-entries
    /// spine (CL-13): this client can always RENDER the host-mute
    /// control, so it always declares; the intersection against the
    /// host decides whether the control exists.
    public var capabilities: Capabilities
    /// The receiver machine's timing. The default deviates from
    /// SessionMachineConfig's 350 ms blackout deliberately — see the
    /// file comment: 2.5 s is beacon-bounded until H2's audio provides
    /// the 5 ms path probe.
    public var machineConfig: SessionMachineConfig
    /// CL-11, the tightening the CL-8 deviation promised: once this
    /// session has SEEN audio (an authenticated chan-1 datagram — the
    /// 5 ms path probe, flowing in ACTIVE/IDLE/FROZEN per HS-15's
    /// lifecycle ruling), the blackout detector re-arms at this
    /// threshold — W4b's pillar figure. Evidence-gated rather than
    /// capability-gated deliberately: W7's registry carries only the
    /// reserved audioExpress escape hatch, no audio-presence key, so
    /// a no-audio host (--no-audio, or pre-HS-15) simply never
    /// tightens and keeps the 2.5 s beacon-bounded behavior. Nil
    /// disables tightening outright.
    public var tightenedBlackoutSilenceMicroseconds: Int64?
    /// The audio playout buffer's policy (CL-11).
    public var audioJitter: AudioJitterConfig
    /// The targeted-repair ask policy (CL-12).
    public var nackPolicy: NackPolicyConfig
    /// The session-start posture (CL-13, the per-host default's
    /// landing point): when set and key 9 survived intersection, the
    /// first 0x19 — the host's own starting posture, sent at
    /// capability agreement — is compared against this, and one 0x18
    /// leaves if they differ. Asked exactly ONCE per session (a host
    /// whose flip fails reports the old posture; re-asking forever
    /// would be a loop, and the strip's toggle is the live override).
    /// Nil takes the host's default without comment.
    ///
    /// DEFAULT FLIPPED BY CL-18 (owner hand-test verdict): a fresh
    /// config now desires `.hostMuted` — the Sunshine/Moonlight
    /// posture, sound follows the viewer while the host holds its
    /// tongue. Against a no-key-9 host nothing changes (the ask only
    /// ever fires on the host's first 0x19, which such a host never
    /// owes — the host plays, nothing we can do). Shells wanting the
    /// old neutral posture set nil explicitly (wire-view does, unless
    /// its --host-audio flag says otherwise).
    public var desiredHostAudioRouting: HostAudioRoutingMode?
    /// CL-15: the session's starting clipboard-sharing posture (the
    /// per-host "Share Clipboard" default's landing point; default
    /// OFF — clipboards carry passwords). Declaration is unaffected:
    /// key 10 is always declared (dialect, not consent — the key-9
    /// rule) and the strip's toggle flips sharing live via
    /// `setClipboardSharing`. While off, nothing leaves and nothing
    /// lands.
    public var shareClipboard: Bool
    /// P-1: the images rung of the consent tier (Off / Text only /
    /// Text + images — LYTE-PLAN §8). Images move only when THIS and
    /// `shareClipboard` are both on; default OFF like text. Declaration
    /// is unaffected — key 12 is always declared (dialect, not consent,
    /// the key-9/10/11 rule) — but an unwelcome inbound marker draws
    /// abort(declined) rather than text's silent ignore, because the
    /// image sender waits on a verdict.
    public var shareClipboardImages: Bool

    public init(
        capabilities: Capabilities = .wireDefault
            .declaringHostAudioRouting().declaringAudioStreamOff()
            .declaringClipboardText()
            // F-4: key 11 (bulkTransfer) — dialect, not consent (the
            // key-9/key-10 rule, third verse): this client can always
            // SEND a dropped file, so it always declares; whether an
            // offer is welcome is the HOST's standing toggle, which
            // decides whether the host declares — the intersection
            // gates the client's offers.
            .declaringBulkTransfer()
            // P-1: key 12 (clipboardImages) — dialect, fourth verse:
            // this client can always speak the 0x22 image-cargo
            // dialect, so it always declares; whether images actually
            // MOVE is the consent tier at both ends (the host's
            // --clipboard=images flag decides ITS declaration; ours
            // is gated live by shareClipboardImages).
            .declaringClipboardImages()
            // E3: key 13 (cursorShape) — dialect, fifth verse: this
            // client can always wear a 0x24 shape as its local
            // NSCursor, so it always declares; whether shapes SEND is
            // the host's capture-organ truth (only the direct eye,
            // whose video carries no cursor, declares its side).
            .declaringCursorShape()
            // Tripwire: key 15 (audioQuietPosture) — dialect, sixth
            // verse: this client can always honor an announced quiet
            // (relax the audio-fed blackout detector, let the jitter
            // buffer rest), so it always declares; whether the host
            // GATES is its own tripwire's verdict.
            .declaringAudioQuietPosture()
            // Video posture: key 16 — dialect, seventh verse: this
            // client can always arm its freshness expectations
            // against an ANNOUNCED keepalive interval, so it always
            // declares; whether the host backs off is its ladder.
            .declaringVideoQuietPosture(),
        machineConfig: SessionMachineConfig = SessionMachineConfig(
            blackoutSilenceMicroseconds: 2_500_000
        ),
        tightenedBlackoutSilenceMicroseconds: Int64? = 350_000,
        audioJitter: AudioJitterConfig = AudioJitterConfig(),
        nackPolicy: NackPolicyConfig = NackPolicyConfig(),
        desiredHostAudioRouting: HostAudioRoutingMode? = .hostMuted,
        shareClipboard: Bool = false,
        shareClipboardImages: Bool = false
    ) {
        self.capabilities = capabilities
        self.machineConfig = machineConfig
        self.tightenedBlackoutSilenceMicroseconds =
            tightenedBlackoutSilenceMicroseconds
        self.audioJitter = audioJitter
        self.nackPolicy = nackPolicy
        self.desiredHostAudioRouting = desiredHostAudioRouting
        self.shareClipboard = shareClipboard
        self.shareClipboardImages = shareClipboardImages
    }
}

// MARK: - The core (everything above the socket)

public final class LyteUdpSessionCore: @unchecked Sendable {
    public let config: LyteUdpSessionCoreConfig

    private let now: @Sendable () -> ClientTimestamp
    private let onEvent: @Sendable (LyteUdpSessionEvent) -> Void
    private let onVideoRecoveryDemand:
        @Sendable (VideoRecoveryCause, FrameNumber) -> Void
    private let onVideoRecoveryTrace:
        @Sendable (VideoRecoveryTraceEvent) -> Void

    // The parts. IUO because their callbacks reference self (the
    // PairingGateTests construction order).
    public private(set) var pipeline: LyteVideoPipeline!
    public private(set) var reliable: ReliableCtrlEndpoint!
    /// F-4: chan 8's OWN ArqEndpoint pair (client side) — the bulk
    /// stream never shares CTRL's, so a file cannot head-of-line-block
    /// a keystroke by construction (the W10 channel ruling).
    public private(set) var bulkReliable: ReliableCtrlEndpoint!
    public private(set) var echoResponder: BeaconEchoResponder!
    public private(set) var idrRequester: IdrRequester!
    public private(set) var feedback: FeedbackSender!
    public private(set) var input: InputSender!
    public private(set) var audio: AudioReceiver!
    /// CL-12: the targeted-repair ask policy behind the pipeline's
    /// repair-signal seam.
    public private(set) var nackPolicy: NackPolicy!
    public let clockModel: HostClockModel

    // Machine + negotiator + dispatch state, one lock.
    private let lock = NSLock()
    private var machine: SessionStateMachine<ClientClock>
    private var negotiator: CapabilityNegotiator
    private var lastState: SessionState = .active
    private var lastWireMode: SessionWireMode = .active
    /// The 0x19-confirmed posture of the host's own speakers (CL-13);
    /// nil until the first status lands. Never set optimistically —
    /// the strip renders exactly this.
    private var hostAudioPosture: HostAudioRoutingMode?
    /// The session-start ask fires at most once (config comment).
    private var sessionStartAudioAskDone = false
    /// CL-15: the live clipboard-sharing toggle (seeded from the
    /// config's per-host default; the strip flips it). Gates BOTH
    /// directions — nothing leaves, nothing lands, while off.
    private var clipboardSharingOn: Bool
    /// CL-15: the loop-prevention/dedupe books (the host runs the
    /// identical type on its side).
    private var clipboardBook = ClipboardSyncBook()
    /// P-1: the images rung's live toggle (seeded from the config's
    /// per-host default). Images move only when clipboardSharingOn
    /// AND this are true — the Text + images tier.
    private var clipboardImagesOn: Bool
    /// P-1: the clipboard-image lane (Wire's sans-IO channel — the
    /// host runs the identical type). Shares clipboardBook so
    /// cross-modal echoes suppress.
    private var imageChannel = ClipboardImageChannel()
    /// Transfer-id minting for image shares. System randomness is
    /// fine here — ids only need collision resistance on one chan-8
    /// stream, not determinism (tests drive the channel directly).
    private var imageRng = SystemRandomNumberGenerator()
    /// V-5: the negotiated-posture audit — SPS chroma_format_idc off
    /// every IDR against the agreed chroma singleton (confirmation
    /// once, DOCTOR line on a mismatch edge).
    private var chromaAudit = ChromaStreamAudit()
    private var counters = LyteUdpSessionCounters()
    /// True once the first authenticated chan-1 datagram landed and
    /// (config permitting) the detector re-armed at 350 ms.
    public private(set) var detectorTightened = false
    /// Video posture: the last 0x26 the host announced (nil = never
    /// announced — the always-on contract). Read by the UI's pill.
    public private(set) var announcedVideoPosture: VideoPostureState?
    /// Audio posture: true between a 0x25 quiet announcement and the
    /// next evidence of life (a 0x25 active or an audio datagram).
    /// Read by the benchmark witness so intentional stillness is not
    /// booked as an audio blackout.
    public private(set) var hostAnnouncedAudioQuiet = false

    /// The production machine-poll wake; nil until `startTimers()`.
    private var machineTimer: DispatchSourceTimer?

    /// The per-datagram evidence book, off the hot path: every accepted
    /// datagram stamps this relaxed atomic instead of taking the core
    /// lock for a machine pass (apply + poll + two action arrays,
    /// ~3k×/s). The 100 ms beat feeds the machine the newest stamp at
    /// its TRUE arrival instant, so the blackout detector's and the
    /// liveness clock's bookkeeping stay exact; only the FROZEN exit
    /// wants datagram latency, and `machineFrozen` routes those (rare)
    /// passes through the immediate path.
    private let lastEvidenceMicros = Atomic<UInt64>(0)
    private let machineFrozen = Atomic<Bool>(false)
    /// Beat-context bookkeeping (guarded by `lock`): the stamp last
    /// fed to the machine.
    private var lastFedEvidenceMicros: UInt64 = 0
    /// Upstream half of the renderer recovery gate. Sample construction may
    /// already be queued when assembler damage is discovered; this fence
    /// prevents those completed P samples from racing the handoff flush.
    /// It shares the exact same close seam as IdrRequester and the handoff.
    private var videoRecoveryOutstanding = false

    public init(
        demux: ReceiveDemux,
        sender: TransportSender,
        config: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig(),
        clockModel: HostClockModel = HostClockModel(),
        asynchronousVideoBuild: Bool = false,
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(
                microseconds: SystemMonotonicClock.nowMicroseconds)
        },
        onVideoRecoveryDemand: @escaping @Sendable (
            VideoRecoveryCause, FrameNumber
        ) -> Void = { _, _ in },
        onVideoRecoveryTrace: @escaping @Sendable (
            VideoRecoveryTraceEvent
        ) -> Void = { _ in },
        videoSink: any VideoSink,
        onEvent: @escaping @Sendable (LyteUdpSessionEvent) -> Void
    ) {
        let sessionSink = SessionVideoSink(downstream: videoSink)
        self.config = config
        self.clockModel = clockModel
        self.now = now
        self.onEvent = onEvent
        self.onVideoRecoveryDemand = onVideoRecoveryDemand
        self.onVideoRecoveryTrace = onVideoRecoveryTrace
        self.clipboardSharingOn = config.shareClipboard
        self.clipboardImagesOn = config.shareClipboardImages
        // The machine begins at establishment (the shell constructs the
        // core only after the Noise handshake), streaming: ACTIVE.
        self.machine = SessionStateMachine(
            role: .mediaReceiver,
            config: config.machineConfig,
            now: now()
        )
        self.negotiator = CapabilityNegotiator(
            role: .client, local: config.capabilities
        )

        self.pipeline = LyteVideoPipeline(
            asynchronousSampleBuild: asynchronousVideoBuild,
            nowNanoseconds: { now().microseconds &* 1_000 },
            sink: sessionSink,
            onFecImpossible: { [weak self] frame, _, _ in
                // CL-12: a frame with a live repair ask holds its IDR
                // for the rule-4 window; everything else requests as
                // CL-3 always did (the policy escalates expiries back
                // through the same requester).
                guard let self else { return }
                let now = self.now()
                if !self.nackPolicy.shouldDeferFecImpossible(
                    frame: frame, now: now
                ) {
                    self.beginVideoRecovery(
                        cause: .fecAssemblerDamage, frame: frame, now: now)
                }
            },
            onRepairSignal: { [weak self] signal, now in
                guard let self else { return }
                if case .framesGone(let from, _) = signal {
                    self.beginVideoRecovery(
                        cause: .hostPurgeInferredDamage,
                        frame: from, now: now)
                }
                self.nackPolicy.handle(signal, now: now)
            })
        self.reliable = ReliableCtrlEndpoint(
            sender: sender,
            now: now,
            onEvent: { [weak self] event in
                self?.dispatchReliable(event)
            })
        self.bulkReliable = ReliableCtrlEndpoint(
            sender: sender,
            channel: .bulkTransfer,
            now: now,
            onEvent: { [weak self] event in
                self?.dispatchBulk(event)
            })
        self.input = InputSender(
            clockModel: clockModel,
            send: { [weak self] message, now in
                try self?.reliable.send(message, now: now)
            })
        self.echoResponder = BeaconEchoResponder(
            now: now,
            onClockSample: { [weak self] in self?.clockModel.ingest($0) },
            emit: { [weak self] echo in
                guard let self else { return }
                _ = try? sender.send(
                    channel: .ctrl, timestamp: self.now(),
                    plaintext: echo.encode())
            })
        self.idrRequester = IdrRequester(emit: { [weak self] request in
            guard let self else { return }
            _ = try? sender.send(
                channel: .ctrl, timestamp: self.now(),
                plaintext: request.encode())
        })
        self.feedback = FeedbackSender(
            demux: demux, sender: sender,
            onTick: { [weak self] tickNow in
                self?.idrRequester.flushIfDue(now: tickNow)
                self?.nackPolicy.tick(now: tickNow)
            })
        self.nackPolicy = NackPolicy(
            config: config.nackPolicy,
            rtt: { [weak self] in
                self?.clockModel.estimate()?.minRttMicroseconds
            },
            emit: { [weak self] entries in
                guard let self else { return }
                // Enqueue + an immediate out-of-cadence report: the
                // host's rule-3 freeze budget is derived from the
                // cadence (HS-32, ~1.5×) — an ask that skips the wait
                // spends none of it.
                self.feedback.enqueueNacks(entries)
                self.feedback.tick(now: self.now())
                for entry in entries {
                    self.onEvent(.protocolNote(
                        "nack: frame \(entry.frame.rawValue) asks "
                        + "shards \(entry.missingShards)"))
                }
            },
            escalate: { [weak self] frame, now in
                guard let self else { return }
                self.beginVideoRecovery(
                    cause: .fecAssemblerDamage, frame: frame, now: now)
                // Reason-neutral: this closure exits deadline expiries,
                // framesGone, AND HS-32 refusals (which already printed
                // their own reasoned note); the books tell them apart.
                self.onEvent(.protocolNote(
                    "nack: frame \(frame.rawValue) repair abandoned — "
                    + "IDR instead"))
            })
        self.audio = AudioReceiver(jitterConfig: config.audioJitter)
        sessionSink.bind(self)
    }

    /// Pure session verdict at the native-media boundary. CoreMedia forwarding
    /// stays in `SessionVideoSink`; the core sees only the decoded wire unit.
    /// Returns true exactly when the adapter may submit downstream.
    func admitVideoUnit(_ unit: DecodeUnit) -> Bool {
        // The input→photon seam (CL-9): a DELIVERED frame whose shards
        // carried the lastInputSeq TLV closes every pending event at or below
        // its stamp. Delivery — not shard arrival — is the honest instant.
        lock.lock()
        let mayRender = !videoRecoveryOutstanding || unit.isIDR
        lock.unlock()
        guard mayRender else {
            onVideoRecoveryTrace(.init(
                kind: "coreRejectedNonIrap",
                frame: unit.frameNumber,
                isRandomAccess: false))
            return false
        }
        if unit.isIDR {
            onVideoRecoveryTrace(.init(
                kind: "coreForwardedIrap",
                frame: unit.frameNumber,
                isRandomAccess: true))
        }
        input.noteFrameDelivered(frame: unit.frameNumber, now: now())
        // V-5: IDRs carry parameter sets in-band. Audit actual chroma against
        // the negotiated posture; mismatch is a doctor line, never a silent
        // resample.
        if unit.isIDR {
            auditStreamChroma(annexB: unit.annexB)
        }
        return true
    }

    // MARK: Lifecycle

    /// The first reliable word: this end's capability declaration
    /// (0x0F) on the ARQ ordered stream — everything gated on a
    /// capability orders behind it for free (W7's rule; the host does
    /// the same from its side).
    public func open(now: ClientTimestamp) throws {
        lock.lock()
        guard let declaration = negotiator.start() else {
            lock.unlock()
            return
        }
        lock.unlock()
        try reliable.send(try declaration.encode(), now: now)
    }

    public func open() throws {
        try open(now: now())
    }

    /// Production timers: the ARQ PTO wake, pipeline eviction, the
    /// feedback cadence, and a 100 ms machine-poll beat (granular
    /// enough for the 2.5 s detector and the 30 s liveness clock).
    /// Tests never call this — they drive `tick(now:)`.
    public func startTimers() {
        reliable.start()
        bulkReliable.start()
        pipeline.start()
        feedback.start()
        lock.lock()
        defer { lock.unlock() }
        guard machineTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .milliseconds(100),
                       repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.machineBeat(now: self.now())
        }
        timer.resume()
        machineTimer = timer
    }

    public func stopTimers() {
        lock.lock()
        let timer = machineTimer
        machineTimer = nil
        lock.unlock()
        timer?.cancel()
        feedback.stop()
        reliable.stop()
        bulkReliable.stop()
        pipeline.stop()
    }

    /// One virtual-time beat for tests: machine poll + ARQ PTO +
    /// pipeline eviction (feedback stays caller-driven — its reports
    /// are a cadence choice, not a correctness one).
    public func tick(now: ClientTimestamp) {
        reliable.tick(now: now)
        bulkReliable.tick(now: now)
        pipeline.tick(now: now)
        nackPolicy.tick(now: now)
        machineBeat(now: now)
    }

    /// The machine's beat (production timer and test tick alike): any
    /// evidence stamped since the last beat is fed first, at its true
    /// arrival instant — exact detector/liveness bookkeeping, deferred
    /// at most one beat — then the pure poll runs at `now`.
    private func machineBeat(now: ClientTimestamp) {
        let stamped = lastEvidenceMicros.load(ordering: .relaxed)
        var feed: ClientTimestamp?
        lock.lock()
        if stamped > lastFedEvidenceMicros {
            lastFedEvidenceMicros = stamped
            feed = ClientTimestamp(microseconds: stamped)
        }
        lock.unlock()
        if let feed { applyMachine(.mediaPathEvidence, now: feed) }
        applyMachine(nil, now: now)
    }

    /// An orderly local close: the typed teardown leaves on the
    /// ordered stream (retransmitting until acknowledged) and the
    /// machine closes. The caller lingers on `isReliableQuiescent`
    /// before tearing the socket down (the host's beginTeardown
    /// discipline, mirrored).
    public func beginTeardown(
        reason: SessionTeardownReason, now: ClientTimestamp
    ) {
        applyMachine(.teardownRequest(reason), now: now)
    }

    public func beginTeardown(reason: SessionTeardownReason) {
        beginTeardown(reason: reason, now: now())
    }

    // MARK: Input (CL-9)

    /// Queues one captured input event on the reliable ordered stream
    /// (0x16), stamped `now` and sequenced by the session's counter.
    /// NEVER gated on wire mode or the FROZEN overlay: the host runs
    /// `.preArmInput` on every delivered event BEFORE injecting, so an
    /// event in IDLE is the WAKE and one during a blackout persists
    /// through FROZEN into RECOVERY's IDR (W4b via HS-13) — sending
    /// promptly IS how this end drives the pre-arm seam. Returns the
    /// allocated seq; throws what the reliable endpoint throws.
    @discardableResult
    public func sendInput(
        _ body: InputEvent.Body, now: ClientTimestamp
    ) throws -> UInt32 {
        try input.send(body, now: now)
    }

    @discardableResult
    public func sendInput(_ body: InputEvent.Body) throws -> UInt32 {
        try sendInput(body, now: now())
    }

    /// App renderer failure/backpressure joins the established IDR recovery
    /// policy instead of inventing an uncoalesced control path.
    public func requestVideoRecovery(
        after frame: FrameNumber,
        cause: VideoRecoveryCause = .rendererFailure
    ) {
        beginVideoRecovery(cause: cause, frame: frame, now: now())
    }

    /// The sole close seam: AVFoundation accepted the IRAP into its queue.
    public func noteVideoIrapEnqueued(
        frame: FrameNumber = FrameNumber(rawValue: 0)
    ) {
        lock.lock()
        videoRecoveryOutstanding = false
        lock.unlock()
        idrRequester.noteUsableIrapAccepted()
        onVideoRecoveryTrace(.init(
            kind: "coreRecoveryClosedAfterIrapEnqueue",
            frame: frame,
            isRandomAccess: true))
    }

    private func beginVideoRecovery(
        cause: VideoRecoveryCause,
        frame: FrameNumber,
        now: ClientTimestamp
    ) {
        lock.lock()
        let overlap = videoRecoveryOutstanding
        videoRecoveryOutstanding = true
        lock.unlock()
        onVideoRecoveryTrace(.init(
            kind: overlap ? "coreDamageOverlap" : "coreDamageKnown",
            frame: frame,
            cause: cause))
        // Queue the renderer gate before emitting the request. The app's
        // serial handoff then observes this before any later sink submit.
        onVideoRecoveryDemand(cause, frame)
        idrRequester.recordRecoveryDemand(frame: frame, now: now)
    }

    // MARK: Host audio routing (CL-13)

    /// Asks the host to flip its own speakers (0x18 on the ARQ ordered
    /// stream) — the strip's live override. Refused HERE when key 9
    /// never survived intersection (the rule-3 gate: the host would
    /// only drop the ask loud) or before the exchange settled. The
    /// posture does NOT change on send: it changes when the host's
    /// 0x19 answer says it did.
    public func requestHostAudioRouting(
        _ mode: HostAudioRoutingMode, now: ClientTimestamp
    ) throws {
        lock.lock()
        guard negotiator.agreed?.hostAudioRouting == true else {
            lock.unlock()
            throw AudioRoutingAskError.notNegotiated
        }
        // The key-14 gate: streamOff is a separate dialect — a legacy
        // host would reject the byte as a protocol break, so the
        // refusal happens HERE, typed, before anything leaves.
        if mode == .streamOff, negotiator.agreed?.audioStreamOff != true {
            lock.unlock()
            throw AudioRoutingAskError.streamOffNotNegotiated
        }
        counters.audioRoutingRequestsSent += 1
        lock.unlock()
        try reliable.send(AudioRoutingRequest(mode: mode).encode(), now: now)
    }

    public func requestHostAudioRouting(_ mode: HostAudioRoutingMode) throws {
        try requestHostAudioRouting(mode, now: now())
    }

    // MARK: Clipboard (CL-15)

    /// True when capability key 10 survived intersection — the
    /// strip's clipboard toggle exists exactly when this is true.
    public var clipboardNegotiated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return negotiator.agreed?.clipboardText == true
    }

    /// The live sharing toggle's state (seeded from the per-host
    /// default; nothing leaves and nothing lands while false).
    public var clipboardSharingEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clipboardSharingOn
    }

    /// The strip's live override for clipboard sharing. Local policy
    /// only — no wire message exists for it in v1 (design doc §1's
    /// named non-goal), so a disabled end simply goes quiet and deaf.
    public func setClipboardSharing(_ enabled: Bool) {
        lock.lock()
        clipboardSharingOn = enabled
        lock.unlock()
    }

    /// The pasteboard watcher's funnel: one local clipboard change,
    /// judged (negotiated → enabled → the sync book → the ceiling) and
    /// shared as a 0x1A when it survives. Never throws — the poller
    /// has nobody to catch for it; the outcome is counted and
    /// returned.
    @discardableResult
    public func shareLocalClipboard(
        _ text: String, now: ClientTimestamp
    ) -> ClipboardShareOutcome {
        lock.lock()
        guard negotiator.agreed?.clipboardText == true else {
            lock.unlock()
            return .notNegotiated
        }
        guard clipboardSharingOn else {
            lock.unlock()
            return .sharingDisabled
        }
        switch clipboardBook.admitLocalChange(text) {
        case .suppressEcho:
            counters.clipboardLoopSuppressed += 1
            lock.unlock()
            return .suppressedEcho
        case .suppressDuplicate:
            counters.clipboardLoopSuppressed += 1
            lock.unlock()
            return .suppressedDuplicate
        case .share:
            break
        }
        lock.unlock()
        let message: [UInt8]
        do {
            message = try ClipboardSet(text: text).encode()
        } catch {
            // Empty or over the v1 ceiling: suppressed weather.
            return .overBudget(text.utf8.count)
        }
        do {
            try reliable.send(message, now: now)
        } catch {
            return .sendRefused(String(describing: error))
        }
        lock.lock()
        clipboardBook.noteShared(text)
        counters.clipboardSharesSent += 1
        lock.unlock()
        return .shared
    }

    @discardableResult
    public func shareLocalClipboard(_ text: String) -> ClipboardShareOutcome {
        shareLocalClipboard(text, now: now())
    }

    // MARK: Clipboard images (P-1, clipboard v2)

    /// True when capability keys 10 AND 12 both survived intersection
    /// — the images rung of the consent tier exists exactly when this
    /// is true. Key 11 (file consent) is deliberately not consulted:
    /// the tiers do not couple (a no-files host still syncs images).
    public var clipboardImagesNegotiated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return negotiator.agreed?.clipboardImagesAgreed == true
    }

    /// The images rung's live state: images move only when sharing
    /// is on AND the rung is on (Text + images, LYTE-PLAN §8).
    public var clipboardImageSharingEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clipboardSharingOn && clipboardImagesOn
    }

    /// The strip's live override for the images rung. Local policy
    /// only, like `setClipboardSharing` — but a disabled end is not
    /// merely deaf: an inbound marker draws abort(declined), because
    /// the image sender waits on a verdict.
    public func setClipboardImageSharing(_ enabled: Bool) {
        lock.lock()
        clipboardImagesOn = enabled
        lock.unlock()
    }

    /// The image lane's own books (Wire's channel counts; these
    /// complement the session counters the same way audio's do).
    public var clipboardImageCounters: ClipboardImageChannelCounters {
        lock.lock()
        defer { lock.unlock() }
        return imageChannel.counters
    }

    /// The pasteboard watcher's image funnel: one local image copy
    /// (PNG bytes in v2), judged (negotiated → tier → the shared sync
    /// book → the lane → the 32 MiB ceiling) and shared as 0x22 cargo
    /// on chan 8 when it survives. Never throws — the poller has
    /// nobody to catch for it.
    @discardableResult
    public func shareLocalClipboardImage(
        _ data: [UInt8], now: ClientTimestamp
    ) -> ClipboardShareOutcome {
        lock.lock()
        guard negotiator.agreed?.clipboardImagesAgreed == true else {
            lock.unlock()
            return .notNegotiated
        }
        guard clipboardSharingOn, clipboardImagesOn else {
            lock.unlock()
            return .sharingDisabled
        }
        let events = imageChannel.shareLocalImage(
            data, sha256: Sha256.digest(data),
            book: &clipboardBook, rng: &imageRng
        )
        lock.unlock()
        return processImageEvents(events, now: now)
    }

    @discardableResult
    public func shareLocalClipboardImage(
        _ data: [UInt8]
    ) -> ClipboardShareOutcome {
        shareLocalClipboardImage(data, now: now())
    }

    /// One batch of channel events into the world: `.send` rides
    /// chan 8's ordered stream, `.applyImage` becomes the typed event
    /// (payload bytes appear THERE and nowhere else — the CL-15 rule),
    /// the rest is protocol weather. Returns the share verdict for
    /// the funnel's caller; called OUTSIDE the lock (the v1 send
    /// pattern — the reliable endpoint's callbacks take our lock).
    @discardableResult
    private func processImageEvents(
        _ events: [ClipboardImageEvent], now: ClientTimestamp
    ) -> ClipboardShareOutcome {
        var outcome: ClipboardShareOutcome = .shared
        for event in events {
            switch event {
            case .send(let bytes):
                bulkReliable.adoptConnectionId(reliable.learnedConnectionId)
                do {
                    try bulkReliable.send(bytes, now: now)
                } catch {
                    outcome = .sendRefused(String(describing: error))
                }
            case .shareStarted:
                outcome = .shared
            case .shareCompleted(_, let byteCount):
                onEvent(.protocolNote(
                    "clipboard image landed on the host sha-exact "
                        + "(\(byteCount) B)"))
            case .shareAborted(let reason, let byRemote):
                onEvent(.protocolNote(
                    "clipboard image share aborted "
                        + "(\(reason), \(byRemote ? "remote" : "local"))"))
            case .receiveAborted(let reason, let byRemote):
                onEvent(.protocolNote(
                    "incoming clipboard image aborted "
                        + "(\(reason), \(byRemote ? "remote" : "local"))"))
            case .suppressed(let reason):
                switch reason {
                case .loopEcho: outcome = .suppressedEcho
                case .duplicate: outcome = .suppressedDuplicate
                case .overBudget(let count): outcome = .overBudget(count)
                case .emptyImage: outcome = .overBudget(0)
                case .sendBusy: outcome = .suppressedBusy
                }
            case .refused(let reason):
                onEvent(.protocolNote(
                    "incoming clipboard image refused (\(reason))"))
            case .applyImage(let data, let mime):
                onEvent(.hostClipboardImageChanged(data: data, mime: mime))
            case .violated(let violation):
                onEvent(.protocolNote(
                    "clipboard image lane violation: \(violation)"))
            }
        }
        return outcome
    }

    // MARK: Bulk transfer (F-4)

    /// True when capability key 11 survived intersection — the host's
    /// standing consent toggle is ON and it accepts file offers. The
    /// drop target's gate.
    public var bulkTransferNegotiated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return negotiator.agreed?.bulkTransfer == true
    }

    /// Queues one encoded bulk message on chan 8's ARQ ordered stream.
    /// Refused HERE when key 11 never survived intersection (the
    /// rule-3 gate: offer only into an agreed set — H3 §0 decision 1).
    public func sendBulkMessage(
        _ message: [UInt8], now: ClientTimestamp
    ) throws {
        lock.lock()
        guard negotiator.agreed?.bulkTransfer == true else {
            lock.unlock()
            throw BulkChannelError.notNegotiated
        }
        counters.bulkMessagesSent += 1
        lock.unlock()
        // Chan 8 borrows the ctrl-learned connection ID so the very
        // first bulk datagram already carries the tag (HS-12's
        // every-packet rule; chan-8 inbound teaches it too).
        bulkReliable.adoptConnectionId(reliable.learnedConnectionId)
        try bulkReliable.send(message, now: now)
    }

    public func sendBulkMessage(_ message: [UInt8]) throws {
        try sendBulkMessage(message, now: now())
    }

    // MARK: Ingest

    /// The endpoint's per-datagram hook: routes accepted payloads to
    /// their consumers and feeds the lifecycle machine's evidence
    /// clocks (every authenticated arrival — the file comment's
    /// receiver-side evidence rule).
    ///
    /// The arrival stamp is DELIBERATELY discarded (A-25): it may be
    /// kernel wall-clock (SCM_TIMESTAMP) while every clock in here —
    /// the echo responder's t2 included — lives on the session's
    /// injected monotonic `now()`. Wiring it into t2 would mix clock
    /// domains and corrupt every RTT sample; the discard binding makes
    /// the compiler hold that line.
    public func handleDatagram(
        _ outcome: IngestOutcome, arrivalMicroseconds _: UInt64
    ) {
        guard case .accepted(let envelope, let payload) = outcome else {
            return
        }
        let now = now()
        if envelope.channel == .ctrl {
            // CL-7's one-byte peek: 0x07/0x08 payloads are wholly ARQ
            // (delivery events dispatch from the endpoint's hook);
            // everything else falls through to the exempt paths.
            if !reliable.handleCtrlDatagram(
                envelope: envelope, payload: payload, now: now
            ) {
                if !echoResponder.handleCtrlPayload(
                    payload, arrivalMicroseconds: now.microseconds
                ) {
                    handleExemptCtrl(payload, now: now)
                }
            }
        } else if envelope.channel == pipeline.channel {
            // Any one shard's lastInputSeq TLV (0x03) associates the
            // frame with the newest injected input — recorded before
            // ingest so the association exists when delivery fires
            // from this same pass.
            input.noteVideoShard(envelope: envelope)
            pipeline.ingest(envelope: envelope, payload: payload, now: now)
        } else if envelope.channel == .bulkTransfer {
            // F-4: the whole channel is ARQ carriage by design — no
            // exempt path exists on chan 8.
            bulkReliable.adoptConnectionId(reliable.learnedConnectionId)
            _ = bulkReliable.handleCtrlDatagram(
                envelope: envelope, payload: payload, now: now)
        } else if envelope.channel == .audio {
            // CL-11: the 5 ms path probe. Depacketize/recover/buffer,
            // and — first time only — tighten the blackout detector
            // to the pillar's 350 ms: with audio flowing in every
            // non-closed state (HS-15's lifecycle ruling), 350 ms of
            // total silence honestly means the path is dark.
            lock.lock()
            counters.audioDatagramsReceived += 1
            lock.unlock()
            if hostAnnouncedAudioQuiet { hostAnnouncedAudioQuiet = false }
            audio.ingest(envelope: envelope, payload: payload, now: now)
            tightenDetectorIfNeeded(now: now)
        }
        // Evidence is a timestamp, not work: stamp it and move on. The
        // beat feeds it to the machine; FROZEN (the one state where a
        // datagram must act NOW — the pill clears on this evidence)
        // keeps the immediate pass.
        lastEvidenceMicros.store(now.microseconds, ordering: .relaxed)
        if machineFrozen.load(ordering: .relaxed) {
            applyMachine(.mediaPathEvidence, now: now)
        }
    }

    /// HS-32: the ARQ-exempt CTRL types beyond the beacon. A 0x23
    /// repair refusal ends the named frame's repair wait immediately —
    /// the policy escalates it to the existing rate-windowed IDR
    /// requester. Anything else (unknown types included) is skipped
    /// silently — the forward-compat contract this very message's
    /// key-free append relies on. Malformed refusals count and drop;
    /// hostile bytes never stop the exempt path.
    private func handleExemptCtrl(
        _ payload: [UInt8], now: ClientTimestamp
    ) {
        guard payload.first == CtrlMessageType.repairRefused else {
            return
        }
        guard let refusal = try? RepairRefusal.decode(payload) else {
            noteMalformed("repair refusal")
            return
        }
        onEvent(.protocolNote(
            "nack: frame \(refusal.frame.rawValue) repair refused "
            + "by host (\(refusal.reason)) — IDR now"))
        nackPolicy.handleRefusal(frame: refusal.frame, now: now)
    }

    /// Tripwire (0x25): the host's audio track-state announcement —
    /// silence with a signed IOU. Quiet relaxes the audio-fed
    /// blackout detector back to the beacon-bounded threshold (gated
    /// silence is CONTRACT, not evidence of a dark path — without
    /// this, 350 ms into the first announced quiet the session would
    /// false-FROZEN) and rests the jitter adaptation across the gap.
    /// Active precedes the wake's pre-roll burst; the burst's first
    /// authenticated datagram re-tightens the detector through the
    /// existing evidence rule (`detectorTightened` was reset).
    private func receiveAudioTrackState(
        _ bytes: [UInt8], now: ClientTimestamp
    ) {
        guard let message = try? AudioTrackState.decode(bytes) else {
            noteMalformed("audio track state")
            return
        }
        lock.lock()
        guard negotiator.agreed?.audioQuietPosture == true else {
            lock.unlock()
            onEvent(.protocolNote(
                "audio track-state 0x25 without negotiated key 15 — dropped"))
            return
        }
        counters.audioTrackStatesReceived += 1
        lock.unlock()
        switch message.state {
        case .quiet:
            hostAnnouncedAudioQuiet = true
            audio.noteAnnouncedQuiet()
            relaxDetectorForAnnouncedQuiet(now: now)
        case .active:
            // The resumed packets are the evidence; nothing to arm
            // here — the tighten path owns the transition.
            hostAnnouncedAudioQuiet = false
        }
    }

    /// Video posture (0x26): the host's keepalive ladder announcement.
    /// v1 consumers: the counter, the note, and the stored posture the
    /// UI's pill can render as calm idle — video freshness alarms were
    /// already gap-normalized (#66), so no detector rebuild is needed
    /// on this axis; the announcement makes the slow heartbeat HONEST
    /// rather than survivable.
    private func receiveVideoPostureState(_ bytes: [UInt8]) {
        guard let message = try? VideoPostureState.decode(bytes) else {
            noteMalformed("video posture state")
            return
        }
        lock.lock()
        guard negotiator.agreed?.videoQuietPosture == true else {
            lock.unlock()
            onEvent(.protocolNote(
                "video posture 0x26 without negotiated key 16 — dropped"))
            return
        }
        counters.videoPostureStatesReceived += 1
        let changed = announcedVideoPosture != message
        announcedVideoPosture = message
        lock.unlock()
        if changed {
            onEvent(.protocolNote(message.posture == .quiet
                ? "video quiet — keepalive \(message.keepaliveSeconds)s "
                    + "announced"
                : "video active — keepalive 1 s"))
        }
    }

    /// The tighten's mirror: rebuilds the receiver machine at the
    /// beacon-bounded default and clears `detectorTightened`, so the
    /// wake's first audio datagram tightens it right back. No-op when
    /// already relaxed (check-ins repeat every ~5 s by design).
    private func relaxDetectorForAnnouncedQuiet(now: ClientTimestamp) {
        lock.lock()
        guard detectorTightened, machine.state != .closed else {
            lock.unlock()
            return
        }
        detectorTightened = false
        var rebuilt = SessionStateMachine<ClientClock>(
            role: .mediaReceiver, config: config.machineConfig, now: now)
        _ = rebuilt.apply(.modeMessage(machine.wireMode), now: now)
        machine = rebuilt
        lock.unlock()
        onEvent(.protocolNote(String(
            format: "audio quiet announced — blackout detector relaxed "
                + "to %d ms",
            config.machineConfig.blackoutSilenceMicroseconds / 1_000)))
    }

    /// Rebuilds the receiver machine at the tightened threshold,
    /// transplanting the wire mode (a receiver machine's only durable
    /// state — FROZEN would exit on this very evidence anyway, and
    /// RECOVERY/pre-arm are sender-role). Wire/ stays untouched: the
    /// config was always the injection point.
    private func tightenDetectorIfNeeded(now: ClientTimestamp) {
        guard let tightened = config.tightenedBlackoutSilenceMicroseconds
        else { return }
        lock.lock()
        guard !detectorTightened, machine.state != .closed else {
            lock.unlock()
            return
        }
        detectorTightened = true
        var machineConfig = config.machineConfig
        machineConfig.blackoutSilenceMicroseconds = tightened
        var rebuilt = SessionStateMachine<ClientClock>(
            role: .mediaReceiver, config: machineConfig, now: now)
        _ = rebuilt.apply(.modeMessage(machine.wireMode), now: now)
        // lastState/lastWireMode stay untouched: the next applyMachine
        // pass surfaces any edge this rebuild caused (e.g. a FROZEN
        // pill clearing on this very evidence).
        machine = rebuilt
        lock.unlock()
        onEvent(.protocolNote(String(
            format: "audio evidence — blackout detector tightened to %d ms",
            tightened / 1_000)))
    }

    /// One IDR's chroma audit pass: parse the in-band SPS, feed the
    /// audit under the lock, surface whatever it has to say. A frame
    /// without a parseable SPS says nothing (an IRAP without in-band
    /// parameter sets keeps the current posture — the factory's rule).
    private func auditStreamChroma(annexB: [UInt8]) {
        guard let idc = HevcSpsChroma.chromaFormatIdc(inAnnexB: annexB)
        else { return }
        lock.lock()
        let line = chromaAudit.observe(
            chromaFormatIdc: idc,
            agreedChromaModes: negotiator.agreed?.chromaModes)
        lock.unlock()
        if let line { onEvent(.protocolNote(line)) }
    }

    // MARK: Snapshots

    /// V-5: the stream's observed chroma ("4:2:0"/"4:4:4"), nil
    /// before the first IDR with in-band parameter sets — the stats
    /// overlay's truth about what the wire actually carries.
    public var streamChromaDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return chromaAudit.observedDescription
    }

    public var state: SessionState {
        lock.lock()
        defer { lock.unlock() }
        return machine.state
    }

    public var wireMode: SessionWireMode {
        lock.lock()
        defer { lock.unlock() }
        return machine.wireMode
    }

    /// The CL-8 pill: true while the local overlay says the path is
    /// dark. Never a wire state; never modal in the UI.
    public var isFrozen: Bool { state == .frozen }

    public var agreedCapabilities: Capabilities? {
        lock.lock()
        defer { lock.unlock() }
        return negotiator.agreed
    }

    /// True when capability key 9 survived intersection — the strip's
    /// host-mute button exists exactly when this is true (CL-13).
    public var hostAudioRoutingNegotiated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return negotiator.agreed?.hostAudioRouting == true
    }

    /// The 0x19-confirmed posture of the host's own speakers; nil
    /// until the host's first status (or forever, against a no-key-9
    /// host). Never optimistic.
    public var hostAudioRoutingPosture: HostAudioRoutingMode? {
        lock.lock()
        defer { lock.unlock() }
        return hostAudioPosture
    }

    public var isReliableQuiescent: Bool { reliable.isQuiescent }

    public func snapshotCounters() -> LyteUdpSessionCounters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    // MARK: The machine

    /// Applies one input (or none — a pure timer beat), fires the
    /// machine's timers, executes its actions, and surfaces state/mode
    /// edges. The single funnel for every lifecycle mutation.
    private func applyMachine(
        _ input: SessionInput?, now: ClientTimestamp
    ) {
        lock.lock()
        var actions: [SessionAction] = []
        if let input {
            actions += machine.apply(input, now: now)
        }
        let (polled, _) = machine.poll(now: now)
        actions += polled
        let state = machine.state
        let mode = machine.wireMode
        let stateEdge = state != lastState
        let modeEdge = mode != lastWireMode
        lastState = state
        lastWireMode = mode
        machineFrozen.store(state == .frozen, ordering: .relaxed)
        lock.unlock()

        for action in actions {
            switch action {
            case .sendTeardownMessage(let reason):
                do {
                    try reliable.send(
                        SessionTeardown(reason: reason).encode(), now: now)
                    onEvent(.teardownSent(reason))
                } catch {
                    onEvent(.protocolNote(
                        "teardown send refused: \(error)"))
                }
            case .sessionClosed(let reason):
                onEvent(.closed(reason))
            case .sendModeMessage, .sendFinalFrameReliably,
                 .armNextDamageAsIdr, .forceIdr,
                 .freezeDatagramSends, .resumeDatagramSends:
                break   // sender-role actions; a receiver never emits them
            }
        }
        if modeEdge { onEvent(.modeChanged(mode)) }
        if stateEdge { onEvent(.stateChanged(state)) }
    }

    // MARK: Reliable dispatch

    /// Every ARQ delivery, dispatched by its own CTRL type byte — the
    /// host Session's consumeReliable, mirrored for the client's
    /// registered consumers. Hostile bytes are counted, never fatal.
    private func dispatchReliable(_ event: ArqEvent) {
        guard case .message(_, let bytes) = event else { return }
        let now = now()
        switch bytes.first {
        case CtrlMessageType.modeTransition:
            guard let transition = try? ModeTransition.decode(bytes) else {
                noteMalformed("mode transition")
                return
            }
            lock.lock()
            counters.modeTransitionsReceived += 1
            lock.unlock()
            applyMachine(.modeMessage(transition.mode), now: now)

        case CtrlMessageType.sessionTeardown:
            guard let teardown = try? SessionTeardown.decode(bytes) else {
                noteMalformed("session teardown")
                return
            }
            applyMachine(.teardownMessage(teardown.reason), now: now)

        case CtrlMessageType.capabilityDeclaration:
            receiveDeclaration(bytes, now: now)

        case CtrlMessageType.capabilityUpdate:
            receiveUpdate(bytes, now: now)

        case CtrlMessageType.idleFrame:
            receiveIdleFrame(bytes)

        case CtrlMessageType.inputEcho:
            guard let echo = try? InputEcho.decode(bytes) else {
                noteMalformed("input echo")
                return
            }
            lock.lock()
            counters.inputEchoMessagesReceived += 1
            lock.unlock()
            input.handleEcho(echo, now: now)

        case CtrlMessageType.audioRoutingStatus:
            receiveAudioRoutingStatus(bytes, now: now)

        case CtrlMessageType.audioTrackState:
            receiveAudioTrackState(bytes, now: now)

        case CtrlMessageType.videoPostureState:
            receiveVideoPostureState(bytes)

        case CtrlMessageType.audioRoutingRequest:
            // Role confusion: 0x18 is client→host only. The host's
            // mirror drops a client-bound 0x19 the same way — loud.
            lock.lock()
            counters.audioRoutingDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(
                "audio-routing 0x18 arrived AT the client "
                + "(role confusion) — dropped"))

        case CtrlMessageType.clipboardAnnounce:
            receiveClipboardAnnounce(bytes)

        case CtrlMessageType.cursorShape:
            receiveCursorShape(bytes)

        case CtrlMessageType.clipboardSet:
            // Role confusion: 0x1A is client→host only (the host's
            // 0x1B-at-host mirror). Loud, payload never logged.
            lock.lock()
            counters.clipboardDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(
                "clipboard 0x1A arrived AT the client "
                + "(role confusion) — dropped"))

        default:
            lock.lock()
            counters.unknownReliableTypes += 1
            lock.unlock()
            onEvent(.protocolNote(
                "unregistered reliable CTRL type "
                    + Hex.string(bytes.first ?? 0, width: 2, prefix: true)
                    + " (\(bytes.count) B)"))
        }
    }

    /// Every chan-8 ARQ delivery: the stream now carries TWO lanes.
    /// A 0x22 marker or any bulk message the image channel claims is
    /// the clipboard lane's (P-1); the rest is the file lane's (F-4),
    /// decoded and surfaced for the owner's BulkSendCoordinator. Each
    /// lane wears its OWN rule-3 gate — a file message without key 11
    /// drops loud even when images agreed, and vice versa (the tiers
    /// do not couple); bytes the codecs refuse drop loud too, payload
    /// never logged.
    private func dispatchBulk(_ event: ArqEvent) {
        guard case .message(_, let bytes) = event else { return }
        let now = now()
        if bytes.first == CtrlMessageType.clipboardImageCargo {
            receiveImageCargo(bytes, now: now)
            return
        }
        guard let message = try? BulkMessage.decode(bytes) else {
            lock.lock()
            counters.bulkDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(
                "malformed bulk message dropped (type "
                    + Hex.string(bytes.first ?? 0, width: 2, prefix: true)
                    + ", \(bytes.count) B)"))
            return
        }
        lock.lock()
        if imageChannel.claims(message) {
            let events = imageChannel.ingest(
                message, book: &clipboardBook, sha256: Sha256.digest
            )
            lock.unlock()
            processImageEvents(events, now: now)
            return
        }
        guard negotiator.agreed?.bulkTransfer == true else {
            counters.bulkDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(
                "bulk message without negotiated key 11 — dropped"))
            return
        }
        counters.bulkMessagesReceived += 1
        lock.unlock()
        onEvent(.bulkMessageReceived(message))
    }

    /// One 0x22 clipboard-image marker (P-1): gate (keys 10∧12), then
    /// tier — a welcome marker arms the channel's receive lane for the
    /// offer riding behind it; an unwelcome one draws abort(declined)
    /// through the channel so the trailing offer is swallowed rather
    /// than leaking to the file lane.
    private func receiveImageCargo(
        _ bytes: [UInt8], now: ClientTimestamp
    ) {
        guard let cargo = try? ClipboardImageCargo.decode(bytes) else {
            lock.lock()
            counters.clipboardDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(String(
                format: "malformed clipboard-image marker dropped (%d B)",
                bytes.count)))
            return
        }
        lock.lock()
        guard negotiator.agreed?.clipboardImagesAgreed == true else {
            counters.clipboardDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(
                "clipboard-image 0x22 without negotiated keys 10∧12 "
                    + "— dropped"))
            return
        }
        let events: [ClipboardImageEvent]
        if clipboardSharingOn && clipboardImagesOn {
            events = imageChannel.ingestCargo(cargo)
        } else {
            // Text's off-posture is silent deafness; the image sender
            // waits on a verdict, so off answers typed instead.
            events = imageChannel.declineCargo(cargo)
        }
        lock.unlock()
        processImageEvents(events, now: now)
    }

    /// The host's declaration: intersection = agreement. An unworkable
    /// intersection (no common codec/chroma) draws the typed teardown —
    /// the host-side rule (HS-11), mirrored.
    private func receiveDeclaration(
        _ bytes: [UInt8], now: ClientTimestamp
    ) {
        guard let declaration = try? CapabilityDeclaration.decode(bytes)
        else {
            noteMalformed("capability declaration")
            return
        }
        lock.lock()
        do {
            let event = try negotiator.receive(declaration)
            if case .agreed(let intersection) = event {
                lock.unlock()
                onEvent(.capabilitiesAgreed(intersection))
                return
            }
            lock.unlock()
        } catch let failure as CapabilityNegotiationError
            where failure == .noCommonVideoCodec
                || failure == .noCommonChromaMode {
            lock.unlock()
            onEvent(.capabilitiesFailed(failure))
            beginTeardown(reason: .shuttingDown, now: now)
        } catch {
            lock.unlock()
            onEvent(.protocolNote(
                "capability declaration refused: \(error)"))
        }
    }

    /// A host renegotiation proposal (v1: maxDatagramBytes only). The
    /// negotiator judges it; the ack echoes the proposal verbatim.
    private func receiveUpdate(_ bytes: [UInt8], now: ClientTimestamp) {
        guard let update = try? CapabilityUpdate.decode(bytes) else {
            noteMalformed("capability update")
            return
        }
        lock.lock()
        let event: CapabilityEvent?
        do {
            event = try negotiator.receive(update)
        } catch {
            lock.unlock()
            onEvent(.protocolNote("capability update refused: \(error)"))
            return
        }
        counters.capabilityUpdatesAnswered += 1
        lock.unlock()
        guard case .answerUpdate(let ack) = event else { return }
        do {
            try reliable.send(try ack.encode(), now: now)
            onEvent(.capabilityUpdateAnswered(
                accepted: ack.status == .accepted))
        } catch {
            onEvent(.protocolNote("update ack send refused: \(error)"))
        }
    }

    /// The 0x15 idle frame: decode, render through the shared factory
    /// (dedupe against the datagram path inside the pipeline). The
    /// one-shot ACK the host's IDLE flip waits on already left in the
    /// ingest pass that delivered this message.
    private func receiveIdleFrame(_ bytes: [UInt8]) {
        guard let idle = try? IdleFrame.decode(bytes) else {
            noteMalformed("idle frame")
            return
        }
        lock.lock()
        counters.idleFramesReceived += 1
        lock.unlock()
        let outcome = pipeline.ingestReliableFrame(
            frame: idle.frame,
            captureTimestampMicroseconds: idle.captureTimestampMicroseconds,
            annexB: idle.annexB
        )
        onEvent(.idleFrameReceived(
            frame: idle.frame.rawValue, outcome: outcome))
    }

    /// The 0x19 applied-posture status (CL-13). Gated on the agreed
    /// set (a status from a host that never negotiated key 9 is a
    /// protocol break — dropped loud, the host's rule-3 gate
    /// mirrored); a legitimate one updates the confirmed posture and
    /// surfaces. The FIRST status is also the session-start seam: it
    /// is the host's own default, so if the configured desired posture
    /// differs, exactly one 0x18 leaves here.
    private func receiveAudioRoutingStatus(
        _ bytes: [UInt8], now: ClientTimestamp
    ) {
        guard let status = try? AudioRoutingStatus.decode(bytes) else {
            noteMalformed("audio-routing status")
            return
        }
        lock.lock()
        guard negotiator.agreed?.hostAudioRouting == true else {
            counters.audioRoutingDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(
                "audio-routing 0x19 without negotiated key 9 — dropped"))
            return
        }
        counters.audioRoutingStatusesReceived += 1
        hostAudioPosture = status.mode
        let firstStatus = !sessionStartAudioAskDone
        sessionStartAudioAskDone = true
        let desired = config.desiredHostAudioRouting
        lock.unlock()
        onEvent(.hostAudioRoutingStatus(status.mode))
        if firstStatus, let desired, desired != status.mode {
            do {
                try requestHostAudioRouting(desired, now: now)
                onEvent(.protocolNote(
                    "session-start posture: asked host for \(desired) "
                    + "(host default \(status.mode))"))
            } catch {
                onEvent(.protocolNote(
                    "session-start posture ask refused: \(error)"))
            }
        }
    }

    /// The 0x1B announce (CL-15). Gated on the agreed set (an
    /// announce from a host that never negotiated key 10 is a
    /// protocol break — dropped loud, the rule-3 gate mirrored) AND
    /// on the session toggle (consent: while sharing is off, host
    /// clipboard content must not land on the pasteboard — counted,
    /// ignored, no event). A legitimate one pre-arms the sync book
    /// against its own changeCount echo, then surfaces for the glue
    /// to apply.
    private func receiveClipboardAnnounce(_ bytes: [UInt8]) {
        guard let announce = try? ClipboardAnnounce.decode(bytes) else {
            noteMalformed("clipboard announce")
            return
        }
        lock.lock()
        guard negotiator.agreed?.clipboardText == true else {
            counters.clipboardDropsLoud += 1
            lock.unlock()
            onEvent(.protocolNote(
                "clipboard 0x1B without negotiated key 10 — dropped"))
            return
        }
        guard clipboardSharingOn else {
            counters.clipboardIgnoredDisabled += 1
            lock.unlock()
            onEvent(.protocolNote(
                "clipboard 0x1B while sharing is off — ignored "
                + "(\(announce.text.utf8.count) B never applied)"))
            return
        }
        counters.clipboardAnnouncesReceived += 1
        clipboardBook.noteRemoteApplied(announce.text)
        lock.unlock()
        onEvent(.hostClipboardChanged(announce.text))
    }

    private func receiveCursorShape(_ bytes: [UInt8]) {
        guard let shape = try? CursorShape.decode(bytes) else {
            noteMalformed("cursor shape")
            return
        }
        lock.lock()
        guard negotiator.agreed?.cursorShape == true else {
            counters.unknownReliableTypes += 1
            lock.unlock()
            onEvent(.protocolNote(
                "cursor 0x24 without negotiated key 13 — dropped"))
            return
        }
        counters.cursorShapesReceived += 1
        lock.unlock()
        onEvent(.hostCursorShapeChanged(shape))
    }

    private func noteMalformed(_ what: String) {
        lock.lock()
        counters.malformedReliableMessages += 1
        lock.unlock()
        onEvent(.protocolNote("malformed \(what) dropped"))
    }
}

// MARK: - The production shell

public final class LyteUdpSession: @unchecked Sendable {
    public struct Config: Sendable {
        /// The local bind (0 = kernel-assigned; wire-view binds its
        /// argued port for tcpdump-friendly runs).
        public var bindPort: UInt16 = 0
        public var bindAddress: String = "0.0.0.0"
        public var core = LyteUdpSessionCoreConfig()
        /// How long `close()` waits for the teardown segment's ACK
        /// before tearing the socket down anyway.
        public var teardownLingerMilliseconds = 500
        /// CL-11: decode + play the audio channel (AVAudioEngine).
        /// Default on — audio just plays; the receiver's stats exist
        /// either way. wire-view surfaces this as --audio.
        public var audioPlayback = true

        public init() {}
    }

    /// The crypto seam, prepared by the caller: NoiseTransportCrypto
    /// (persistent identity for the app's paired path, throwaway for
    /// the --host-key debug posture) or InsecureTransportCrypto for
    /// the recorded CP-3 fallback.
    public let crypto: any TransportCrypto
    public let config: Config
    public private(set) var endpoint: UdpReceiveEndpoint?
    private let coreStorage = Mutex<LyteUdpSessionCore?>(nil)
    public var core: LyteUdpSessionCore? {
        coreStorage.withLock { $0 }
    }
    /// The CL-11 playback unit, present when `config.audioPlayback`
    /// and the audio device came up.
    public private(set) var audioPlayer: LyteAudioPlayer?

    private let videoSink: any VideoSink
    private let onEvent: @Sendable (LyteUdpSessionEvent) -> Void
    private let onVideoRecoveryDemand:
        @Sendable (VideoRecoveryCause, FrameNumber) -> Void
    private let onVideoRecoveryTrace:
        @Sendable (VideoRecoveryTraceEvent) -> Void
    private let closing = Atomic<Bool>(false)
    public let clockModel: HostClockModel
    /// CoreAudio engine start/stop runs HERE, never on the caller's
    /// thread: AVAudioEngine.start() can block on HAL/device
    /// arbitration (found live — wire-view's @MainActor run() wedged
    /// inside session.start() before NSApplication owned the run
    /// loop). One serial queue keeps start/stop ordered.
    private let audioQueue = DispatchQueue(
        label: "lyte.audio.engine", qos: .userInitiated)
    private lazy var orderedInput = OrderedInputSender { [weak self] body, now in
        guard let self, let core = self.core else {
            throw TransportEndpointError.notStarted
        }
        _ = try core.sendInput(body, now: now)
    }

    public init(
        crypto: any TransportCrypto,
        config: Config = Config(),
        clockModel: HostClockModel = HostClockModel(),
        onVideoRecoveryDemand: @escaping @Sendable (
            VideoRecoveryCause, FrameNumber
        ) -> Void = { _, _ in },
        onVideoRecoveryTrace: @escaping @Sendable (
            VideoRecoveryTraceEvent
        ) -> Void = { _ in },
        videoSink: any VideoSink,
        onEvent: @escaping @Sendable (LyteUdpSessionEvent) -> Void
    ) {
        self.crypto = crypto
        self.config = config
        self.clockModel = clockModel
        self.onVideoRecoveryDemand = onVideoRecoveryDemand
        self.onVideoRecoveryTrace = onVideoRecoveryTrace
        self.videoSink = videoSink
        self.onEvent = onEvent
    }

    /// Bind → Noise handshake (blocking, retry timer inside; answers a
    /// W8 retry challenge with the verbatim msg1) → receive thread →
    /// capability declaration as the first reliable word → timers.
    /// Throws TransportCryptoError / TransportEndpointError on a dial
    /// that never became a session.
    public func start() throws {
        let endpoint = UdpReceiveEndpoint(
            port: config.bindPort,
            bindAddress: config.bindAddress,
            crypto: crypto,
            onDatagram: { [weak self] outcome, arrivalMicroseconds in
                self?.core?.handleDatagram(
                    outcome, arrivalMicroseconds: arrivalMicroseconds)
            })
        try endpoint.start()
        self.endpoint = endpoint

        let sender = TransportSender(crypto: crypto, transmit: {
            [weak endpoint] datagram in
            endpoint?.sendToPeer(datagram) ?? false
        })
        let core = LyteUdpSessionCore(
            demux: endpoint.demux,
            sender: sender,
            config: config.core,
            clockModel: clockModel,
            asynchronousVideoBuild: true,
            onVideoRecoveryDemand: onVideoRecoveryDemand,
            onVideoRecoveryTrace: onVideoRecoveryTrace,
            videoSink: videoSink,
            onEvent: onEvent
        )
        coreStorage.withLock { $0 = core }
        try core.open()
        core.startTimers()

        // Audio out (CL-11): a refused device is weather, never fatal —
        // the screen must stream even when audio cannot (the host's
        // rule, mirrored). Construction is cheap and synchronous; the
        // engine spin-up goes to the audio queue (see its comment).
        if config.audioPlayback {
            do {
                let player = try LyteAudioPlayer(receiver: core.audio)
                audioPlayer = player
                let onEvent = onEvent
                audioQueue.async {
                    do {
                        try player.start()
                    } catch {
                        onEvent(.protocolNote(
                            "audio playback unavailable (\(error)) — video-only"))
                    }
                }
            } catch {
                onEvent(.protocolNote(
                    "audio playback unavailable (\(error)) — video-only"))
            }
        }
    }

    /// The stream window's mute toggle (CL-11): playback keeps
    /// consuming (buffer discipline unaffected); only the mixer goes
    /// quiet.
    public func setAudioMuted(_ muted: Bool) {
        audioPlayer?.muted = muted
    }

    /// The strip's host-mute override (CL-13): asks the host to flip
    /// its OWN speakers. Throws `AudioRoutingAskError.notNegotiated`
    /// when key 9 never survived intersection — the button gating
    /// means the app never hits that; wire-view's flag can.
    public func requestHostAudioRouting(_ mode: HostAudioRoutingMode) throws {
        guard let core else { throw TransportEndpointError.notStarted }
        try core.requestHostAudioRouting(mode)
    }

    /// True when key 9 survived intersection (CL-13).
    public var hostAudioRoutingNegotiated: Bool {
        core?.hostAudioRoutingNegotiated ?? false
    }

    /// The 0x19-confirmed host-speaker posture, nil before the first
    /// status (CL-13).
    public var hostAudioRoutingPosture: HostAudioRoutingMode? {
        core?.hostAudioRoutingPosture
    }

    /// True when key 10 survived intersection (CL-15) — the strip's
    /// clipboard toggle exists exactly when this is true.
    public var clipboardNegotiated: Bool {
        core?.clipboardNegotiated ?? false
    }

    /// True when key 11 survived intersection (F-4) — the host's
    /// standing consent toggle is on; the drop target offers exactly
    /// when this is true.
    public var bulkTransferNegotiated: Bool {
        core?.bulkTransferNegotiated ?? false
    }

    /// The BulkSendCoordinator's chan-8 send leg (F-4). Throws
    /// `BulkChannelError.notNegotiated` against a key-11-less host —
    /// the coordinator's own gate means the app never hits that.
    public func sendBulkMessage(_ message: [UInt8]) throws {
        guard let core else { throw TransportEndpointError.notStarted }
        try core.sendBulkMessage(message)
    }

    /// The live clipboard-sharing toggle (CL-15).
    public var clipboardSharingEnabled: Bool {
        core?.clipboardSharingEnabled ?? false
    }

    public func setClipboardSharing(_ enabled: Bool) {
        core?.setClipboardSharing(enabled)
    }

    /// The pasteboard watcher's funnel (CL-15): one local clipboard
    /// change through the core's gates. Safe before start (`.sendRefused`).
    @discardableResult
    public func shareLocalClipboard(_ text: String) -> ClipboardShareOutcome {
        core?.shareLocalClipboard(text) ?? .sendRefused("not started")
    }

    /// P-1: true when keys 10∧12 both survived intersection — the
    /// images rung of the consent tier exists exactly when this is.
    public var clipboardImagesNegotiated: Bool {
        core?.clipboardImagesNegotiated ?? false
    }

    /// The images rung's live state (sharing on AND images on).
    public var clipboardImageSharingEnabled: Bool {
        core?.clipboardImageSharingEnabled ?? false
    }

    public func setClipboardImageSharing(_ enabled: Bool) {
        core?.setClipboardImageSharing(enabled)
    }

    /// The pasteboard watcher's image funnel (P-1): one local image
    /// copy (PNG bytes) through the core's gates. Safe before start.
    @discardableResult
    public func shareLocalClipboardImage(
        _ data: [UInt8]
    ) -> ClipboardShareOutcome {
        core?.shareLocalClipboardImage(data)
            ?? .sendRefused("not started")
    }

    /// Orderly close: the typed 0x0A on the ordered stream, a linger
    /// for its ACK (≤ the configured window), then teardown. Blocking —
    /// call off the main thread.
    public func close(reason: SessionTeardownReason = .shuttingDown) {
        guard !closing.exchange(true, ordering: .relaxed) else { return }
        orderedInput.finishAndDrain()
        if let core {
            core.beginTeardown(reason: reason)
            let deadline = SystemMonotonicClock.nowNanoseconds
                + UInt64(config.teardownLingerMilliseconds) * 1_000_000
            while !core.isReliableQuiescent,
                  SystemMonotonicClock.nowNanoseconds < deadline
            {
                usleep(20_000)
            }
        }
        stopParts()
    }

    /// The shell's input leg (CL-9): captured events straight onto the
    /// reliable stream. A refused send (teardown races, mostly) is the
    /// caller's weather — count it, never crash the capture monitor.
    @discardableResult
    public func sendInput(_ body: InputEvent.Body) throws -> UInt32 {
        guard let core else { throw TransportEndpointError.notStarted }
        return try core.sendInput(body)
    }

    /// Renderer-side broken-reference seam. It joins the same coalescing
    /// episode as FEC/repair failures: one immediate 0x10, slow retries,
    /// and no second episode until a usable IRAP reaches the pipeline.
    public func requestVideoRecovery(
        after frame: FrameNumber,
        cause: VideoRecoveryCause = .rendererFailure
    ) {
        core?.requestVideoRecovery(after: frame, cause: cause)
    }

    public func noteVideoIrapEnqueued(
        frame: FrameNumber = FrameNumber(rawValue: 0)
    ) {
        core?.noteVideoIrapEnqueued(frame: frame)
    }

    /// Production UI funnel: capture returns immediately; one dedicated
    /// serial sender preserves event order while ARQ, sealing, and sendto
    /// execute away from MainActor. Jobs observe `closing` before touching
    /// session state, so teardown cannot resurrect a dead sender.
    public func enqueueInput(_ body: InputEvent.Body) {
        orderedInput.enqueue(body)
    }

    public var inputSendTimingSnapshot: InputSendTiming.Snapshot {
        orderedInput.snapshot
    }

    /// Hard stop, no wire goodbye — the path after a peer teardown or
    /// liveness close (the machine is already closed; there is nothing
    /// to say and possibly nobody to say it to).
    public func stop() {
        guard !closing.exchange(true, ordering: .relaxed) else { return }
        stopParts()
    }

    private func stopParts() {
        orderedInput.stop()
        if let player = audioPlayer {
            audioPlayer = nil
            // Serialized behind the async start; never blocks teardown.
            audioQueue.async { player.stop() }
        }
        core?.stopTimers()
        endpoint?.stop()
    }
}
