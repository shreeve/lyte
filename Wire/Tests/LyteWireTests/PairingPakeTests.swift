import XCTest
import LyteWire
import LyteWireTestKit

// The W-G7 gate legs for PairingPake: a full pairing run derives one
// ISK on both ends; wrong PIN aborts cleanly with nothing pinnable and
// nothing offline-testable; the transcript binding (tampered Noise
// handshake hash, swapped statics) fails the same way; low-order
// shares abort before any tag math; the state machines refuse misuse.

final class PairingPakeTests: XCTestCase {

    private static let pin = Array("482913".utf8)
    private static let clientStatic = (0..<32).map { UInt8(0x10 + $0) }
    private static let hostStatic = (0..<32).map { UInt8(0x30 + $0) }
    private static let handshakeHash = (0..<32).map { UInt8(0x50 + $0) }

    private func makePair(
        initiatorPin: [UInt8] = pin,
        responderPin: [UInt8] = pin,
        initiatorHash: [UInt8] = handshakeHash,
        responderHash: [UInt8] = handshakeHash,
        responderClientStatic: [UInt8] = clientStatic
    ) throws -> (PairingPakeInitiator, PairingPakeResponder) {
        let initiator = try PairingPakeInitiator(
            pin: initiatorPin,
            clientStaticPublicKey: Self.clientStatic,
            hostStaticPublicKey: Self.hostStatic,
            noiseHandshakeHash: initiatorHash
        )
        let responder = try PairingPakeResponder(
            pin: responderPin,
            clientStaticPublicKey: responderClientStatic,
            hostStaticPublicKey: Self.hostStatic,
            noiseHandshakeHash: responderHash
        )
        return (initiator, responder)
    }

    // MARK: The happy path

    func testFullPairingRunAgreesOnIskAndPins() throws {
        var (initiator, responder) = try makePair()
        // Byte round trips through the codecs, the way HS-9/CL-6 will
        // actually carry the messages.
        let shareA = try PairingShareA.decode(
            try initiator.makeShareA().encode()
        )
        let shareB = try PairingShareB.decode(
            try responder.receiveShareA(shareA).encode()
        )
        XCTAssertNil(
            responder.result,
            "the responder must not report success before the confirm"
        )
        let confirm = try PairingConfirm.decode(
            try initiator.receiveShareB(shareB).encode()
        )
        try responder.receiveConfirm(confirm)

        let initiatorResult = try XCTUnwrap(initiator.result)
        let responderResult = try XCTUnwrap(responder.result)
        XCTAssertEqual(
            initiatorResult.intermediateSessionKey,
            responderResult.intermediateSessionKey,
            "both ends must derive the same ISK"
        )
        XCTAssertEqual(
            initiatorResult.intermediateSessionKey.count,
            CPace.iskByteCount
        )
        // The handover: each end pins the OTHER side's Noise static.
        XCTAssertEqual(
            initiatorResult.peerStaticPublicKeyToPin, Self.hostStatic
        )
        XCTAssertEqual(
            responderResult.peerStaticPublicKeyToPin, Self.clientStatic
        )
    }

    func testDistinctSessionsDeriveDistinctIsks() throws {
        // Same PIN, same statics, two Noise sessions (different
        // handshake hashes) → different ISKs: sid does its job.
        func run(hash: [UInt8]) throws -> [UInt8] {
            var initiator = try PairingPakeInitiator(
                pin: Self.pin,
                clientStaticPublicKey: Self.clientStatic,
                hostStaticPublicKey: Self.hostStatic,
                noiseHandshakeHash: hash
            )
            var responder = try PairingPakeResponder(
                pin: Self.pin,
                clientStaticPublicKey: Self.clientStatic,
                hostStaticPublicKey: Self.hostStatic,
                noiseHandshakeHash: hash
            )
            let shareB = try responder.receiveShareA(
                initiator.makeShareA()
            )
            let confirm = try initiator.receiveShareB(shareB)
            try responder.receiveConfirm(confirm)
            return try XCTUnwrap(initiator.result).intermediateSessionKey
        }
        let hashOne = (0..<32).map { UInt8($0) }
        let hashTwo = (0..<32).map { UInt8($0 + 1) }
        XCTAssertNotEqual(try run(hash: hashOne), try run(hash: hashTwo))
    }

    // MARK: Wrong PIN — the offline-attack gate leg

    func testWrongPinFailsAtTheInitiator() throws {
        var (initiator, responder) = try makePair(
            responderPin: Array("482914".utf8)
        )
        let shareB = try responder.receiveShareA(
            initiator.makeShareA()
        )
        XCTAssertThrowsError(
            try initiator.receiveShareB(shareB)
        ) { error in
            XCTAssertEqual(
                error as? PairingPakeError, .confirmationFailed
            )
        }
        XCTAssertNil(initiator.result, "a failed run must expose no key")
        // The machine is dead after failure — no retry with the same
        // scalars, which would let an attacker test PINs one by one
        // against a single transcript.
        XCTAssertThrowsError(try initiator.receiveShareB(shareB)) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidState)
        }
    }

    func testWrongPinFailsAtTheResponder() throws {
        var (initiator, responder) = try makePair(
            responderPin: Array("000000".utf8)
        )
        let shareB = try responder.receiveShareA(
            initiator.makeShareA()
        )
        // The initiator refuses first (Tb is wrong for it)…
        XCTAssertThrowsError(try initiator.receiveShareB(shareB))
        // …and a forged confirm cannot rescue the responder side: only
        // the true Ta (derived from the PIN it doesn't share) verifies.
        let forged = PairingConfirm(
            confirmationTag: [UInt8](
                repeating: 0xAB, count: CPace.tagByteCount
            )
        )
        XCTAssertThrowsError(
            try responder.receiveConfirm(forged)
        ) { error in
            XCTAssertEqual(
                error as? PairingPakeError, .confirmationFailed
            )
        }
        XCTAssertNil(responder.result)
        XCTAssertThrowsError(try responder.receiveConfirm(forged)) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidState)
        }
    }

    // MARK: Transcript binding — the §8.2 negative tests

    func testTamperedHandshakeHashFails() throws {
        // Same PIN both ends, but the two ends saw different Noise
        // sessions — the MITM shape. Must fail exactly like wrong PIN.
        var tamperedHash = Self.handshakeHash
        tamperedHash[0] ^= 0x01
        var (initiator, responder) = try makePair(
            responderHash: tamperedHash
        )
        let shareB = try responder.receiveShareA(
            initiator.makeShareA()
        )
        XCTAssertThrowsError(
            try initiator.receiveShareB(shareB)
        ) { error in
            XCTAssertEqual(
                error as? PairingPakeError, .confirmationFailed
            )
        }
        XCTAssertNil(initiator.result)
    }

    func testMismatchedStaticsFail() throws {
        // The host believes a different client static than the client
        // holds — CI diverges, the generator diverges, pairing fails.
        var otherClientStatic = Self.clientStatic
        otherClientStatic[31] ^= 0xFF
        var (initiator, responder) = try makePair(
            responderClientStatic: otherClientStatic
        )
        let shareB = try responder.receiveShareA(
            initiator.makeShareA()
        )
        XCTAssertThrowsError(
            try initiator.receiveShareB(shareB)
        ) { error in
            XCTAssertEqual(
                error as? PairingPakeError, .confirmationFailed
            )
        }
    }

    // MARK: Low-order shares — draft §7.2's MUST-abort

    func testLowOrderShareAbortsBothRoles() throws {
        // u0 (the neutral element itself) and u3 (a low-order point on
        // the curve) from the draft's B.1.10 table, injected as the
        // peer's share: scalar_mult_vfy yields G.I and the run aborts
        // BEFORE any confirmation-tag math.
        let lowOrderShares = [
            [UInt8](repeating: 0, count: 32),
            Hex.bytes(
                "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"
            )!,
        ]
        for share in lowOrderShares {
            var (initiator, responder) = try makePair()
            // Into the responder as share A…
            XCTAssertThrowsError(
                try responder.receiveShareA(PairingShareA(share: share))
            ) { error in
                XCTAssertEqual(
                    error as? PairingPakeError, .invalidPeerShare
                )
            }
            // …and into the initiator as share B (any tag: the abort
            // must fire before the tag is even looked at).
            _ = try initiator.makeShareA()
            XCTAssertThrowsError(
                try initiator.receiveShareB(PairingShareB(
                    share: share,
                    confirmationTag: [UInt8](
                        repeating: 0, count: CPace.tagByteCount
                    )
                ))
            ) { error in
                XCTAssertEqual(
                    error as? PairingPakeError, .invalidPeerShare
                )
            }
            XCTAssertNil(initiator.result)
            XCTAssertNil(responder.result)
        }
    }

    // MARK: State and input discipline

    func testStateMachineRefusesMisuse() throws {
        var (initiator, responder) = try makePair()
        // Confirm before share A.
        XCTAssertThrowsError(
            try responder.receiveConfirm(PairingConfirm(
                confirmationTag: [UInt8](
                    repeating: 0, count: CPace.tagByteCount
                )
            ))
        ) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidState)
        }
        // A second share A after the first.
        let shareA = try initiator.makeShareA()
        _ = try responder.receiveShareA(shareA)
        XCTAssertThrowsError(try responder.receiveShareA(shareA)) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidState)
        }
        // A completed initiator refuses another share B.
        var (initiator2, responder2) = try makePair()
        let shareB2 = try responder2.receiveShareA(
            initiator2.makeShareA()
        )
        _ = try initiator2.receiveShareB(shareB2)
        XCTAssertThrowsError(try initiator2.receiveShareB(shareB2)) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidState)
        }
    }

    func testInvalidInputsReject() {
        // Empty PIN.
        XCTAssertThrowsError(
            try PairingPakeInitiator(
                pin: [],
                clientStaticPublicKey: Self.clientStatic,
                hostStaticPublicKey: Self.hostStatic,
                noiseHandshakeHash: Self.handshakeHash
            )
        ) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidInput)
        }
        // Mis-sized static.
        XCTAssertThrowsError(
            try PairingPakeResponder(
                pin: Self.pin,
                clientStaticPublicKey: [1, 2, 3],
                hostStaticPublicKey: Self.hostStatic,
                noiseHandshakeHash: Self.handshakeHash
            )
        ) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidInput)
        }
        // Mis-sized handshake hash.
        XCTAssertThrowsError(
            try PairingPakeInitiator(
                pin: Self.pin,
                clientStaticPublicKey: Self.clientStatic,
                hostStaticPublicKey: Self.hostStatic,
                noiseHandshakeHash: [0xAA]
            )
        ) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidInput)
        }
        // Mis-sized injected scalar.
        XCTAssertThrowsError(
            try PairingPakeInitiator(
                pin: Self.pin,
                clientStaticPublicKey: Self.clientStatic,
                hostStaticPublicKey: Self.hostStatic,
                noiseHandshakeHash: Self.handshakeHash,
                fixedScalar: [1, 2, 3]
            )
        ) {
            XCTAssertEqual($0 as? PairingPakeError, .invalidInput)
        }
    }

    // MARK: Composition with the real Noise handshake

    func testPairingBoundToARealNoiseSession() throws {
        // The full W6 story in one test: a real IK handshake (TOFU
        // statics), then pairing bound to its handshake hash; both ends
        // pin the statics the session actually used.
        let clientStatic = NoiseKeyPair.generate()
        let hostStatic = NoiseKeyPair.generate()
        var clientSession = try NoiseSession(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: hostStatic.publicKey
        )
        var hostSession = try NoiseSession(
            role: .responder, staticKeys: hostStatic
        )
        let message1 = try clientSession.writeMessage1()
        _ = try hostSession.readMessage1(message1[...])
        let message2 = try hostSession.writeMessage2()
        _ = try clientSession.readMessage2(message2[...])
        XCTAssertEqual(
            clientSession.handshakeHash, hostSession.handshakeHash
        )

        let pin = Array("735During".utf8)
        var initiator = try PairingPakeInitiator(
            pin: pin,
            clientStaticPublicKey: clientStatic.publicKey,
            hostStaticPublicKey: try XCTUnwrap(
                clientSession.remoteStaticPublicKey
            ),
            noiseHandshakeHash: clientSession.handshakeHash
        )
        var responder = try PairingPakeResponder(
            pin: pin,
            clientStaticPublicKey: try XCTUnwrap(
                hostSession.remoteStaticPublicKey
            ),
            hostStaticPublicKey: hostStatic.publicKey,
            noiseHandshakeHash: hostSession.handshakeHash
        )
        let shareB = try responder.receiveShareA(
            initiator.makeShareA()
        )
        let confirm = try initiator.receiveShareB(shareB)
        try responder.receiveConfirm(confirm)
        XCTAssertEqual(
            try XCTUnwrap(initiator.result).peerStaticPublicKeyToPin,
            hostStatic.publicKey
        )
        XCTAssertEqual(
            try XCTUnwrap(responder.result).peerStaticPublicKeyToPin,
            clientStatic.publicKey
        )
        XCTAssertEqual(
            try XCTUnwrap(initiator.result).intermediateSessionKey,
            try XCTUnwrap(responder.result).intermediateSessionKey
        )
    }
}
