import LyteWire

/// The capability word being interpreted by the client session policy.
public enum ClientCapabilityMessage: Hashable, Sendable {
    case declaration
    case update
}

public enum ClientCapabilitySessionError: Error, Hashable, Sendable {
    case unexpectedNegotiatorEvent
}

/// A client-role capability result for the platform shell to surface.
public enum ClientCapabilitySessionEvent: Hashable, Sendable {
    case agreed(Capabilities)
    case failed(CapabilityNegotiationError)
    case updateAnswered(accepted: Bool)
    case malformed(ClientCapabilityMessage)
    case refused(ClientCapabilityMessage, CapabilityNegotiationError)
}

/// One IO-free capability decision. Outbound bytes ride the client's ordered
/// reliable stream; teardown is a lifecycle input, not an IO side effect.
public struct ClientCapabilitySessionDecision: Hashable, Sendable {
    public let outboundReliable: [[UInt8]]
    public let event: ClientCapabilitySessionEvent
    public let teardownReason: SessionTeardownReason?

    public init(
        outboundReliable: [[UInt8]] = [],
        event: ClientCapabilitySessionEvent,
        teardownReason: SessionTeardownReason? = nil
    ) {
        self.outboundReliable = outboundReliable
        self.event = event
        self.teardownReason = teardownReason
    }
}

/// IO-free client-role orchestration around LyteWire's symmetric capability
/// machine. This organ owns client judgment: declaration-first startup,
/// decoding the two client-bound words, answering updates, and turning an
/// unworkable intersection into a typed teardown recommendation.
public struct ClientCapabilitySession: Sendable {
    private var negotiator: CapabilityNegotiator

    public init(local: Capabilities) {
        negotiator = CapabilityNegotiator(role: .client, local: local)
    }

    public var agreed: Capabilities? { negotiator.agreed }
    public var operativeMaxDatagramBytes: UInt32 {
        negotiator.operativeMaxDatagramBytes
    }

    /// Returns the declaration exactly once. The shell sends these bytes as
    /// the first post-establishment reliable word.
    /// - Throws: `CapabilityMessageError` when the local capabilities do
    ///   not encode (a local configuration bug).
    public mutating func start() throws -> [UInt8]? {
        guard let declaration = negotiator.start() else { return nil }
        return try declaration.encode()
    }

    /// Handles only client-bound capability words. `nil` leaves all other
    /// reliable message types to their owning client organs. Hostile or
    /// unanswerable words become `.malformed`/`.refused` events.
    /// - Throws: `ClientCapabilitySessionError.unexpectedNegotiatorEvent`
    ///   only if LyteWire's negotiator breaks its event contract.
    public mutating func receive(
        _ bytes: [UInt8]
    ) throws -> ClientCapabilitySessionDecision? {
        switch bytes.first {
        case CtrlMessageType.capabilityDeclaration:
            guard let declaration = try? CapabilityDeclaration.decode(bytes)
            else {
                return ClientCapabilitySessionDecision(
                    event: .malformed(.declaration))
            }
            do {
                let event = try negotiator.receive(declaration)
                guard case .agreed(let capabilities) = event else {
                    throw ClientCapabilitySessionError
                        .unexpectedNegotiatorEvent
                }
                return ClientCapabilitySessionDecision(
                    event: .agreed(capabilities))
            } catch let failure as CapabilityNegotiationError
                where failure == .noCommonVideoCodec
                    || failure == .noCommonChromaMode
            {
                return ClientCapabilitySessionDecision(
                    event: .failed(failure),
                    teardownReason: .shuttingDown)
            } catch let failure as CapabilityNegotiationError {
                return ClientCapabilitySessionDecision(
                    event: .refused(.declaration, failure))
            }

        case CtrlMessageType.capabilityUpdate:
            guard let update = try? CapabilityUpdate.decode(bytes) else {
                return ClientCapabilitySessionDecision(
                    event: .malformed(.update))
            }
            do {
                let event = try negotiator.receive(update)
                guard case .answerUpdate(let acknowledgement) = event else {
                    throw ClientCapabilitySessionError
                        .unexpectedNegotiatorEvent
                }
                // The ack's status byte makes it one byte longer than
                // the update it echoes: an update at the ceiling cannot be
                // answered and is malformed from this end's view.
                guard let ack = try? acknowledgement.encode() else {
                    return ClientCapabilitySessionDecision(
                        event: .malformed(.update))
                }
                return ClientCapabilitySessionDecision(
                    outboundReliable: [ack],
                    event: .updateAnswered(
                        accepted: acknowledgement.status == .accepted))
            } catch let failure as CapabilityNegotiationError {
                return ClientCapabilitySessionDecision(
                    event: .refused(.update, failure))
            }

        default:
            return nil
        }
    }
}
