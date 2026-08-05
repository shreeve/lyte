import LyteWire

/// A client request that the agreed capability set cannot express.
public enum AudioRoutingAskError: Error, Hashable, Sendable {
    case notNegotiated
    case streamOffNotNegotiated
}

/// What the first truthful host posture required from session-start policy.
public enum ClientAudioRoutingStartup: Hashable, Sendable {
    case none
    case requested(HostAudioRoutingMode)
    case refused(HostAudioRoutingMode, AudioRoutingAskError)
}

/// One client-role interpretation of a host-audio reliable word.
public enum ClientAudioRoutingSessionEvent: Hashable, Sendable {
    case status(HostAudioRoutingMode, startup: ClientAudioRoutingStartup)
    case malformedStatus
    case unnegotiatedStatus
    case roleConfusedRequest
}

public struct ClientAudioRoutingSessionDecision: Hashable, Sendable {
    public let outboundReliable: [[UInt8]]
    public let event: ClientAudioRoutingSessionEvent

    public init(
        outboundReliable: [[UInt8]] = [],
        event: ClientAudioRoutingSessionEvent
    ) {
        self.outboundReliable = outboundReliable
        self.event = event
    }
}

/// IO-free client policy for the host's own speaker posture. The confirmed
/// posture changes only on a truthful 0x19; the first one reconciles the
/// session-start preference exactly once. Capability gates are value inputs so
/// this organ never duplicates or caches the negotiated set.
public struct ClientAudioRoutingSession: Sendable {
    private let desiredAtStart: HostAudioRoutingMode?
    public private(set) var posture: HostAudioRoutingMode?

    public init(desiredAtStart: HostAudioRoutingMode?) {
        self.desiredAtStart = desiredAtStart
    }

    public func request(
        _ mode: HostAudioRoutingMode,
        agreed: Capabilities?
    ) throws -> [UInt8] {
        try requestResult(mode, agreed: agreed).get()
    }

    private func requestResult(
        _ mode: HostAudioRoutingMode,
        agreed: Capabilities?
    ) -> Result<[UInt8], AudioRoutingAskError> {
        guard agreed?.hostAudioRouting == true else {
            return .failure(.notNegotiated)
        }
        if mode == .streamOff, agreed?.audioStreamOff != true {
            return .failure(.streamOffNotNegotiated)
        }
        return .success(AudioRoutingRequest(mode: mode).encode())
    }

    /// Handles only 0x18/0x19. A client-bound 0x18 is role confusion even when
    /// its body is malformed: this direction can never legitimately carry it.
    public mutating func receiveReliable(
        _ bytes: [UInt8],
        agreed: Capabilities?
    ) -> ClientAudioRoutingSessionDecision? {
        switch bytes.first {
        case CtrlMessageType.audioRoutingRequest:
            return ClientAudioRoutingSessionDecision(
                event: .roleConfusedRequest)

        case CtrlMessageType.audioRoutingStatus:
            guard let status = try? AudioRoutingStatus.decode(bytes) else {
                return ClientAudioRoutingSessionDecision(
                    event: .malformedStatus)
            }
            guard agreed?.hostAudioRouting == true else {
                return ClientAudioRoutingSessionDecision(
                    event: .unnegotiatedStatus)
            }

            let isFirstStatus = posture == nil
            posture = status.mode
            guard isFirstStatus,
                  let desiredAtStart,
                  desiredAtStart != status.mode
            else {
                return ClientAudioRoutingSessionDecision(
                    event: .status(status.mode, startup: .none))
            }
            switch requestResult(desiredAtStart, agreed: agreed) {
            case .success(let bytes):
                return ClientAudioRoutingSessionDecision(
                    outboundReliable: [bytes],
                    event: .status(
                        status.mode,
                        startup: .requested(desiredAtStart)))
            case .failure(let error):
                return ClientAudioRoutingSessionDecision(
                    event: .status(
                        status.mode,
                        startup: .refused(desiredAtStart, error)))
            }

        default:
            return nil
        }
    }
}
