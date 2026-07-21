import XCTest
import LyteWire
import LyteWireTestKit

// W-G6's live-handshake half: fresh-key IK handshakes succeed end to end,
// version mismatches abort loudly before any transport key exists,
// tampered or truncated handshake bytes fail authentication without
// panicking, and malformed-input fuzz never traps.

final class NoiseHandshakeTests: XCTestCase {

    private func makeSessions() throws -> (client: NoiseSession, host: NoiseSession) {
        let clientStatic = NoiseKeyPair.generate()
        let hostStatic = NoiseKeyPair.generate()
        let client = try NoiseSession(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: hostStatic.publicKey
        )
        let host = try NoiseSession(role: .responder, staticKeys: hostStatic)
        return (client, host)
    }

    // MARK: Success path

    func testFullHandshakeAndTransportRoundTrip() throws {
        var (client, host) = try makeSessions()

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
        XCTAssertEqual(client.negotiatedVersion, WireVersion.major)
        XCTAssertEqual(host.negotiatedVersion, WireVersion.major)

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
        // The W6 hook: both ends expose the same 32-byte transcript hash,
        // it is stable across makeTransport, and it differs per session
        // (fresh ephemerals) — exactly what CPace needs to bind to.
        var (client, host) = try makeSessions()
        _ = try host.readMessage1(try client.writeMessage1()[...])
        _ = try client.readMessage2(try host.writeMessage2()[...])

        XCTAssertEqual(client.handshakeHash.count, 32)
        XCTAssertEqual(client.handshakeHash, host.handshakeHash)
        XCTAssertEqual(try client.makeTransport().handshakeHash, client.handshakeHash)
        XCTAssertEqual(try host.makeTransport().handshakeHash, host.handshakeHash)

        var (client2, host2) = try makeSessions()
        _ = try host2.readMessage1(try client2.writeMessage1()[...])
        _ = try client2.readMessage2(try host2.writeMessage2()[...])
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
        XCTAssertThrowsError(try host.readMessage1(message1[...])) { error in
            XCTAssertEqual(
                error as? NoiseError,
                .versionMismatch(
                    received: WireVersion.major + 1, expected: WireVersion.major
                )
            )
        }
        XCTAssertNil(host.negotiatedVersion)
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
        XCTAssertThrowsError(try client.readMessage2(message2[...])) { error in
            XCTAssertEqual(
                error as? NoiseError,
                .versionMismatch(received: 0, expected: WireVersion.major)
            )
        }
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
        XCTAssertThrowsError(try host.readMessage1(message1[...])) { error in
            XCTAssertEqual(error as? NoiseError, .missingVersionPayload)
        }
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
        XCTAssertThrowsError(try host.readMessage1(message1[...])) { error in
            XCTAssertEqual(error as? NoiseError, .authenticationFailure)
        }
    }

    func testTamperedMessage1FailsEverywhere() throws {
        var (client, host) = try makeSessions()
        let message1 = try client.writeMessage1()
        // Flip one bit in every byte position class: the ephemeral, the
        // encrypted static, and the encrypted payload.
        for index in [0, 16, 33, 60, message1.count - 1] {
            var tampered = message1
            tampered[index] ^= 0x01
            var freshHost = host
            XCTAssertThrowsError(
                try freshHost.readMessage1(tampered[...]),
                "byte \(index)"
            ) { error in
                XCTAssertEqual(
                    error as? NoiseError, .authenticationFailure, "byte \(index)"
                )
            }
        }
        // The untampered original still works on the real host.
        XCTAssertNoThrow(try host.readMessage1(message1[...]))
    }

    func testTamperedMessage2Fails() throws {
        var (client, host) = try makeSessions()
        _ = try host.readMessage1(try client.writeMessage1()[...])
        let message2 = try host.writeMessage2()
        for index in [0, 31, 32, message2.count - 1] {
            var tampered = message2
            tampered[index] ^= 0x80
            var freshClient = client
            XCTAssertThrowsError(
                try freshClient.readMessage2(tampered[...]),
                "byte \(index)"
            ) { error in
                XCTAssertEqual(
                    error as? NoiseError, .authenticationFailure, "byte \(index)"
                )
            }
        }
        XCTAssertNoThrow(try client.readMessage2(message2[...]))
    }

    // MARK: Malformed input never panics

    func testTruncatedAndHostileHandshakeBytesNeverTrap() throws {
        var (client, host) = try makeSessions()
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
        var (client, host) = try makeSessions()
        // Responder writing first, double-write, reuse after completion —
        // all handshakeOutOfOrder, never a trap.
        var hostCopy = host
        XCTAssertThrowsError(try hostCopy.writeMessage2()) { error in
            XCTAssertEqual(error as? NoiseError, .handshakeOutOfOrder)
        }
        let message1 = try client.writeMessage1()
        var clientCopy = client
        XCTAssertThrowsError(try clientCopy.writeMessage1()) { error in
            XCTAssertEqual(error as? NoiseError, .handshakeOutOfOrder)
        }
        _ = try host.readMessage1(message1[...])
        let message2 = try host.writeMessage2()
        _ = try client.readMessage2(message2[...])
        XCTAssertThrowsError(try client.readMessage2(message2[...])) { error in
            XCTAssertEqual(error as? NoiseError, .handshakeOutOfOrder)
        }
    }

    func testMakeTransportBeforeCompletionThrows() throws {
        let (client, _) = try makeSessions()
        XCTAssertThrowsError(try client.makeTransport()) { error in
            XCTAssertEqual(error as? NoiseError, .handshakeIncomplete)
        }
    }
}
