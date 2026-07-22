// The sans-IO capability negotiation machine (W7) — HS-8's and CL-7's
// explicitly deferred third item. One machine, two roles, mirroring the
// SessionStateMachine pattern: the shell owns carriage (declarations
// and updates ride the sealed ARQ ordered stream; ordering and
// exactly-once delivery are the ARQ's guarantees, assumed here), this
// type owns judgment — what to send, what an inbound message means,
// and what the session may now do.
//
// Exchange shape: `start()` yields the local declaration to send (the
// first post-establishment word on the CTRL stream); `receive` of the
// peer's declaration computes agreed = local ∩ remote and either
// settles the session or fails it (no common video codec / chroma mode
// = no session — a typed failure the shell turns into a teardown).
// There is no accept round: the intersection is the agreement, and
// both ends compute it identically from the same two declarations.
//
// Renegotiation (v1): host→client only — the host owns pacing and
// geometry, so the media sender proposes (`.host` role; the client
// answers). One proposal outstanding at a time; the ordered stream
// makes proposal/answer pairing positional, and the ack's echoed
// parameters re-verify it byte-wise anyway. Only registry keys marked
// renegotiable may move (v1: maxDatagramBytes), only within
// [1152, agreed ceiling] — an out-of-bounds or fixed-key proposal is
// answered with a rejected ack carrying the proposal verbatim, never
// a teardown: a broken proposal wastes a round trip, an accepted one
// changes `operativeMaxDatagramBytes` on both ends (applied at the
// next IDR boundary; that timing is shell business).
//
// Everything protocol-violating (a second declaration, an update from
// the non-proposer, an ack with nothing outstanding, an ack echoing
// the wrong bytes, any capability message before establishment's
// declaration) throws — the shell treats a throw as a peer protocol
// violation, same doctrine as the codecs.

/// Which end this machine negotiates for. The role decides who may
/// propose renegotiation (v1: the host), nothing else — declarations
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
    /// A peer update was answered — send this ack. `accepted` says
    /// which way; on accept the negotiator has already moved its
    /// operative value.
    case answerUpdate(CapabilityUpdateAck)
    /// Our outstanding proposal was accepted; the operative value
    /// moved. Apply at the next IDR boundary.
    case updateAccepted([CapabilityParameter])
    /// Our outstanding proposal was rejected; nothing moved.
    case updateRejected([CapabilityParameter])
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
    /// An update arrived at the proposing end (v1: the host), or a
    /// local propose was attempted at the answering end.
    case wrongRoleForUpdate
    /// An ack arrived with no proposal outstanding.
    case unexpectedAck
    /// An ack whose echoed parameters differ from the outstanding
    /// proposal's bytes.
    case ackParameterMismatch
    /// A local propose while one is already outstanding.
    case proposalAlreadyOutstanding
    /// A local propose naming a fixed or unknown key, or a value
    /// outside [1152, agreed ceiling] — caught before it wastes a
    /// round trip.
    case invalidLocalProposal
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
    private var outstandingProposal: [CapabilityParameter]?

    public init(role: CapabilityRole, local: Capabilities) {
        self.role = role
        self.local = local
    }

    // MARK: - Declaration exchange

    /// The local declaration to send, once, immediately after
    /// establishment. Idempotent accessor for the message; the shell
    /// sends it on the ARQ ordered stream.
    public mutating func start() -> CapabilityDeclaration {
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

    /// Builds a geometry-raise proposal (the DPLPMTUD seam). Host
    /// role only, one outstanding at a time, value validated against
    /// the agreed ceiling before it costs a round trip.
    public mutating func proposeMaxDatagramBytes(
        _ value: UInt32
    ) throws -> CapabilityUpdate {
        guard role == .host else {
            throw CapabilityNegotiationError.wrongRoleForUpdate
        }
        guard let agreed else {
            throw CapabilityNegotiationError.notEstablished
        }
        guard outstandingProposal == nil else {
            throw CapabilityNegotiationError.proposalAlreadyOutstanding
        }
        guard value >= UInt32(WireBudget.maxDatagramByteCount),
              value <= agreed.maxDatagramBytes else {
            throw CapabilityNegotiationError.invalidLocalProposal
        }
        let parameters = [CapabilityParameter(
            key: CapabilityKey.maxDatagramBytes,
            value: .unsigned(UInt64(value))
        )]
        outstandingProposal = parameters
        return CapabilityUpdate(parameters: parameters)
    }

    /// A peer update (client role only in v1). Judges the proposal and
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
        let acceptable = update.parameters.allSatisfy { parameter in
            guard CapabilityKey.renegotiableKeys.contains(parameter.key),
                  parameter.key == CapabilityKey.maxDatagramBytes,
                  case .unsigned(let raw) = parameter.value,
                  let value = UInt32(exactly: raw),
                  value >= UInt32(WireBudget.maxDatagramByteCount),
                  value <= agreed.maxDatagramBytes else {
                return false
            }
            return true
        }
        if acceptable {
            for parameter in update.parameters {
                if case .unsigned(let raw) = parameter.value {
                    operativeMaxDatagramBytes = UInt32(raw)
                }
            }
        }
        return .answerUpdate(CapabilityUpdateAck(
            status: acceptable ? .accepted : .rejected,
            parameters: update.parameters
        ))
    }

    /// The answer to our outstanding proposal. The echo must match the
    /// proposal exactly; acceptance moves the operative value.
    public mutating func receive(
        _ ack: CapabilityUpdateAck
    ) throws -> CapabilityEvent {
        guard agreed != nil else {
            throw CapabilityNegotiationError.notEstablished
        }
        guard let proposal = outstandingProposal else {
            throw CapabilityNegotiationError.unexpectedAck
        }
        guard ack.parameters == proposal else {
            throw CapabilityNegotiationError.ackParameterMismatch
        }
        outstandingProposal = nil
        switch ack.status {
        case .accepted:
            for parameter in proposal {
                if case .unsigned(let raw) = parameter.value {
                    operativeMaxDatagramBytes = UInt32(raw)
                }
            }
            return .updateAccepted(proposal)
        case .rejected:
            return .updateRejected(proposal)
        }
    }
}
