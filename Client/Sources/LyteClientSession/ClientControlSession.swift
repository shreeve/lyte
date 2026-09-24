import LyteWire

/// The control edge a platform shell should surface after offering one
/// reliable word to the IO-free client session.
public enum ClientControlSessionEvent: Hashable, Sendable {
    case lifecycle(ClientLifecycleMessage)
    case malformedLifecycle(ClientLifecycleMessage)
    case capability(ClientCapabilitySessionEvent)
    case audioRouting(ClientAudioRoutingSessionEvent)
    case clipboard(ClientClipboardSessionEvent)
    case cursor(ClientCursorSessionEvent)
    case mediaPosture(ClientMediaPostureSessionEvent)
}

/// A blackout-detector threshold change, for the shell's log line.
public enum ClientDetectorPosture: Hashable, Sendable {
    /// Audio evidence arrived: the detector watches at this tighter bound.
    case tightened(blackoutSilenceMicroseconds: Int64)
    /// The host announced audio quiet: back to the baseline bound.
    case relaxed(blackoutSilenceMicroseconds: Int64)
}

/// One composed client-control decision. The shell sends the returned bytes,
/// projects the typed event, then executes any lifecycle actions.
public struct ClientControlSessionDecision: Hashable, Sendable {
    public let outboundReliable: [[UInt8]]
    public let event: ClientControlSessionEvent
    public let lifecycle: ClientSessionLifecycleDecision?
    public let detectorPosture: ClientDetectorPosture?

    public init(
        outboundReliable: [[UInt8]] = [],
        event: ClientControlSessionEvent,
        lifecycle: ClientSessionLifecycleDecision? = nil,
        detectorPosture: ClientDetectorPosture? = nil
    ) {
        self.outboundReliable = outboundReliable
        self.event = event
        self.lifecycle = lifecycle
        self.detectorPosture = detectorPosture
    }
}

/// The single IO-free control boundary shared by every client platform shell.
/// It composes capability and lifecycle organs so cross-organ consequences,
/// such as an unworkable capability set causing typed teardown, are decided
/// once rather than reimplemented by each platform.
///
/// Blackout detector posture: every authenticated host arrival is evidence
/// the host→client path moves. The baseline threshold sits past an idle
/// host's 1 Hz beacons; the first audio datagram (a dense path probe)
/// re-arms it at the tightened bound, and an announced audio quiet relaxes
/// it until audio resumes. A host without audio never tightens.
public struct ClientControlSession: Sendable {
    private let machineConfig: SessionMachineConfig
    private let tightenedBlackoutSilenceMicroseconds: Int64?
    public private(set) var detectorTightened = false
    private var lifecycle: ClientSessionLifecycle
    private var capabilities: ClientCapabilitySession
    private var audioRouting: ClientAudioRoutingSession
    private var clipboard: ClientClipboardSession
    private var cursor: ClientCursorSession
    private var mediaPosture: ClientMediaPostureSession

    public init(
        localCapabilities: Capabilities,
        machineConfig: SessionMachineConfig,
        desiredHostAudioRouting: HostAudioRoutingMode?,
        clipboardSharingAtStart: Bool = false,
        clipboardImageSharingAtStart: Bool = false,
        tightenedBlackoutSilenceMicroseconds: Int64? = nil,
        now: ClientTimestamp
    ) {
        self.machineConfig = machineConfig
        self.tightenedBlackoutSilenceMicroseconds =
            tightenedBlackoutSilenceMicroseconds
        lifecycle = ClientSessionLifecycle(config: machineConfig, now: now)
        capabilities = ClientCapabilitySession(local: localCapabilities)
        audioRouting = ClientAudioRoutingSession(
            desiredAtStart: desiredHostAudioRouting)
        clipboard = ClientClipboardSession(
            textSharingAtStart: clipboardSharingAtStart,
            imageSharingAtStart: clipboardImageSharingAtStart)
        cursor = ClientCursorSession()
        mediaPosture = ClientMediaPostureSession()
    }

    public var state: SessionState { lifecycle.state }
    public var wireMode: SessionWireMode { lifecycle.wireMode }
    public var agreedCapabilities: Capabilities? { capabilities.agreed }
    public var hostAudioRoutingPosture: HostAudioRoutingMode? {
        audioRouting.posture
    }
    public var hostAudioRoutingNegotiated: Bool {
        capabilities.agreed?.hostAudioRouting == true
    }
    public var clipboardNegotiated: Bool {
        capabilities.agreed?.clipboardText == true
    }
    public var clipboardSharingEnabled: Bool {
        clipboard.isTextSharingEnabled
    }
    public var clipboardImagesNegotiated: Bool {
        capabilities.agreed?.clipboardImagesAgreed == true
    }
    public var clipboardImageSharingEnabled: Bool {
        clipboard.isImageSharingEnabled
    }
    public var clipboardImageCounters: ClipboardImageChannelCounters {
        clipboard.imageCounters
    }
    public var cursorNegotiated: Bool {
        capabilities.agreed?.cursorShape == true
    }
    public var hostAnnouncedAudioQuiet: Bool {
        mediaPosture.hostAnnouncedAudioQuiet
    }
    public var announcedVideoPosture: VideoPostureState? {
        mediaPosture.announcedVideoPosture
    }
    public var operativeMaxDatagramBytes: UInt32 {
        capabilities.operativeMaxDatagramBytes
    }

    /// Returns the client's declaration exactly once for the shell to send as
    /// its first post-establishment reliable word.
    /// - Throws: `CapabilityMessageError` when the local capabilities do
    ///   not encode.
    public mutating func start() throws -> [UInt8]? {
        try capabilities.start()
    }

    /// - Throws: `AudioRoutingAskError` without negotiated key 9 or before
    ///   the capability exchange settled.
    public func requestHostAudioRouting(
        _ mode: HostAudioRoutingMode
    ) throws -> [UInt8] {
        try audioRouting.request(mode, agreed: capabilities.agreed)
    }

    public mutating func setClipboardSharing(_ enabled: Bool) {
        clipboard.setTextSharing(enabled)
    }

    public mutating func setClipboardImageSharing(_ enabled: Bool) {
        clipboard.setImageSharing(enabled)
    }

    public mutating func shareLocalClipboard(
        _ text: String
    ) -> ClientClipboardSessionDecision {
        clipboard.shareLocalText(text, agreed: capabilities.agreed)
    }

    public mutating func noteLocalClipboardSent(_ text: String) {
        clipboard.noteLocalTextSent(text)
    }

    /// The digest-free image gates; nil means hash and share. See
    /// `ClientClipboardSession.prejudgeLocalImage`.
    public mutating func prejudgeLocalClipboardImage(
        byteCount: Int
    ) -> ClientClipboardSessionDecision? {
        clipboard.prejudgeLocalImage(
            byteCount: byteCount, agreed: capabilities.agreed)
    }

    public mutating func shareLocalClipboardImage(
        _ data: [UInt8],
        sha256: () -> [UInt8],
        rng: inout some RandomNumberGenerator
    ) -> ClientClipboardSessionDecision {
        clipboard.shareLocalImage(
            data, sha256: sha256, rng: &rng, agreed: capabilities.agreed)
    }

    public mutating func receiveClipboardImageCargo(
        _ bytes: [UInt8]
    ) -> ClientClipboardSessionDecision {
        clipboard.receiveImageCargo(bytes, agreed: capabilities.agreed)
    }

    public func clipboardClaimsBulk(_ message: BulkMessage) -> Bool {
        clipboard.claimsBulk(message)
    }

    public mutating func receiveClipboardBulk(
        _ message: BulkMessage,
        hasher: () -> any ClipboardImageHasher
    ) -> ClientClipboardSessionDecision {
        clipboard.receiveBulk(message, hasher: hasher)
    }

    /// One authenticated audio datagram: the track is active again and, on
    /// the first one, the detector tightens.
    public mutating func noteAudioEvidence(
        now: ClientTimestamp
    ) -> ClientDetectorPosture? {
        mediaPosture.noteAudioEvidence()
        guard let tightened = tightenedBlackoutSilenceMicroseconds,
              !detectorTightened
        else { return nil }
        var config = machineConfig
        config.blackoutSilenceMicroseconds = tightened
        guard lifecycle.reconfigure(config, now: now) else { return nil }
        detectorTightened = true
        return .tightened(blackoutSilenceMicroseconds: tightened)
    }

    /// Advances injected time or applies a local lifecycle input.
    public mutating func advance(
        _ input: SessionInput? = nil,
        now: ClientTimestamp
    ) -> ClientSessionLifecycleDecision {
        lifecycle.advance(input, now: now)
    }

    @discardableResult
    public mutating func reconfigure(
        _ config: SessionMachineConfig,
        now: ClientTimestamp
    ) -> Bool {
        lifecycle.reconfigure(config, now: now)
    }

    /// Routes every reliable word currently owned by client-control policy.
    /// `nil` leaves media and feature words to their narrower organs.
    /// - Throws: only `ClientCapabilitySession.receive`'s contract break;
    ///   hostile bytes become events, never errors.
    public mutating func receiveReliable(
        _ bytes: [UInt8],
        now: ClientTimestamp
    ) throws -> ClientControlSessionDecision? {
        if let ingress = lifecycle.receiveReliable(bytes, now: now) {
            switch ingress {
            case .applied(let message, let decision):
                return ClientControlSessionDecision(
                    event: .lifecycle(message),
                    lifecycle: decision)
            case .malformed(let message):
                return ClientControlSessionDecision(
                    event: .malformedLifecycle(message))
            }
        }

        guard let decision = try capabilities.receive(bytes) else {
            if let decision = audioRouting.receiveReliable(
                bytes, agreed: capabilities.agreed
            ) {
                return ClientControlSessionDecision(
                    outboundReliable: decision.outboundReliable,
                    event: .audioRouting(decision.event))
            }
            if let event = clipboard.receiveReliable(
                bytes, agreed: capabilities.agreed
            ) {
                return ClientControlSessionDecision(
                    event: .clipboard(event))
            }
            if let event = cursor.receiveReliable(
                bytes, agreed: capabilities.agreed
            ) {
                return ClientControlSessionDecision(event: .cursor(event))
            }
            if let event = mediaPosture.receiveReliable(
                bytes, agreed: capabilities.agreed
            ) {
                return ClientControlSessionDecision(
                    event: .mediaPosture(event),
                    detectorPosture: relaxDetectorIfQuiet(event, now: now))
            }
            return nil
        }
        let lifecycleDecision = decision.teardownReason.map {
            lifecycle.advance(.teardownRequest($0), now: now)
        }
        return ClientControlSessionDecision(
            outboundReliable: decision.outboundReliable,
            event: .capability(decision.event),
            lifecycle: lifecycleDecision
        )
    }

    /// An announced audio quiet restores the baseline threshold until
    /// audio resumes; repeated quiet check-ins change nothing.
    private mutating func relaxDetectorIfQuiet(
        _ event: ClientMediaPostureSessionEvent, now: ClientTimestamp
    ) -> ClientDetectorPosture? {
        guard case .audioState(let state) = event, state.state == .quiet,
              detectorTightened,
              lifecycle.reconfigure(machineConfig, now: now)
        else { return nil }
        detectorTightened = false
        return .relaxed(
            blackoutSilenceMicroseconds: machineConfig.blackoutSilenceMicroseconds)
    }
}
