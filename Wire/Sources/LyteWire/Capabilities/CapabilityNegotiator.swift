// The sans-IO capability negotiation machine. The shell owns carriage
// (the sealed ARQ ordered stream guarantees order and exactly-once); this
// type owns judgment — what to send, what an inbound message means, and
// what the session may now do.
//
// `start()` yields the local declaration; `receive` of the peer's
// declaration computes agreed = local ∩ remote and settles the session,
// or fails it when no video codec or chroma mode is common.
//
// Renegotiation is host→client only. The client answers an update: only
// `maxDatagramBytes` may move, within [1152, agreed ceiling]; a bad
// proposal draws a rejected ack echoing it, never a teardown, and an
// accepted one moves `operativeMaxDatagramBytes` (applied by the shell
// at the next IDR boundary). The host never proposes.
//
// Protocol violations (a second declaration, an update at the host, a
// capability message before the declaration) throw; the shell treats a
// throw as a peer protocol violation.

/// Which end this machine negotiates for. The role decides who may
/// answer renegotiation (the client), nothing else — declarations
/// are symmetric.
public enum CapabilityRole: Sendable {
    case host
    case client
}

/// What an inbound capability message means for the session.
public enum CapabilityEvent: Hashable, Sendable {
    /// The exchange settled: this is the session's agreed set.
    /// `operativeMaxDatagramBytes` starts at the 1152 B default
    /// regardless of the agreed ceiling.
    case agreed(Capabilities)
    /// A peer update was answered — send this ack. Its `status` says
    /// which way; on accept the negotiator has already moved its
    /// operative value.
    case answerUpdate(CapabilityUpdateAck)
}

/// Why an exchange failed to produce a workable session.
public enum CapabilityNegotiationError: Error, Hashable, Sendable {
    /// The intersection has no video codec — nothing to stream.
    case noCommonVideoCodec
    /// The intersection has no chroma mode.
    case noCommonChromaMode
    /// A declaration arrived after the exchange already settled.
    case duplicateDeclaration
    /// A capability message arrived before the exchange settled.
    case notEstablished
    /// An update arrived at the host.
    case wrongRoleForUpdate
}

/// The negotiation machine. Not thread-safe by design (sans-IO: the
/// shell serializes, same as ArqEndpoint).
public struct CapabilityNegotiator: Sendable {
    public let role: CapabilityRole
    public let local: Capabilities

    /// The agreed set, nil until the peer's declaration lands.
    public private(set) var agreed: Capabilities?
    /// The session's CURRENT datagram ceiling: 1152 from establishment
    /// (the bridge-safe default), moved only by an accepted update,
    /// never past the agreed ceiling.
    public private(set) var operativeMaxDatagramBytes =
        UInt32(WireBudget.maxDatagramByteCount)

    private var declarationSent = false

    public init(role: CapabilityRole, local: Capabilities) {
        self.role = role
        self.local = local
    }

    // MARK: - Declaration exchange

    /// The local declaration to send exactly once after establishment.
    public mutating func start() -> CapabilityDeclaration? {
        guard !declarationSent else { return nil }
        declarationSent = true
        return CapabilityDeclaration(capabilities: local)
    }

    /// The peer's declaration: computes and settles the agreed set.
    /// Throws when the result cannot carry a session or when a
    /// declaration already settled.
    public mutating func receive(
        _ declaration: CapabilityDeclaration
    ) throws -> CapabilityEvent {
        guard agreed == nil else {
            throw CapabilityNegotiationError.duplicateDeclaration
        }
        let intersection = local.intersecting(declaration.capabilities)
        guard !intersection.videoCodecs.isEmpty else {
            throw CapabilityNegotiationError.noCommonVideoCodec
        }
        guard !intersection.chromaModes.isEmpty else {
            throw CapabilityNegotiationError.noCommonChromaMode
        }
        agreed = intersection
        return .agreed(intersection)
    }

    // MARK: - Renegotiation

    /// A peer update (client role only). Judges the proposal and
    /// returns the ack to send; acceptance moves the operative value.
    /// A bad proposal draws a rejected ack, not a throw — only
    /// role/state violations are protocol errors.
    public mutating func receive(
        _ update: CapabilityUpdate
    ) throws -> CapabilityEvent {
        guard role == .client else {
            throw CapabilityNegotiationError.wrongRoleForUpdate
        }
        guard let agreed else {
            throw CapabilityNegotiationError.notEstablished
        }
        let values = update.parameters.compactMap { parameter -> UInt32? in
            guard parameter.key == CapabilityKey.maxDatagramBytes,
                  case .unsigned(let raw) = parameter.value,
                  let value = UInt32(exactly: raw),
                  value >= UInt32(WireBudget.maxDatagramByteCount),
                  value <= agreed.maxDatagramBytes else {
                return nil
            }
            return value
        }
        let acceptable = values.count == update.parameters.count
        if acceptable, let value = values.last {
            operativeMaxDatagramBytes = value
        }
        return .answerUpdate(CapabilityUpdateAck(
            status: acceptable ? .accepted : .rejected,
            parameters: update.parameters
        ))
    }
}
