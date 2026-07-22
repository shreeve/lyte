// The IK handshake (Noise spec §7.5), the WireGuard-proven pattern the
// core plan pins:
//
//   IK:
//     <- s            (responder's static, learned at pairing — pre-message)
//     ...
//     -> e, es, s, ss  + payload      message 1, initiator → responder
//     <- e, ee, se     + payload      message 2, responder → initiator
//
// Suite: Noise_IK_25519_ChaChaPoly_SHA256. One round trip, mutual
// authentication against pinned statics, forward secrecy from the
// ephemerals. This type is payload-agnostic — the wire-version rule for
// the first payload lives in NoiseSession, so published test vectors
// (arbitrary payloads) drive this layer byte-for-byte.

/// An X25519 key pair in raw 32-byte form. Static keys live in platform
/// keystores (shell territory); this type only carries bytes.
public struct NoiseKeyPair: Sendable {
    public let privateKey: [UInt8]
    public let publicKey: [UInt8]

    /// Derives the public key; throws on a malformed private key.
    public init(privateKey: [UInt8]) throws {
        self.privateKey = privateKey
        self.publicKey = try NoisePrimitives.publicKey(
            forPrivateKey: privateKey
        )
    }

    /// A fresh pair from the platform CSPRNG.
    public static func generate() -> NoiseKeyPair {
        // The freshly generated raw key is well-formed by construction.
        try! NoiseKeyPair(privateKey: NoisePrimitives.generatePrivateKey())
    }
}

public enum NoiseRole: Sendable, Equatable {
    /// The client: knows the responder's static key out-of-band (pairing).
    case initiator
    /// The host: learns and authenticates the initiator's static in msg 1.
    case responder
}

public struct NoiseHandshake: Sendable {
    /// "Noise_IK_25519_ChaChaPoly_SHA256" — exactly 32 ASCII bytes, so
    /// InitializeSymmetric uses it as h verbatim.
    public static let protocolName: [UInt8] = Array(
        "Noise_IK_25519_ChaChaPoly_SHA256".utf8
    )

    private enum Phase: Equatable {
        case awaitingMessage1
        case awaitingMessage2
        case complete
    }

    public let role: NoiseRole
    private var symmetric: NoiseSymmetricState
    private var phase: Phase = .awaitingMessage1

    private let staticKeys: NoiseKeyPair
    private var ephemeralKeys: NoiseKeyPair?
    /// Initiator: set at init (the pinned key). Responder: learned from
    /// message 1 — the identity to check against the paired set.
    public private(set) var remoteStaticPublicKey: [UInt8]?
    private var remoteEphemeralPublicKey: [UInt8]?

    /// Wire sizes: msg1 = e(32) ‖ enc(s)(48) ‖ enc(payload)(≥16);
    /// msg2 = e(32) ‖ enc(payload)(≥16).
    public static let message1MinimumByteCount = 32 + 48 + 16
    public static let message2MinimumByteCount = 32 + 16

    /// - Parameters:
    ///   - fixedEphemeral: ONLY for test vectors and the vectorgen tool —
    ///     a live handshake must let the CSPRNG pick (pass nil).
    public init(
        role: NoiseRole,
        staticKeys: NoiseKeyPair,
        remoteStaticPublicKey: [UInt8]? = nil,
        prologue: [UInt8] = [],
        fixedEphemeral: NoiseKeyPair? = nil
    ) throws {
        self.role = role
        self.staticKeys = staticKeys
        self.ephemeralKeys = fixedEphemeral

        var symmetric = NoiseSymmetricState(protocolName: Self.protocolName)
        symmetric.mixHash(prologue)

        // IK pre-message "<- s": the responder's static public key.
        switch role {
        case .initiator:
            guard let remote = remoteStaticPublicKey,
                  remote.count == NoisePrimitives.keyByteCount else {
                throw NoiseError.invalidKeyLength(
                    remoteStaticPublicKey?.count ?? 0
                )
            }
            self.remoteStaticPublicKey = remote
            symmetric.mixHash(remote)
        case .responder:
            self.remoteStaticPublicKey = nil
            symmetric.mixHash(staticKeys.publicKey)
        }
        self.symmetric = symmetric
    }

    public var isComplete: Bool { phase == .complete }

    /// The transcript hash `h`. After completion this is the handshake
    /// hash the W6 PAKE binds to (channel binding per Noise spec §11.2).
    public var handshakeHash: [UInt8] { symmetric.handshakeHash }

    // MARK: Message 1  (-> e, es, s, ss)

    /// Initiator writes message 1 carrying `payload`.
    public mutating func writeMessage1(
        payload: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard role == .initiator, phase == .awaitingMessage1 else {
            throw NoiseError.handshakeOutOfOrder
        }
        guard let remoteStatic = remoteStaticPublicKey else {
            throw NoiseError.handshakeOutOfOrder
        }
        let e = ephemeralKeys ?? .generate()
        ephemeralKeys = e

        var message = [UInt8]()
        // e
        symmetric.mixHash(e.publicKey)
        message.append(contentsOf: e.publicKey)
        // es = DH(e, rs)
        symmetric.mixKey(try NoisePrimitives.dh(
            privateKey: e.privateKey, publicKey: remoteStatic
        ))
        // s (encrypted — the initiator identity hides from passive observers)
        message.append(contentsOf: try symmetric.encryptAndHash(
            staticKeys.publicKey[...]
        ))
        // ss = DH(s, rs)
        symmetric.mixKey(try NoisePrimitives.dh(
            privateKey: staticKeys.privateKey, publicKey: remoteStatic
        ))
        // payload
        message.append(contentsOf: try symmetric.encryptAndHash(payload))

        phase = .awaitingMessage2
        return message
    }

    /// Responder reads message 1, returning its payload. On success
    /// `remoteStaticPublicKey` holds the authenticated initiator identity.
    ///
    /// TRANSACTIONAL (pre-H1 Crypto/ review): a message that fails
    /// mid-read — bad DH point, failed authentication — restores the
    /// state exactly as it was, so half-mixed transcript state can never
    /// poison a later attempt. Without this, one garbage datagram fed to
    /// a handshake that a shell retries in place would make the GENUINE
    /// message unverifiable forever after.
    public mutating func readMessage1(
        _ message: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard role == .responder, phase == .awaitingMessage1 else {
            throw NoiseError.handshakeOutOfOrder
        }
        guard message.count >= Self.message1MinimumByteCount else {
            throw NoiseError.truncatedHandshakeMessage
        }
        let savedSymmetric = symmetric
        do {
            let base = message.startIndex
            // e
            let re = Array(message[base..<base + 32])
            remoteEphemeralPublicKey = re
            symmetric.mixHash(re)
            // es = DH(s, re)
            symmetric.mixKey(try NoisePrimitives.dh(
                privateKey: staticKeys.privateKey, publicKey: re
            ))
            // s
            let rs = try symmetric.decryptAndHash(message[base + 32..<base + 80])
            guard rs.count == NoisePrimitives.keyByteCount else {
                throw NoiseError.invalidKeyLength(rs.count)
            }
            remoteStaticPublicKey = rs
            // ss = DH(s, rs)
            symmetric.mixKey(try NoisePrimitives.dh(
                privateKey: staticKeys.privateKey, publicKey: rs
            ))
            // payload
            let payload = try symmetric.decryptAndHash(message[(base + 80)...])

            phase = .awaitingMessage2
            return payload
        } catch {
            symmetric = savedSymmetric
            remoteEphemeralPublicKey = nil
            remoteStaticPublicKey = nil
            throw error
        }
    }

    // MARK: Message 2  (<- e, ee, se)

    /// Responder writes message 2 carrying `payload`; the handshake is
    /// complete afterwards.
    public mutating func writeMessage2(
        payload: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard role == .responder, phase == .awaitingMessage2 else {
            throw NoiseError.handshakeOutOfOrder
        }
        guard let re = remoteEphemeralPublicKey,
              let rs = remoteStaticPublicKey else {
            throw NoiseError.handshakeOutOfOrder
        }
        let e = ephemeralKeys ?? .generate()
        ephemeralKeys = e

        var message = [UInt8]()
        // e
        symmetric.mixHash(e.publicKey)
        message.append(contentsOf: e.publicKey)
        // ee = DH(e, re)
        symmetric.mixKey(try NoisePrimitives.dh(
            privateKey: e.privateKey, publicKey: re
        ))
        // se = DH(e, rs)
        symmetric.mixKey(try NoisePrimitives.dh(
            privateKey: e.privateKey, publicKey: rs
        ))
        // payload
        message.append(contentsOf: try symmetric.encryptAndHash(payload))

        phase = .complete
        return message
    }

    /// Initiator reads message 2, returning its payload; the handshake is
    /// complete afterwards. Transactional like `readMessage1` — this is
    /// the load-bearing case: the client retransmits ONE message 1
    /// across the retry window (0443beb's rule) and must remain able to
    /// read the REAL message 2 after hostile or mangled bytes on the
    /// same port failed a read attempt.
    public mutating func readMessage2(
        _ message: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard role == .initiator, phase == .awaitingMessage2 else {
            throw NoiseError.handshakeOutOfOrder
        }
        guard message.count >= Self.message2MinimumByteCount else {
            throw NoiseError.truncatedHandshakeMessage
        }
        guard let e = ephemeralKeys else {
            throw NoiseError.handshakeOutOfOrder
        }
        let savedSymmetric = symmetric
        let savedRemoteEphemeral = remoteEphemeralPublicKey
        do {
            let base = message.startIndex
            // e
            let re = Array(message[base..<base + 32])
            remoteEphemeralPublicKey = re
            symmetric.mixHash(re)
            // ee = DH(e, re)
            symmetric.mixKey(try NoisePrimitives.dh(
                privateKey: e.privateKey, publicKey: re
            ))
            // se = DH(s, re)
            symmetric.mixKey(try NoisePrimitives.dh(
                privateKey: staticKeys.privateKey, publicKey: re
            ))
            // payload
            let payload = try symmetric.decryptAndHash(message[(base + 32)...])

            phase = .complete
            return payload
        } catch {
            symmetric = savedSymmetric
            remoteEphemeralPublicKey = savedRemoteEphemeral
            throw error
        }
    }

    // MARK: Split

    /// Split (spec §5.2), keyed by role: `send` encrypts our outbound
    /// traffic, `receive` opens the peer's. Handshake must be complete.
    package func splitCipherStates() throws -> (
        send: NoiseCipherState, receive: NoiseCipherState
    ) {
        guard phase == .complete else {
            throw NoiseError.handshakeIncomplete
        }
        let (initiatorToResponder, responderToInitiator) = symmetric.split()
        switch role {
        case .initiator:
            return (initiatorToResponder, responderToInitiator)
        case .responder:
            return (responderToInitiator, initiatorToResponder)
        }
    }
}
