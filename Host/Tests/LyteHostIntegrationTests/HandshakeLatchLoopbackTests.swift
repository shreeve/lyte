import CNetIO
import Glibc
import HostWire
@testable import lyte_host
import LyteWire
import XCTest

/// The listening host's handshake admission end to end on loopback.
final class HandshakeLatchLoopbackTests: XCTestCase {
    /// A spoofed message 1 arrives first and a real client handshakes
    /// from another tuple: the host completes with the real client,
    /// answers it with message 2 from the session port, and commits once
    /// the client proves key possession.
    func testAHandshakeAfterASpoofedFirstArrivalStillEstablishes() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0), peer: nil,
            rateBitsPerSecond: 1_000_000)
        defer { wire.shutdown(reason: .shuttingDown, lingerSeconds: 0) }

        let spoofer = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        let client = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        spoofer.send(try LoopbackDialer.ctrl([CtrlMessageType.noiseHandshake1]
            + [UInt8](repeating: 0x42, count: 96), seq: 1))
        try client.dial()

        XCTAssertEqual(try awaitClient(
            wire, hostStatic: hostStatic, timeoutSeconds: 5
        ) {
            let reply = try XCTUnwrap(
                client.awaitMessage2(), "the real client gets message 2")
            XCTAssertEqual(reply.sourcePort, wire.localPort,
                "message 2 leaves from the session port")
            try client.confirm(message2: reply.payload)
        }, .established)
    }

    /// A replayed message 1 is answered, but an answer commits nothing:
    /// the host keeps waiting, and the real client's own message 1
    /// replaces the unconfirmed handshake instead of being locked out.
    func testAReplayedMessage1CannotLockOutTheNextClient() throws {
        let hostStatic = NoiseKeyPair.generate()
        let listener = try HostListener(port: 0)
        let port = lyte_netio_local_port(listener.netio)
        let wire = try SessionWire(
            listener: listener, peer: nil, rateBitsPerSecond: 1_000_000)
        defer { wire.shutdown(reason: .shuttingDown, lingerSeconds: 0) }

        // A message 1 observed from an earlier dial, replayed from
        // another tuple; nobody behind it holds the keys.
        let victim = try LoopbackDialer(
            port: port, hostStaticPublicKey: hostStatic.publicKey)
        try victim.writeMessage1()
        let replayer = try LoopbackDialer(
            port: port, hostStaticPublicKey: hostStatic.publicKey)
        replayer.send(victim.message1Datagram)

        let client = try LoopbackDialer(
            port: port, hostStaticPublicKey: hostStatic.publicKey)
        XCTAssertEqual(try awaitClient(
            wire, hostStatic: hostStatic, timeoutSeconds: 5
        ) {
            XCTAssertNotNil(replayer.awaitMessage2(),
                "the replay is answered — and commits nothing")
            try client.dial()
            let reply = try XCTUnwrap(client.awaitMessage2())
            try client.confirm(message2: reply.payload)
        }, .established)
        XCTAssertEqual(wire.handshakesSuperseded, 1)
    }

    /// An answer no client confirms within the client's whole retransmit
    /// span is discarded then, not held until the 30 s liveness close.
    func testAnAnswerNobodyConfirmsIsDiscardedAfterTheRetransmitSpan() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0), peer: nil,
            rateBitsPerSecond: 1_000_000)
        defer { wire.shutdown(reason: .shuttingDown, lingerSeconds: 0) }
        let replayer = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        try replayer.dial()
        let span = Double(Session.unconfirmedAnswerLifetimeNS) / 1e9
        XCTAssertThrowsError(try awaitClient(
            wire, hostStatic: hostStatic, timeoutSeconds: span + 1
        ) {
            XCTAssertNotNil(replayer.awaitMessage2(), "answered, never confirmed")
        })
        XCTAssertEqual(wire.handshakesAbandoned, 1)
    }

    /// A connect's first dial (message 1 at 0, 2, 4, 6 and 8 s) whose
    /// message 2s are all lost but the last still establishes: each
    /// verbatim retransmit is answered again, never dropped as a message
    /// 1 an abandoned session answered.
    func testAFirstDialWhoseEarlyAnswersAreLostStillEstablishes() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0), peer: nil,
            rateBitsPerSecond: 1_000_000)
        defer { wire.shutdown(reason: .shuttingDown, lingerSeconds: 0) }
        let client = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        XCTAssertEqual(try awaitClient(
            wire, hostStatic: hostStatic, timeoutSeconds: 15
        ) {
            try client.dial()
            for _ in 0..<4 {
                usleep(2_000_000)
                client.drain() // every answer so far is lost
                client.send(client.message1Datagram)
            }
            let reply = try XCTUnwrap(
                client.awaitMessage2(), "the 8 s retransmit is answered")
            try client.confirm(message2: reply.payload)
        }, .established)
        XCTAssertEqual(wire.handshakesAbandoned, 0)
    }

    /// A message 1 some session of this process already answered is
    /// dropped before any session reads it: the stale copy a client's
    /// retransmit timer left queued, or a replay of it.
    func testAMessage1AnsweredEarlierInTheProcessIsDropped() throws {
        let hostStatic = NoiseKeyPair.generate()
        let listener = try HostListener(port: 0)
        let port = lyte_netio_local_port(listener.netio)

        let first = try SessionWire(
            listener: listener, peer: nil, rateBitsPerSecond: 1_000_000)
        let client = try LoopbackDialer(
            port: port, hostStaticPublicKey: hostStatic.publicKey)
        try client.dial()
        XCTAssertEqual(try awaitClient(
            first, hostStatic: hostStatic, timeoutSeconds: 5
        ) {
            let reply = try XCTUnwrap(client.awaitMessage2())
            try client.confirm(message2: reply.payload)
        }, .established)
        first.shutdown(reason: .shuttingDown, lingerSeconds: 0)
        first.release()

        let second = try SessionWire(
            listener: listener, peer: nil, rateBitsPerSecond: 1_000_000)
        defer { second.shutdown(reason: .shuttingDown, lingerSeconds: 0) }
        usleep(50_000)
        client.drain() // session one's words, and its teardown
        client.send(client.message1Datagram)
        XCTAssertThrowsError(try second.awaitClient(
            hostStatic: hostStatic, timeoutSeconds: 0.3))
        XCTAssertNil(client.awaitMessage2(), "nothing answers it")
    }
}
