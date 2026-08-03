// The session face of W5: the IK handshake with Lyte's first-payload
// rule applied. There is no ALPN (Lyte-UDP decision §8.3), so the wire
// major version rides inside the first handshake message's encrypted
// payload — one version byte prefixing whatever application payload the
// caller supplies — and a mismatch aborts the handshake loudly, before
// any transport key exists. Message 2's payload echoes the responder's
// version byte back, so both ends prove agreement inside the transcript.
//
// Driving the messages over a socket is host/client territory (HS-7 and
// CL-1 plug their `TransportCrypto` seams into this); everything here is
// sans-IO bytes-in/bytes-out.

public struct NoiseSession: Sendable {
    public private(set) var handshake: NoiseHandshake
    /// Set once both version bytes have been verified.
    public private(set) var negotiatedVersion: UInt8?

    /// - Parameters:
    ///   - remoteStaticPublicKey: required for the initiator (the pinned
    ///     host static from pairing); must be nil-or-ignored for the
    ///     responder, which learns the peer static from message 1.
    ///   - fixedEphemeral: test vectors and vectorgen only.
    public init(
        role: NoiseRole,
        staticKeys: NoiseKeyPair,
        remoteStaticPublicKey: [UInt8]? = nil,
        prologue: [UInt8] = [],
        fixedEphemeral: NoiseKeyPair? = nil
    ) throws {
        handshake = try NoiseHandshake(
            role: role,
            staticKeys: staticKeys,
            remoteStaticPublicKey: remoteStaticPublicKey,
            prologue: prologue,
            fixedEphemeral: fixedEphemeral
        )
    }

    public var isComplete: Bool { handshake.isComplete }

    /// The transcript hash — after completion, the handshake hash the W6
    /// PAKE binds to (Lyte-UDP decision §8.2). Also available on the
    /// `NoiseTransport` this session produces.
    public var handshakeHash: [UInt8] { handshake.handshakeHash }

    /// The peer's authenticated static key: known from init on the
    /// initiator, learned from message 1 on the responder. Checking it
    /// against the paired set is the shell's job.
    public var remoteStaticPublicKey: [UInt8]? {
        handshake.remoteStaticPublicKey
    }

    // MARK: Initiator side

    /// Builds message 1: version byte ‖ `applicationPayload`, encrypted
    /// per the pattern.
    public mutating func writeMessage1(
        applicationPayload: ArraySlice<UInt8> = [][...]
    ) throws -> [UInt8] {
        try handshake.writeMessage1(
            payload: ([WireVersion.major] + applicationPayload)[...]
        )
    }

    /// Reads message 2, verifying the responder's echoed version byte.
    /// Returns the application payload after the version byte.
    public mutating func readMessage2(
        _ message: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        let payload = try handshake.readMessage2(message)
        return try verifyVersion(in: payload)
    }

    // MARK: Responder side

    /// Reads message 1, rejecting a wire-major mismatch before any
    /// transport state exists. Returns the application payload after the
    /// version byte.
    public mutating func readMessage1(
        _ message: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        let payload = try handshake.readMessage1(message)
        return try verifyVersion(in: payload)
    }

    /// Builds message 2: our version byte echoed ‖ `applicationPayload`.
    public mutating func writeMessage2(
        applicationPayload: ArraySlice<UInt8> = [][...]
    ) throws -> [UInt8] {
        try handshake.writeMessage2(
            payload: ([WireVersion.major] + applicationPayload)[...]
        )
    }

    // MARK: Completion

    /// The transport both `TransportCrypto` seams wrap: seal/unseal with
    /// the extended-counter nonce, replay window, and rekey epochs.
    public func makeTransport() throws -> NoiseTransport {
        let (send, receive) = try handshake.splitCipherStates()
        return NoiseTransport(
            send: send,
            receive: receive,
            handshakeHash: handshake.handshakeHash
        )
    }

    private mutating func verifyVersion(in payload: [UInt8]) throws -> [UInt8] {
        guard let received = payload.first else {
            throw NoiseError.missingVersionPayload
        }
        guard received == WireVersion.major else {
            throw NoiseError.versionMismatch(
                received: received, expected: WireVersion.major
            )
        }
        negotiatedVersion = received
        return Array(payload.dropFirst())
    }
}
