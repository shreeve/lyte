// The capability wire messages, CTRL types 0x0F / 0x11 / 0x12, all on the
// sealed ARQ ordered stream: the declaration is the first
// post-establishment word each way (everything gated on a capability
// orders behind it), and an update ack never reorders against its update.
//
// Declaration (0x0F): `type ‖ CBOR map` — one end's full capability set.
// There is no accept/reject round: the intersection IS the agreement.
//
// Update (0x11): `type ‖ CBOR map` — a renegotiation proposal carrying
// only renegotiable registry keys; naming a fixed or unknown key rejects
// at the negotiator. Host→client only: the sender of media proposes
// geometry.
//
// Update ack (0x12): `type ‖ status ‖ CBOR map` — status 0x01 accepted /
// 0x02 rejected; the map echoes the proposal verbatim, binding the ack to
// specific bytes. Accepted parameters apply at the next IDR boundary.
//
// The CBOR body extends to the end of the message; its trailing-bytes
// rule makes the message exactly its layout. The whole encoded message is
// capped at 1024 bytes against a peer streaming megabytes of
// "capabilities" through the reassembler.

/// The capability-declaration CTRL message (type 0x0F).
public struct CapabilityDeclaration: Hashable, Sendable {
    public var capabilities: Capabilities

    /// Ceiling for any encoded capability message, type byte included.
    public static let maxEncodedByteCount = 1024

    public init(capabilities: Capabilities) {
        self.capabilities = capabilities
    }

    /// Encodes `type ‖ CBOR map`. Throws on a non-encodable set or a
    /// message past the 1024 B ceiling.
    public func encode() throws -> [UInt8] {
        let body = try capabilities.encodeCbor()
        guard 1 + body.count <= Self.maxEncodedByteCount else {
            throw CapabilityMessageError.messageOverBudget(1 + body.count)
        }
        return [CtrlMessageType.capabilityDeclaration] + body
    }

    /// Decodes a whole ARQ-delivered CTRL message (type byte first).
    /// Unknown capability keys pass through (the forward-compat rule);
    /// malformed CBOR, wrong registry types, and missing required
    /// keys reject. Never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> CapabilityDeclaration {
        let body = try checkCapabilityFrame(
            payload, type: CtrlMessageType.capabilityDeclaration
        )
        do {
            return CapabilityDeclaration(
                capabilities: try Capabilities.decodeCbor(body)
            )
        } catch let error as CapabilityError {
            throw CapabilityMessageError.malformedBody(error)
        }
    }

    public static func decode(
        _ payload: [UInt8]
    ) throws -> CapabilityDeclaration {
        try decode(payload[...])
    }
}

/// One renegotiation parameter: a registry key and its proposed CBOR
/// value. The value stays CBOR-typed at this layer — which keys are
/// renegotiable and what their values may be is the negotiator's
/// judgment, framing is this file's.
public struct CapabilityParameter: Hashable, Sendable {
    public var key: UInt64
    public var value: CborValue

    public init(key: UInt64, value: CborValue) {
        self.key = key
        self.value = value
    }
}

/// The session-parameter update proposal (type 0x11).
public struct CapabilityUpdate: Hashable, Sendable, SliceDecodable {
    /// Key-ascending (the CBOR map's canonical order).
    public var parameters: [CapabilityParameter]

    public init(parameters: [CapabilityParameter]) {
        self.parameters = parameters
    }

    /// Encodes `type ‖ CBOR map`. Throws on an empty proposal (a
    /// no-op update is a bug, not a message), duplicate keys, or the
    /// 1024 B ceiling.
    public func encode() throws -> [UInt8] {
        guard !parameters.isEmpty else {
            throw CapabilityMessageError.emptyUpdate
        }
        let body = try encodeParameterMap(parameters)
        guard 1 + body.count
            <= CapabilityDeclaration.maxEncodedByteCount else {
            throw CapabilityMessageError.messageOverBudget(1 + body.count)
        }
        return [CtrlMessageType.capabilityUpdate] + body
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> CapabilityUpdate {
        let body = try checkCapabilityFrame(
            payload, type: CtrlMessageType.capabilityUpdate
        )
        let parameters = try decodeParameterMap(body)
        guard !parameters.isEmpty else {
            throw CapabilityMessageError.emptyUpdate
        }
        return CapabilityUpdate(parameters: parameters)
    }
}

/// How an update was answered, as the wire carries it.
public enum CapabilityUpdateStatus: UInt8, Hashable, CaseIterable, Sendable {
    case accepted = 0x01
    case rejected = 0x02
}

/// The update answer (type 0x12), echoing the proposal it answers.
public struct CapabilityUpdateAck: Hashable, Sendable {
    public var status: CapabilityUpdateStatus
    /// The answered proposal's parameters, echoed verbatim.
    public var parameters: [CapabilityParameter]

    public init(
        status: CapabilityUpdateStatus,
        parameters: [CapabilityParameter]
    ) {
        self.status = status
        self.parameters = parameters
    }

    /// Encodes `type ‖ status ‖ CBOR map`. Same refusals as the
    /// update it echoes.
    public func encode() throws -> [UInt8] {
        guard !parameters.isEmpty else {
            throw CapabilityMessageError.emptyUpdate
        }
        let body = try encodeParameterMap(parameters)
        guard 2 + body.count
            <= CapabilityDeclaration.maxEncodedByteCount else {
            throw CapabilityMessageError.messageOverBudget(2 + body.count)
        }
        return [CtrlMessageType.capabilityUpdateAck, status.rawValue] + body
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> CapabilityUpdateAck {
        guard payload.count >= 2 else {
            throw CapabilityMessageError.truncatedMessage
        }
        guard payload.count <= CapabilityDeclaration.maxEncodedByteCount
        else {
            throw CapabilityMessageError.messageOverBudget(payload.count)
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.capabilityUpdateAck else {
            throw CapabilityMessageError.unexpectedType(payload[base])
        }
        guard let status = CapabilityUpdateStatus(
            rawValue: payload[base + 1]
        ) else {
            throw CapabilityMessageError.unknownStatus(payload[base + 1])
        }
        let parameters = try decodeParameterMap(payload[(base + 2)...])
        guard !parameters.isEmpty else {
            throw CapabilityMessageError.emptyUpdate
        }
        return CapabilityUpdateAck(status: status, parameters: parameters)
    }

    public static func decode(
        _ payload: [UInt8]
    ) throws -> CapabilityUpdateAck {
        try decode(payload[...])
    }
}

/// Everything the capability message codecs can refuse. Hostile bytes
/// throw, never trap.
public enum CapabilityMessageError: Error, Hashable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    case unknownStatus(UInt8)
    case messageOverBudget(Int)
    case emptyUpdate
    /// An update/ack map key that is not a CBOR unsigned — parameter
    /// keys are registry numbers by definition.
    case nonIntegerParameterKey
    case malformedBody(CapabilityError)
}

// MARK: - Shared framing

private func checkCapabilityFrame(
    _ payload: ArraySlice<UInt8>, type: UInt8
) throws -> ArraySlice<UInt8> {
    guard payload.count >= 2 else {
        throw CapabilityMessageError.truncatedMessage
    }
    guard payload.count <= CapabilityDeclaration.maxEncodedByteCount else {
        throw CapabilityMessageError.messageOverBudget(payload.count)
    }
    guard payload[payload.startIndex] == type else {
        throw CapabilityMessageError.unexpectedType(
            payload[payload.startIndex]
        )
    }
    return payload[(payload.startIndex + 1)...]
}

private func encodeParameterMap(
    _ parameters: [CapabilityParameter]
) throws -> [UInt8] {
    try Cbor.encode(.map(parameters.map {
        CborMapEntry(key: .unsigned($0.key), value: $0.value)
    }))
}

private func decodeParameterMap(
    _ bytes: ArraySlice<UInt8>
) throws -> [CapabilityParameter] {
    let value: CborValue
    do {
        value = try Cbor.decode(bytes)
    } catch let error as CborError {
        throw CapabilityMessageError.malformedBody(.malformedCbor(error))
    }
    guard case .map(let entries) = value else {
        throw CapabilityMessageError.malformedBody(.notAMap)
    }
    return try entries.map { entry in
        guard case .unsigned(let key) = entry.key else {
            throw CapabilityMessageError.nonIntegerParameterKey
        }
        return CapabilityParameter(key: key, value: entry.value)
    }
}
