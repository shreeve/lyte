import XCTest
import LyteCore
import LyteWire
import LyteWireTestKit

// The live handshake: fresh-key IK handshakes succeed end to end,
// version mismatches abort loudly before any transport key exists,
// tampered or truncated handshake bytes fail authentication without
// panicking or poisoning the session, and malformed input never traps.

final class NoiseHandshakeTests: XCTestCase {

    // MARK: Success path

    func testFullHandshakeAndTransportRoundTrip() throws {
        var (client, host) = try NoisePair.sessions()

        let message1 = try client.writeMessage1(
            applicationPayload: Array("hello".utf8)[...]
        )
        XCTAssertEqual(try host.readMessage1(message1[...]), Array("hello".utf8))
        let message2 = try host.writeMessage2(
            applicationPayload: Array("welcome".utf8)[...]
        )
        XCTAssertEqual(try client.readMessage2(message2[...]), Array("welcome".utf8))

        XCTAssertTrue(client.isComplete)
        XCTAssertTrue(host.isComplete)

        // Mutual authentication artifacts: each end holds the other's
        // static, ready to check against the paired set.
        XCTAssertNotNil(host.remoteStaticPublicKey)
        XCTAssertNotNil(client.remoteStaticPublicKey)

        var clientTransport = try client.makeTransport()
        var hostTransport = try host.makeTransport()

        let envelope = Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: 42,
            fec: 0
        )
        let aad = try envelope.encode(payload: [])
        let plaintext = Array("first authenticated bytes".utf8)
        let sealed = try clientTransport.seal(
            plaintext: plaintext[...], aad: aad[...], envelope: envelope
        )
        XCTAssertEqual(
            try hostTransport.unseal(
                wirePayload: sealed[...], aad: aad[...], envelope: envelope
            ),
            plaintext
        )
    }

    func testHandshakeHashHookForPake() throws {
        // The pairing hook: both ends expose the same 32-byte transcript hash,
        // it is stable across makeTransport, and it differs per session
        // (fresh ephemerals) — exactly what CPace needs to bind to.
        var (client, host) = try NoisePair.sessions()
        try NoisePair.complete(&client, &host)

        XCTAssertEqual(client.handshakeHash.count, 32)
        XCTAssertEqual(client.handshakeHash, host.handshakeHash)
        XCTAssertEqual(try client.makeTransport().handshakeHash, client.handshakeHash)
        XCTAssertEqual(try host.makeTransport().handshakeHash, host.handshakeHash)

        var (client2, host2) = try NoisePair.sessions()
        try NoisePair.complete(&client2, &host2)
        XCTAssertNotEqual(client.handshakeHash, client2.handshakeHash)
    }

    // MARK: Version negotiation (Lyte-UDP decision §8.3)

    func testVersionMismatchRejectedByResponder() throws {
        // A future/foreign client speaking wire major 2: build message 1
        // through the raw handshake with a version byte we don't speak.
        let clientStatic = NoiseKeyPair.generate()
        let hostStatic = NoiseKeyPair.generate()
        var rawClient = try NoiseHandshake(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: hostStatic.publicKey
        )
        let message1 = try rawClient.writeMessage1(payload: [WireVersion.major + 1][...])

        var host = try NoiseSession(role: .responder, staticKeys: hostStatic)
        assertThrows(
            NoiseError.versionMismatch( received: WireVersion.major + 1, expected: WireVersion.major )
        ) {
            try host.readMessage1(message1[...])
        }
        // The rejected message left no trace: the responder cannot
        // answer it or derive keys from it, and a genuine message 1
        // still completes.
        XCTAssertThrowsError(try host.writeMessage2())
        XCTAssertThrowsError(try host.makeTransport())
        var client = try NoiseSession(
            role: .initiator, staticKeys: clientStatic,
            remoteStaticPublicKey: hostStatic.publicKey
        )
        try NoisePair.complete(&client, &host)
        XCTAssertEqual(try client.makeTransport().handshakeHash,
                       try host.makeTransport().handshakeHash)
    }

    func testVersionMismatchRejectedByInitiator() throws {
        let clientStatic = NoiseKeyPair.generate()
        let hostStatic = NoiseKeyPair.generate()
        var client = try NoiseSession(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: hostStatic.publicKey
        )
        var rawHost = try NoiseHandshake(role: .responder, staticKeys: hostStatic)
        _ = try rawHost.readMessage1(try client.writeMessage1()[...])
        // Version byte only travels — but wrong.
        let message2 = try rawHost.writeMessage2(payload: [0][...])
        assertThrows(
            NoiseError.versionMismatch(received: 0, expected: WireVersion.major)
        ) {
            try client.readMessage2(message2[...])
        }
        // Keys never exist for a mismatched answer.
        XCTAssertFalse(client.isComplete)
        XCTAssertThrowsError(try client.makeTransport())
    }

    func testEmptyFirstPayloadRejected() throws {
        let clientStatic = NoiseKeyPair.generate()
        let hostStatic = NoiseKeyPair.generate()
        var rawClient = try NoiseHandshake(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: hostStatic.publicKey
        )
        let message1 = try rawClient.writeMessage1(payload: [][...])
        var host = try NoiseSession(role: .responder, staticKeys: hostStatic)
        assertThrows(NoiseError.missingVersionPayload) {
            try host.readMessage1(message1[...])
        }
    }

    // MARK: Low-order ephemerals

    /// X25519's low-order u-coordinates (and their non-canonical
    /// encodings p−1, p, p+1): a DH with any of them yields the all-zero
    /// secret.
    private static let lowOrderPoints: [[UInt8]] = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    ].map { Hex.bytes($0)! }

    /// A low-order `e` in message 1 aborts with invalidPublicKey and
    /// leaves the responder able to take a genuine message 1.
    func testLowOrderInitiatorEphemeralRejectedAndRetryable() throws {
        var (client, host) = try NoisePair.sessions()
        let genuine = try client.writeMessage1()
        for point in Self.lowOrderPoints {
            let forged = point + genuine.dropFirst(32)
            assertThrows(NoiseError.invalidPublicKey) {
                try host.readMessage1(forged[...])
            }
        }
        _ = try host.readMessage1(genuine[...])
        _ = try client.readMessage2(try host.writeMessage2()[...])
        XCTAssertTrue(client.isComplete)
    }

    /// A low-order `e` in message 2 aborts with invalidPublicKey and
    /// leaves the initiator able to take the genuine message 2.
    func testLowOrderResponderEphemeralRejectedAndRetryable() throws {
        var (client, host) = try NoisePair.sessions()
        _ = try host.readMessage1(try client.writeMessage1()[...])
        let genuine = try host.writeMessage2()
        for point in Self.lowOrderPoints {
            let forged = point + genuine.dropFirst(32)
            assertThrows(NoiseError.invalidPublicKey) {
                try client.readMessage2(forged[...])
            }
            XCTAssertFalse(client.isComplete)
        }
        _ = try client.readMessage2(genuine[...])
        XCTAssertEqual(try client.makeTransport().handshakeHash,
                       try host.makeTransport().handshakeHash)
    }

    // MARK: Authentication failures

    func testWrongPinnedStaticFailsMessage1() throws {
        // Initiator pins a key that is NOT the responder's — a rogue
        // host cannot complete message 1.
        let clientStatic = NoiseKeyPair.generate()
        let realHost = NoiseKeyPair.generate()
        let pinnedButWrong = NoiseKeyPair.generate()
        var client = try NoiseSession(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: pinnedButWrong.publicKey
        )
        var host = try NoiseSession(role: .responder, staticKeys: realHost)
        let message1 = try client.writeMessage1()
        assertThrows(NoiseError.authenticationFailure) {
            try host.readMessage1(message1[...])
        }
    }

    /// A failed read is transactional: every tampered message 1 fails on
    /// the SAME responder, which still takes the genuine one afterwards.
    func testTamperedMessage1FailsAndLeavesResponderRetryable() throws {
        var (client, host) = try NoisePair.sessions()
        let message1 = try client.writeMessage1(
            applicationPayload: Array("real".utf8)[...]
        )
        // Flip one bit in every byte position class: the ephemeral, the
        // encrypted static, and the encrypted payload.
        for index in [0, 16, 33, 40, 60, message1.count - 1] {
            var tampered = message1
            tampered[index] ^= 0x01
            assertThrows(NoiseError.authenticationFailure, "byte \(index)") {
                try host.readMessage1(tampered[...])
            }
            XCTAssertNil(host.remoteStaticPublicKey, "byte \(index)")
        }
        XCTAssertEqual(
            try host.readMessage1(message1[...]), Array("real".utf8)
        )
        _ = try client.readMessage2(try host.writeMessage2()[...])
        XCTAssertEqual(client.handshakeHash, host.handshakeHash)
    }

    /// The initiator retransmits one message 1 across the retry window,
    /// so tampered answers and garbage on the port must leave the SAME
    /// initiator able to read the genuine message 2.
    func testTamperedMessage2FailsAndLeavesInitiatorRetryable() throws {
        var (client, host) = try NoisePair.sessions()
        _ = try host.readMessage1(try client.writeMessage1()[...])
        let message2 = try host.writeMessage2()
        for index in [0, 31, 32, message2.count - 1] {
            var tampered = message2
            tampered[index] ^= 0x80
            assertThrows(NoiseError.authenticationFailure, "byte \(index)") {
                try client.readMessage2(tampered[...])
            }
        }
        var rng = SplitMix64(seed: 0xBAD2)
        XCTAssertThrowsError(try client.readMessage2(rng.bytes(48)[...]))

        XCTAssertNoThrow(try client.readMessage2(message2[...]))
        XCTAssertEqual(client.handshakeHash, host.handshakeHash)
        var up = try client.makeTransport()
        var down = try host.makeTransport()
        let envelope = Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 7, fec: 0
        )
        XCTAssertEqual(
            try down.openDatagram(up.sealDatagram(envelope, plaintext: [1, 2, 3]))
                .plaintext,
            [1, 2, 3]
        )
    }

    // MARK: Malformed input never panics

    func testTruncatedAndHostileHandshakeBytesNeverTrap() throws {
        var (client, host) = try NoisePair.sessions()
        let message1 = try client.writeMessage1()

        // Every truncation of a real message 1.
        for length in 0..<message1.count {
            var freshHost = host
            XCTAssertThrowsError(
                try freshHost.readMessage1(message1[0..<length]),
                "truncation to \(length)"
            )
        }
        // Seeded garbage at assorted lengths, including the exact minimum.
        var rng = SplitMix64(seed: 0x57_47_36_25)
        for length in [0, 1, 31, 32, 95, 96, 97, 256, 1152] {
            let garbage = (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            var freshHost = host
            XCTAssertThrowsError(try freshHost.readMessage1(garbage[...]))
        }

        // Same for message 2 against the initiator.
        _ = try host.readMessage1(message1[...])
        let message2 = try host.writeMessage2()
        for length in 0..<message2.count {
            var freshClient = client
            XCTAssertThrowsError(try freshClient.readMessage2(message2[0..<length]))
        }
    }

    func testOutOfOrderDrivingThrows() throws {
        var (client, host) = try NoisePair.sessions()
        // Responder writing first, double-write, reuse after completion —
        // all handshakeOutOfOrder, never a trap.
        var hostCopy = host
        assertThrows(NoiseError.handshakeOutOfOrder) {
            try hostCopy.writeMessage2()
        }
        let message1 = try client.writeMessage1()
        var clientCopy = client
        assertThrows(NoiseError.handshakeOutOfOrder) {
            try clientCopy.writeMessage1()
        }
        _ = try host.readMessage1(message1[...])
        let message2 = try host.writeMessage2()
        _ = try client.readMessage2(message2[...])
        assertThrows(NoiseError.handshakeOutOfOrder) {
            try client.readMessage2(message2[...])
        }
    }

    func testMakeTransportBeforeCompletionThrows() throws {
        let (client, _) = try NoisePair.sessions()
        assertThrows(NoiseError.handshakeIncomplete) {
            try client.makeTransport()
        }
    }
}
