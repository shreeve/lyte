// PairingPake (W6): the CPace pairing flow that turns a short human PIN
// into pinned Noise statics without ever exposing the PIN to offline
// attack. This is the core plan's `PairingPake` — "CPace over X25519,
// transcript bound to the Noise handshake hash (adjudication §8.2);
// emits the static keys to pin (storage is shell-side)".
//
// How the composition works (the decision record's §8.2 collapse of
// "bind via TLS exporter" onto Noise):
//
// 1. First contact runs Noise IK against the DISCOVERED host static
//    (the `pkh` in the _lyte._udp TXT record) — encrypted, but trust-
//    on-first-use: nothing yet proves the static belongs to the host
//    the user is looking at.
// 2. The CPace run rides that session's sealed CTRL stream with
//    sid = the Noise handshake hash (unique per session, both
//    ephemerals hashed in) and CI = lv_cat(label, client static,
//    host static) — the exact identities about to be pinned, initiator
//    first per draft §10.1.
// 3. Explicit key confirmation (§10.4 tags, carried in the 0x0C/0x0D
//    messages) then proves BOTH ends hold the same PIN AND saw the
//    same Noise session with the same statics. A MITM terminating
//    Noise separately with each side has different handshake hashes
//    and different statics on the two legs — different generators,
//    different ISKs, confirmation fails. Wrong PIN fails the same way,
//    and the transcript (two public shares) yields nothing offline-
//    testable: recovering K from Ya/Yb is the Diffie-Hellman problem,
//    per PIN guess (the draft's "quantum-annoying" property).
// 4. On success each shell pins the statics the Noise session already
//    authenticated cryptographically — the client pins the host static
//    it dialed, the host pins the client static message 1 delivered.
//    The "static-key handover" is a promotion of keys both ends
//    already hold, not a transport of new ones; every later connect is
//    plain Noise IK against the pinned static, no PAKE, no UI.
//
// Sans-IO: consumes and produces typed pairing messages; carriage
// (sealing, ARQ, timers, retry-cookie flood control) is HS-9/CL-6
// shell territory. Randomness is the CPace scalar — injected for tests
// and vectorgen, platform CSPRNG otherwise (the NoiseSession
// fixedEphemeral pattern). The PIN is consumed at init to derive the
// generator and never retained.

/// The pairing outcome both roles expose on success: the ISK (already
/// authenticated by confirmation; hash it through a KDF if a key for a
/// higher protocol is ever needed) and the statics the shell should
/// now pin.
public struct PairingResult: Hashable, Sendable {
    /// CPace's intermediate session key, 64 bytes.
    public var intermediateSessionKey: [UInt8]
    /// The peer static Noise public key to pin: for the client role the
    /// host's static, for the host role the client's.
    public var peerStaticPublicKeyToPin: [UInt8]
}

/// Everything the pairing machine can refuse. `confirmationFailed` is
/// deliberately one case for wrong PIN and tampered binding alike —
/// distinguishing them would hand an active attacker an oracle.
public enum PairingPakeError: Error, Hashable, Sendable {
    /// A CPace scalar multiplication yielded the neutral element G.I —
    /// a low-order share (draft §7.2's MUST-abort) or a malformed one.
    case invalidPeerShare
    /// The peer's confirmation tag did not verify: wrong PIN, or the
    /// two ends did not see the same Noise session and statics.
    case confirmationFailed
    /// A method was driven out of order or after completion/failure.
    case invalidState
    /// An input had the wrong length (keys and hashes are 32 bytes,
    /// scalars 32 bytes, the PIN non-empty).
    case invalidInput
}

/// The client (initiator, CPace party A) half of the pairing flow.
/// Drive it: `makeShareA()` → send 0x0B → feed the 0x0C reply to
/// `receiveShareB(_:)` → send the returned 0x0D → `result` is set.
public struct PairingPakeInitiator: Sendable {
    private enum State {
        case awaitingShareB
        case complete
        case failed
    }

    private var state: State
    private let sid: [UInt8]
    private let scalar: [UInt8]
    private let shareA: [UInt8]
    private let hostStaticPublicKey: [UInt8]
    /// Set once the responder's confirmation tag verifies.
    public private(set) var result: PairingResult?

    /// - Parameters:
    ///   - pin: the PRS — the human-entered PIN's bytes (RFC 8265
    ///     encoding is the shell's job). Consumed here, not retained.
    ///   - clientStaticPublicKey: our Noise static public key (rides
    ///     in CI, initiator first).
    ///   - hostStaticPublicKey: the host static this Noise session
    ///     dialed — the key pairing is deciding whether to pin.
    ///   - noiseHandshakeHash: `NoiseSession.handshakeHash` of the
    ///     session carrying the pairing — the §8.2 transcript binding.
    ///   - fixedScalar: tests and vectorgen only.
    public init(
        pin: [UInt8],
        clientStaticPublicKey: [UInt8],
        hostStaticPublicKey: [UInt8],
        noiseHandshakeHash: [UInt8],
        fixedScalar: [UInt8]? = nil
    ) throws {
        let generator = try PairingPake.deriveGenerator(
            pin: pin,
            clientStaticPublicKey: clientStaticPublicKey,
            hostStaticPublicKey: hostStaticPublicKey,
            noiseHandshakeHash: noiseHandshakeHash
        )
        sid = noiseHandshakeHash
        scalar = fixedScalar ?? CPace.sampleScalar()
        guard scalar.count == CPace.elementByteCount else {
            throw PairingPakeError.invalidInput
        }
        shareA = CPace.scalarMult(scalar: scalar, element: generator)
        guard shareA != CPace.neutralElement else {
            // Unreachable with an Elligator-mapped generator; refuse
            // to put G.I on the wire regardless.
            throw PairingPakeError.invalidPeerShare
        }
        self.hostStaticPublicKey = hostStaticPublicKey
        state = .awaitingShareB
    }

    /// The 0x0B message to send. Callable until share B arrives.
    public func makeShareA() throws -> PairingShareA {
        guard state == .awaitingShareB else {
            throw PairingPakeError.invalidState
        }
        return PairingShareA(share: shareA)
    }

    /// Feeds the host's 0x0C reply: aborts on a low-order share (before
    /// any tag math — draft §7.2), verifies Tb in constant time, and on
    /// success returns the 0x0D confirm to send and sets `result`.
    public mutating func receiveShareB(
        _ message: PairingShareB
    ) throws -> PairingConfirm {
        guard state == .awaitingShareB else {
            throw PairingPakeError.invalidState
        }
        let k = CPace.scalarMultVfy(scalar: scalar, element: message.share)
        guard k != CPace.neutralElement else {
            state = .failed
            throw PairingPakeError.invalidPeerShare
        }
        let transcript = CPace.transcript(
            ya: shareA, ada: [], yb: message.share, adb: []
        )
        let isk = CPace.intermediateSessionKey(
            sid: sid, k: k, transcript: transcript
        )
        let confirmationKey = CPace.confirmationKey(sid: sid, isk: isk)
        let expectedTb = CPace.confirmationTag(
            confirmationKey: confirmationKey,
            share: message.share, associatedData: []
        )
        guard CPace.constantTimeEquals(
            expectedTb, message.confirmationTag
        ) else {
            state = .failed
            throw PairingPakeError.confirmationFailed
        }
        let ta = CPace.confirmationTag(
            confirmationKey: confirmationKey,
            share: shareA, associatedData: []
        )
        result = PairingResult(
            intermediateSessionKey: isk,
            peerStaticPublicKeyToPin: hostStaticPublicKey
        )
        state = .complete
        return PairingConfirm(confirmationTag: ta)
    }
}

/// The host (responder, CPace party B) half of the pairing flow.
/// Drive it: feed the 0x0B to `receiveShareA(_:)` → send the returned
/// 0x0C → feed the 0x0D to `receiveConfirm(_:)` → `result` is set.
public struct PairingPakeResponder: Sendable {
    private enum State {
        case awaitingShareA
        case awaitingConfirm
        case complete
        case failed
    }

    private var state: State
    private let sid: [UInt8]
    private let scalar: [UInt8]
    private let shareB: [UInt8]
    private let generator: [UInt8]
    private let clientStaticPublicKey: [UInt8]
    private var expectedTa: [UInt8] = []
    private var pendingResult: PairingResult?
    /// Set once the initiator's confirmation tag verifies.
    public private(set) var result: PairingResult?

    /// Parameter meanings mirror the initiator; `clientStaticPublicKey`
    /// here is the static message 1 of the carrying Noise session
    /// delivered — the key the host pins on success.
    public init(
        pin: [UInt8],
        clientStaticPublicKey: [UInt8],
        hostStaticPublicKey: [UInt8],
        noiseHandshakeHash: [UInt8],
        fixedScalar: [UInt8]? = nil
    ) throws {
        generator = try PairingPake.deriveGenerator(
            pin: pin,
            clientStaticPublicKey: clientStaticPublicKey,
            hostStaticPublicKey: hostStaticPublicKey,
            noiseHandshakeHash: noiseHandshakeHash
        )
        sid = noiseHandshakeHash
        scalar = fixedScalar ?? CPace.sampleScalar()
        guard scalar.count == CPace.elementByteCount else {
            throw PairingPakeError.invalidInput
        }
        shareB = CPace.scalarMult(scalar: scalar, element: generator)
        guard shareB != CPace.neutralElement else {
            throw PairingPakeError.invalidPeerShare
        }
        self.clientStaticPublicKey = clientStaticPublicKey
        state = .awaitingShareA
    }

    /// Feeds the client's 0x0B: aborts on a low-order share, derives
    /// the ISK, and returns the 0x0C reply (share B + our tag). The
    /// run is NOT complete until `receiveConfirm(_:)` verifies —
    /// `result` stays nil and nothing must be pinned yet.
    public mutating func receiveShareA(
        _ message: PairingShareA
    ) throws -> PairingShareB {
        guard state == .awaitingShareA else {
            throw PairingPakeError.invalidState
        }
        let k = CPace.scalarMultVfy(scalar: scalar, element: message.share)
        guard k != CPace.neutralElement else {
            state = .failed
            throw PairingPakeError.invalidPeerShare
        }
        let transcript = CPace.transcript(
            ya: message.share, ada: [], yb: shareB, adb: []
        )
        let isk = CPace.intermediateSessionKey(
            sid: sid, k: k, transcript: transcript
        )
        let confirmationKey = CPace.confirmationKey(sid: sid, isk: isk)
        let tb = CPace.confirmationTag(
            confirmationKey: confirmationKey,
            share: shareB, associatedData: []
        )
        expectedTa = CPace.confirmationTag(
            confirmationKey: confirmationKey,
            share: message.share, associatedData: []
        )
        pendingResult = PairingResult(
            intermediateSessionKey: isk,
            peerStaticPublicKeyToPin: clientStaticPublicKey
        )
        state = .awaitingConfirm
        return PairingShareB(share: shareB, confirmationTag: tb)
    }

    /// Feeds the client's 0x0D. On a verified tag `result` is set; on
    /// failure the derived key material is discarded — wrong PIN yields
    /// nothing offline-testable and nothing pinnable.
    public mutating func receiveConfirm(
        _ message: PairingConfirm
    ) throws {
        guard state == .awaitingConfirm else {
            throw PairingPakeError.invalidState
        }
        guard CPace.constantTimeEquals(
            expectedTa, message.confirmationTag
        ) else {
            state = .failed
            pendingResult = nil
            expectedTa = []
            throw PairingPakeError.confirmationFailed
        }
        result = pendingResult
        pendingResult = nil
        state = .complete
    }
}

/// The shared input derivations — one place computes CI and the
/// generator so the two roles can never drift.
enum PairingPake {
    /// The CI label: bump it if the CI layout ever changes shape.
    static let channelIdentifierLabel: [UInt8] =
        Array("lyte-pairing-v1".utf8)

    /// CI = lv_cat(label, client static, host static) — the identities
    /// being pinned, initiator's first (draft §10.1), kept confidential
    /// inside the generator derivation.
    static func channelIdentifier(
        clientStaticPublicKey: [UInt8], hostStaticPublicKey: [UInt8]
    ) -> [UInt8] {
        CPace.lvCat(
            channelIdentifierLabel,
            clientStaticPublicKey,
            hostStaticPublicKey
        )
    }

    static func deriveGenerator(
        pin: [UInt8],
        clientStaticPublicKey: [UInt8],
        hostStaticPublicKey: [UInt8],
        noiseHandshakeHash: [UInt8]
    ) throws -> [UInt8] {
        guard
            !pin.isEmpty,
            clientStaticPublicKey.count == CPace.elementByteCount,
            hostStaticPublicKey.count == CPace.elementByteCount,
            noiseHandshakeHash.count == 32
        else {
            throw PairingPakeError.invalidInput
        }
        return CPace.calculateGenerator(
            prs: pin,
            ci: channelIdentifier(
                clientStaticPublicKey: clientStaticPublicKey,
                hostStaticPublicKey: hostStaticPublicKey
            ),
            sid: noiseHandshakeHash
        )
    }
}
