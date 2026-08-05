import LyteWire

/// The control edge a platform shell should surface after offering one
/// reliable word to the IO-free client session.
public enum ClientControlSessionEvent: Hashable, Sendable {
    case lifecycle(ClientLifecycleMessage)
    case malformedLifecycle(ClientLifecycleMessage)
    case capability(ClientCapabilitySessionEvent)
    case audioRouting(ClientAudioRoutingSessionEvent)
    case clipboard(ClientClipboardSessionEvent)
}

/// One composed client-control decision. The shell sends the returned bytes,
/// projects the typed event, then executes any lifecycle actions.
public struct ClientControlSessionDecision: Hashable, Sendable {
    public let outboundReliable: [[UInt8]]
    public let event: ClientControlSessionEvent
    public let lifecycle: ClientSessionLifecycleDecision?

    public init(
        outboundReliable: [[UInt8]] = [],
        event: ClientControlSessionEvent,
        lifecycle: ClientSessionLifecycleDecision? = nil
    ) {
        self.outboundReliable = outboundReliable
        self.event = event
        self.lifecycle = lifecycle
    }
}

/// The single IO-free control boundary shared by every client platform shell.
/// It composes capability and lifecycle organs so cross-organ consequences,
/// such as an unworkable capability set causing typed teardown, are decided
/// once rather than reimplemented by each platform.
public struct ClientControlSession: Sendable {
    private var lifecycle: ClientSessionLifecycle
    private var capabilities: ClientCapabilitySession
    private var audioRouting: ClientAudioRoutingSession
    private var clipboard: ClientClipboardSession

    public init(
        localCapabilities: Capabilities,
        machineConfig: SessionMachineConfig,
        desiredHostAudioRouting: HostAudioRoutingMode?,
        clipboardSharingAtStart: Bool = false,
        clipboardImageSharingAtStart: Bool = false,
        now: ClientTimestamp
    ) {
        lifecycle = ClientSessionLifecycle(config: machineConfig, now: now)
        capabilities = ClientCapabilitySession(local: localCapabilities)
        audioRouting = ClientAudioRoutingSession(
            desiredAtStart: desiredHostAudioRouting)
        clipboard = ClientClipboardSession(
            textSharingAtStart: clipboardSharingAtStart,
            imageSharingAtStart: clipboardImageSharingAtStart)
    }

    public var state: SessionState { lifecycle.state }
    public var wireMode: SessionWireMode { lifecycle.wireMode }
    public var isFrozen: Bool { lifecycle.isFrozen }
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
    public var operativeMaxDatagramBytes: UInt32 {
        capabilities.operativeMaxDatagramBytes
    }

    /// Returns the client's declaration exactly once for the shell to send as
    /// its first post-establishment reliable word.
    public mutating func start() throws -> [UInt8]? {
        try capabilities.start()
    }

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

    public mutating func shareLocalClipboardImage(
        _ data: [UInt8],
        sha256: [UInt8],
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
        sha256: ([UInt8]) -> [UInt8]
    ) -> ClientClipboardSessionDecision {
        clipboard.receiveBulk(message, sha256: sha256)
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
            guard let decision = audioRouting.receiveReliable(
                bytes, agreed: capabilities.agreed)
            else {
                guard let event = clipboard.receiveReliable(
                    bytes, agreed: capabilities.agreed)
                else {
                    return nil
                }
                return ClientControlSessionDecision(
                    event: .clipboard(event))
            }
            return ClientControlSessionDecision(
                outboundReliable: decision.outboundReliable,
                event: .audioRouting(decision.event))
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
}
