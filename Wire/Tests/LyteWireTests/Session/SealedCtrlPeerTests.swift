import XCTest
import LyteWire
import LyteWireTestKit

// The gate suites' shared fake peer, checked against itself: an initiator
// and a responder complete Noise IK, carry reliable CTRL both ways, tag the
// host role's datagrams with its conn-id, and classify replays as routine.

final class SealedCtrlPeerTests: XCTestCase {
    func testInitiatorAndResponderCarryReliableCtrlBothWays() throws {
        var rng = SplitMix64(seed: 0x5EA1)
        let connectionId = ConnectionId.random(using: &rng)
        var host = SealedCtrlPeer<HostClock>(connectionId: connectionId)
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.staticKeys.publicKey)

        let message1 = try client.message1Datagram(timestamp: 500)
        let message2 = try XCTUnwrap(host.answerMessage1(message1))
        XCTAssertTrue(host.isEstablished)
        guard case .handshakeCompleted = try client.absorb(message2, nowMicros: 600)
        else { return XCTFail("message 2 must complete the handshake") }
        XCTAssertEqual(
            try ConnectionId.decode(extensions: Envelope.decode(message2).0.extensions),
            connectionId, "the host role tags even bare message 2")

        try client.declare(.wireDefault, as: .client, nowMicros: 1_000)
        try host.declare(.wireDefault, as: .host, nowMicros: 1_000)
        try host.send([CtrlMessageType.clipboardAnnounce, 0x01], nowMicros: 1_000)

        var t: UInt64 = 1_000
        var agreed: Capabilities?
        for _ in 0..<10 {
            t += 2_000
            for datagram in try client.pollOut(nowMicros: t) {
                XCTAssertNil(try ConnectionId.decode(
                    extensions: Envelope.decode(datagram).0.extensions))
                try host.absorb(datagram, nowMicros: t)
            }
            for (_, bytes) in host.received
            where bytes.first == CtrlMessageType.capabilityDeclaration {
                agreed = try host.receiveDeclaration(bytes)
            }
            host.received.removeAll()
            for datagram in try host.pollOut(nowMicros: t) {
                try client.absorb(datagram, nowMicros: t)
            }
        }
        XCTAssertEqual(agreed, Capabilities.wireDefault)
        XCTAssertEqual(
            client.take(type: CtrlMessageType.capabilityDeclaration).count, 1)
        XCTAssertEqual(
            client.take(type: CtrlMessageType.clipboardAnnounce),
            [[CtrlMessageType.clipboardAnnounce, 0x01]])
        XCTAssertTrue(client.received.isEmpty)
        XCTAssertTrue(client.arq.isQuiescent)
        XCTAssertTrue(host.arq.isQuiescent)
    }

    func testReplaysAreDuplicatesAndPlainCtrlIsSurfaced() throws {
        var host = SealedCtrlPeer<HostClock>()
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.staticKeys.publicKey)
        let message2 = try XCTUnwrap(host.answerMessage1(
            client.message1Datagram(timestamp: 0)))
        try client.absorb(message2, nowMicros: 0)

        let beacon = try host.datagram(
            body: [CtrlMessageType.clockBeacon, 0xAA], timestamp: 10)
        guard case .plain(let envelope, let plaintext) =
            try client.absorb(beacon, nowMicros: 10)
        else { return XCTFail("a non-ARQ CTRL word is surfaced plain") }
        XCTAssertEqual(envelope.channel, .ctrl)
        XCTAssertEqual(plaintext, [CtrlMessageType.clockBeacon, 0xAA])
        guard case .duplicate = try client.absorb(beacon, nowMicros: 11)
        else { return XCTFail("a replay is a routine duplicate") }

        client.openChannels = [.ctrl]
        let audio = try host.datagram(channel: .audio, body: [1], timestamp: 12)
        guard case .unopened(let skipped) = try client.absorb(audio, nowMicros: 12)
        else { return XCTFail("channels outside openChannels stay sealed") }
        XCTAssertEqual(skipped.channel, .audio)
        XCTAssertEqual(host.nextSeq(on: .ctrl), 2)
        XCTAssertEqual(host.nextSeq(on: .audio), 1)
    }
}
