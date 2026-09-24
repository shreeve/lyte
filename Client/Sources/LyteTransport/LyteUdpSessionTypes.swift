// The public vocabulary of the client session: the events it surfaces,
// its counters, and the core's configuration.

import LyteClientCore
import LyteClientSession
import LyteWire

/// The IO-free session's error, re-exported for LyteTransport callers.
public typealias AudioRoutingAskError = LyteClientSession.AudioRoutingAskError

// MARK: - Bulk channel

/// A bulk send without key 11 in the agreed set is refused before a byte
/// leaves: the client offers only into an agreed set, and the host's
/// standing consent toggle decides whether it declares the key.
public enum BulkChannelError: Error, Equatable, Sendable {
    case notNegotiated
}

/// The IO-free session's share verdict, re-exported for LyteTransport
/// callers.
public typealias ClipboardShareOutcome =
    LyteClientSession.ClipboardShareOutcome

// MARK: - Events

/// Everything the session surfaces to its owner (the CLI's printer,
/// the app's ConnectionModel). Fired from receive/timer threads —
/// UI owners hop to the main actor themselves.
public enum LyteUdpSessionEvent: Sendable {
    /// The capability exchange settled: this is the session's agreed set.
    case capabilitiesAgreed(Capabilities)
    /// The peer's declaration produced an unworkable intersection; the
    /// typed teardown followed automatically. The app's chroma fallback
    /// keys on `.noCommonChromaMode` (a Best declaration against a
    /// 4:2:0-only host re-dials at Good).
    case capabilitiesFailed(CapabilityNegotiationError)
    /// A host renegotiation proposal (0x11) was answered (0x12).
    case capabilityUpdateAnswered(accepted: Bool)
    /// The wire mode changed (a delivered ModeTransition, or RECOVERY
    /// re-entry semantics on the host's side reflected here).
    case modeChanged(SessionWireMode)
    /// The lifecycle state changed — `frozen` is the path-dark pill.
    /// Edges arrive in decision order.
    case stateChanged(SessionState)
    /// A reliable idle frame (0x15) arrived, with what became of it.
    case idleFrameReceived(frame: UInt32, outcome: ReliableFrameOutcome)
    /// A 0x19 applied-posture status arrived: where the host's own
    /// speakers actually stand. The host sends one at capability
    /// agreement and after every flip attempt (a failed flip reports the
    /// old posture). Fires on every status, changed or not, so the UI can
    /// settle a pending toggle either way.
    case hostAudioRoutingStatus(HostAudioRoutingMode)
    /// A 0x1B clipboard announce passed every gate (negotiated, sharing
    /// on); the owner applies `text` to the pasteboard. The sync book is
    /// already armed against the apply's echo. Never fires while sharing
    /// is off: content must not land on the pasteboard without consent.
    case hostClipboardChanged(String)
    /// A 0x24 cursor shape arrived with key 13 agreed: the host's video
    /// carries no cursor, so the owner wears this image as the local
    /// cursor over the video view. `.hidden` (zero-sized) means the host
    /// cursor is hidden. No consent toggle: a cursor shape is
    /// presentation state, not content.
    case hostCursorShapeChanged(CursorShape)
    /// A host clipboard image landed digest-verified off the chan-8
    /// clipboard lane and passed every gate (keys 10 and 12 agreed,
    /// sharing and the images rung on); the owner applies `data` (PNG) to
    /// the pasteboard. The sync book is already armed against the apply's
    /// echo. Never fires while the rung is off: an unwelcome marker draws
    /// abort(declined) instead, because the sender waits on a verdict.
    case hostClipboardImageChanged(data: [UInt8], mime: String)
    /// One decoded chan-8 file-lane message (accept/ack/complete/abort
    /// answers for the client's sending role), key 11 agreed; the owner
    /// feeds it to its BulkSendCoordinator.
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

/// The session core's dispatch counters; each part keeps its own
/// detailed stats.
public struct LyteUdpSessionCounters: Sendable {
    public var modeTransitionsReceived: UInt64 = 0
    public var idleFramesReceived: UInt64 = 0
    public var capabilityUpdatesAnswered: UInt64 = 0
    public var unknownReliableTypes: UInt64 = 0
    public var malformedReliableMessages: UInt64 = 0
    /// 0x17 echo messages consumed (tuple-level books live on
    /// `InputSender`'s stats).
    public var inputEchoMessagesReceived: UInt64 = 0
    /// Chan-1 datagrams routed to the audio receiver.
    public var audioDatagramsReceived: UInt64 = 0
    /// 0x18 flip requests this end put on the ordered stream, the
    /// session-start posture ask included.
    public var audioRoutingRequestsSent: UInt64 = 0
    /// 0x19 applied-posture statuses consumed.
    public var audioRoutingStatusesReceived: UInt64 = 0
    /// 0x25 audio track-state announcements received (gate closes,
    /// still-quiet check-ins, and wakes all count here).
    public var audioTrackStatesReceived: UInt64 = 0
    /// 0x26 video posture announcements received (ladder steps and
    /// wakes).
    public var videoPostureStatesReceived: UInt64 = 0
    /// Loud audio-routing drops: an unnegotiated 0x19, or a
    /// role-confused 0x18 arriving at the client.
    public var audioRoutingDropsLoud: UInt64 = 0
    /// 0x1A clipboard sets this end put on the ordered stream.
    public var clipboardSharesSent: UInt64 = 0
    /// 0x1B announces consumed and applied.
    public var clipboardAnnouncesReceived: UInt64 = 0
    /// 0x24 cursor shapes consumed and worn.
    public var cursorShapesReceived: UInt64 = 0
    /// Local changes the sync book suppressed (echo or duplicate).
    public var clipboardLoopSuppressed: UInt64 = 0
    /// Announces that arrived while sharing was off — counted, never
    /// applied.
    public var clipboardIgnoredDisabled: UInt64 = 0
    /// Loud clipboard drops: an unnegotiated 0x1B or 0x22, or a
    /// role-confused 0x1A arriving at the client.
    public var clipboardDropsLoud: UInt64 = 0
    /// Bulk messages this end put on chan 8's ordered stream.
    public var bulkMessagesSent: UInt64 = 0
    /// Decoded chan-8 file-lane messages surfaced to the owner.
    public var bulkMessagesReceived: UInt64 = 0
    /// Loud bulk drops: a chan-8 message without negotiated key 11,
    /// or bytes the bulk codecs refused.
    public var bulkDropsLoud: UInt64 = 0
}

extension LyteUdpSessionCounters {
    mutating func bump(_ counter: ClientControlCounter) {
        switch counter {
        case .modeTransitionReceived: modeTransitionsReceived += 1
        case .capabilityUpdateAnswered: capabilityUpdatesAnswered += 1
        case .audioRoutingStatusReceived: audioRoutingStatusesReceived += 1
        case .audioRoutingRequestSent: audioRoutingRequestsSent += 1
        case .audioRoutingDropLoud: audioRoutingDropsLoud += 1
        case .clipboardAnnounceReceived: clipboardAnnouncesReceived += 1
        case .clipboardIgnoredDisabled: clipboardIgnoredDisabled += 1
        case .clipboardDropLoud: clipboardDropsLoud += 1
        case .cursorShapeReceived: cursorShapesReceived += 1
        case .unknownReliableType: unknownReliableTypes += 1
        case .audioTrackStateReceived: audioTrackStatesReceived += 1
        case .videoPostureStateReceived: videoPostureStatesReceived += 1
        case .malformedReliableMessage: malformedReliableMessages += 1
        }
    }
}

// MARK: - Config

public struct LyteUdpSessionCoreConfig: Sendable {
    /// What this client declares (0x0F). The default is the wire default
    /// (HEVC, 4:2:0, idle silence on, 1152 B ceiling) plus every optional
    /// capability key this client can speak: 9 host-audio routing, audio
    /// stream off, 10 clipboard text, 11 bulk transfer, 12 clipboard
    /// images, 13 cursor shape, 15 audio quiet posture, 16 video quiet
    /// posture. Declaration is dialect, not consent: whether a feature
    /// moves is decided by the host's declaration (the intersection) and
    /// by this end's live consent toggles.
    public var capabilities: Capabilities
    /// The receiver machine's timing. The default blackout is 2.5 s,
    /// past the 1 Hz beacon cadence of an idle host, where the only
    /// evidence is beacons and CTRL (see LyteUdpSessionCore).
    public var machineConfig: SessionMachineConfig
    /// Once an authenticated audio datagram arrives, the blackout
    /// detector re-arms at this threshold (the 5 ms audio stream is a
    /// dense path probe). Evidence-gated because no capability key
    /// announces audio: a host without audio never tightens. Nil disables
    /// tightening.
    public var tightenedBlackoutSilenceMicroseconds: Int64?
    /// The audio playout buffer's policy.
    public var audioJitter: AudioJitterConfig
    /// The targeted-repair ask policy.
    public var nackPolicy: NackPolicyConfig
    /// The session-start host-speaker posture. When set and key 9
    /// survived intersection, the host's first 0x19 (its starting
    /// posture, sent at agreement) is compared against this and one 0x18
    /// leaves if they differ — exactly once per session; the strip's
    /// toggle is the live override. Default `.hostMuted` (sound follows
    /// the viewer); nil takes the host's default without comment.
    public var desiredHostAudioRouting: HostAudioRoutingMode?
    /// The session's starting clipboard-sharing consent (default off:
    /// clipboards carry passwords). Toggled live by
    /// `setClipboardSharing`; while off nothing leaves and nothing lands.
    public var shareClipboard: Bool
    /// The images rung of the consent tier. Images move only when this
    /// and `shareClipboard` are both on; default off. An unwelcome
    /// inbound marker draws abort(declined) rather than silence, because
    /// the image sender waits on a verdict.
    public var shareClipboardImages: Bool

    public init(
        capabilities: Capabilities = .wireDefault
            .declaringHostAudioRouting().declaringAudioStreamOff()
            .declaringClipboardText()
            .declaringBulkTransfer()
            .declaringClipboardImages()
            .declaringCursorShape()
            .declaringAudioQuietPosture()
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
