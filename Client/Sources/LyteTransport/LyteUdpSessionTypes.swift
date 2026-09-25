// The public vocabulary of the client session: the events it surfaces,
// its counters, and the core's configuration.

import LyteClientCore
import LyteClientSession
import LyteWire

/// The IO-free session's error, re-exported for LyteTransport callers.
public typealias AudioRoutingAskError = LyteClientSession.AudioRoutingAskError

// MARK: - Bulk channel

/// A bulk send without key 11 in the agreed set is refused before a byte
/// leaves.
public enum BulkChannelError: Error, Equatable, Sendable {
    case notNegotiated
}

/// The IO-free session's share verdict, re-exported for LyteTransport
/// callers.
public typealias ClipboardShareOutcome =
    LyteClientSession.ClipboardShareOutcome

// MARK: - Events

/// Everything the session surfaces to its owner. Fired from receive/timer
/// threads; UI owners hop to the main actor themselves.
public enum LyteUdpSessionEvent: Sendable {
    /// The capability exchange settled: this is the session's agreed set.
    case capabilitiesAgreed(Capabilities)
    /// The intersection was unworkable; the typed teardown followed
    /// automatically. The app's chroma fallback keys on
    /// `.noCommonChromaMode`.
    case capabilitiesFailed(CapabilityNegotiationError)
    /// A host renegotiation proposal (0x11) was answered (0x12).
    case capabilityUpdateAnswered(accepted: Bool)
    /// The wire mode changed.
    case modeChanged(SessionWireMode)
    /// The lifecycle state changed — `frozen` is the path-dark pill.
    /// Edges arrive in decision order.
    case stateChanged(SessionState)
    /// A reliable idle frame (0x15) arrived, with what became of it.
    case idleFrameReceived(frame: UInt32, outcome: ReliableFrameOutcome)
    /// A 0x19 status: where the host's speakers actually stand. Fires on
    /// every status, changed or not, so the UI can settle a pending toggle.
    case hostAudioRoutingStatus(HostAudioRoutingMode)
    /// A 0x1B announce passed every gate; the owner applies `text` to the
    /// pasteboard (the sync book is already armed against its echo). Never
    /// fires while sharing is off.
    case hostClipboardChanged(String)
    /// A 0x24 cursor shape (key 13): the video carries no cursor, so the
    /// owner wears this as the local cursor. `.hidden` means hidden.
    case hostCursorShapeChanged(CursorShape)
    /// A digest-verified host clipboard image passed every gate; the
    /// owner applies `data` (PNG) to the pasteboard (the sync book is
    /// already armed against its echo). Never fires while the rung is off.
    case hostClipboardImageChanged(data: [UInt8], mime: String)
    /// One decoded chan-8 file-lane message for the BulkSendCoordinator.
    case bulkMessageReceived(BulkMessage)
    /// Our typed teardown left on the ordered stream.
    case teardownSent(SessionTeardownReason)
    /// The host broke an ordered stream (CTRL or chan 8) with a message
    /// over the shared ceiling; the session is ending with a typed
    /// teardown because nothing on that stream can arrive in order again.
    /// Fires once per session, before its `closed`.
    case orderedStreamPoisoned
    /// The session reached `closed` — peer teardown, local teardown,
    /// or the 30 s liveness timeout. The owner stops the session.
    case closed(SessionCloseReason)
    /// Protocol weather worth a log line, never fatal.
    case protocolNote(String)
}

/// What opened a video recovery episode (telemetry only; not wire).
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
    /// 0x17 echo messages consumed.
    public var inputEchoMessagesReceived: UInt64 = 0
    /// 0x03 path challenges answered with their 0x04 echo.
    public var pathChallengesAnswered: UInt64 = 0
    /// Chan-1 datagrams routed to the audio receiver.
    public var audioDatagramsReceived: UInt64 = 0
    /// 0x18 flip requests sent, the session-start ask included.
    public var audioRoutingRequestsSent: UInt64 = 0
    /// 0x19 applied-posture statuses consumed.
    public var audioRoutingStatusesReceived: UInt64 = 0
    /// 0x25 audio track-state announcements received.
    public var audioTrackStatesReceived: UInt64 = 0
    /// 0x26 video posture announcements received.
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
    /// Announces that arrived while sharing was off (never applied).
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
    /// What this client declares (0x0F): the wire default plus every
    /// optional key it speaks. Declaration is dialect, not consent: the
    /// intersection and the live consent toggles decide what moves.
    public var capabilities: Capabilities
    /// Blackout threshold once authenticated audio arrives (a dense path
    /// probe). Evidence-gated: a host without audio never tightens. Nil
    /// disables tightening.
    public var tightenedBlackoutSilenceMicroseconds: Int64?
    public var audioJitter: AudioJitterConfig
    public var nackPolicy: NackPolicyConfig
    /// The session-start host-speaker posture: with key 9 agreed, one
    /// 0x18 leaves if the host's first 0x19 differs (once per session).
    /// Nil takes the host's default.
    public var desiredHostAudioRouting: HostAudioRoutingMode?
    /// Starting clipboard-sharing consent (default off: clipboards carry
    /// passwords).
    public var shareClipboard: Bool
    /// The images rung; images move only when this and `shareClipboard`
    /// are both on.
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
        tightenedBlackoutSilenceMicroseconds: Int64? =
            ClientControlSession.tightenedBlackoutSilenceMicroseconds,
        audioJitter: AudioJitterConfig = AudioJitterConfig(),
        nackPolicy: NackPolicyConfig = NackPolicyConfig(),
        desiredHostAudioRouting: HostAudioRoutingMode? = .hostMuted,
        shareClipboard: Bool = false,
        shareClipboardImages: Bool = false
    ) {
        self.capabilities = capabilities
        self.tightenedBlackoutSilenceMicroseconds =
            tightenedBlackoutSilenceMicroseconds
        self.audioJitter = audioJitter
        self.nackPolicy = nackPolicy
        self.desiredHostAudioRouting = desiredHostAudioRouting
        self.shareClipboard = shareClipboard
        self.shareClipboardImages = shareClipboardImages
    }
}
