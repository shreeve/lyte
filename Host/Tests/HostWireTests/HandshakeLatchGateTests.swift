import HostCore
import HostSession
import HostWire
import LyteWire
import LyteWireTestKit
import XCTest

/// A listening host never pins its session to the first plausible
/// message 1's source. Until a handshake completes
/// the session belongs to no tuple; the message 1 that authenticates
/// names the client's path.
final class HandshakeLatchGateTests: XCTestCase {
    private static let spoofed = FourTuple(
        localAddress: "0.0.0.0", localPort: 41_151,
        remoteAddress: "10.0.0.66", remotePort: 40_000)
    private static let client = FourTuple(
        localAddress: "0.0.0.0", localPort: 41_151,
        remoteAddress: "10.0.0.23", remotePort: 61_000)

    private func ctrl(_ payload: [UInt8], seq: UInt16) throws -> [UInt8] {
        try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: payload)
    }

    private func message1(to host: NoiseKeyPair) throws -> [UInt8] {
        var client = try NoiseSession(
            role: .initiator, staticKeys: NoiseKeyPair.generate(),
            remoteStaticPublicKey: host.publicKey)
        return [CtrlMessageType.noiseHandshake1] + (try client.writeMessage1())
    }

    func testTheAuthenticatingTupleBecomesThePrimaryNotTheFirstArrival() throws {
        let host = NoiseKeyPair.generate()
        var sent: [VideoChannelDatagram] = []
        // The shell made the session on the first plausible arrival: a
        // spoofed, garbage message 1.
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: host),
                rateBitsPerSecond: 20_000_000),
            clientTuple: Self.spoofed, now: 0,
            rng: SplitMix64(seed: 0x1A7C4)
        ) { sent.append($0) }
        let garbage = [CtrlMessageType.noiseHandshake1]
            + [UInt8](repeating: 0x42, count: 96)
        _ = session.receive(
            try ctrl(garbage, seq: 1), from: Self.spoofed,
            now: 1_000, hostMicroseconds: 1)
        XCTAssertEqual(session.phase, .awaitingHandshake)

        let events = session.receive(
            try ctrl(try message1(to: host), seq: 1), from: Self.client,
            now: 2_000, hostMicroseconds: 2)
        XCTAssertTrue(events.contains { event in
            if case .handshakeCompleted = event { return true }
            return false
        })
        XCTAssertEqual(session.phase, .established)
        XCTAssertEqual(session.validator.primary.tuple, Self.client,
            "message 2 and all media go to the client that authenticated")

        var now: UInt64 = 3_000
        for _ in 0..<8 where sent.isEmpty {
            session.pump(now: now)
            now += 1_000_000
        }
        let message2 = try XCTUnwrap(sent.first)
        XCTAssertNil(message2.destination,
            "message 2 rides the primary path, now the client's")
    }

    func testOnlyHandshakeInitiationsAreLatchCandidates() throws {
        XCTAssertTrue(Session.looksLikeHandshakeInitiation(
            try ctrl([CtrlMessageType.noiseHandshake1, 1, 2, 3], seq: 1)))
        XCTAssertTrue(Session.looksLikeHandshakeInitiation(
            try ctrl([CtrlMessageType.retryHandshake1, 1, 2, 3], seq: 1)))
        XCTAssertFalse(Session.looksLikeHandshakeInitiation(
            try ctrl([CtrlMessageType.noiseHandshake2, 1], seq: 1)))
        XCTAssertFalse(Session.looksLikeHandshakeInitiation([0x00, 0x01]))
    }
}

final class PairingPinTests: XCTestCase {
    func testPinsAreSixZeroPaddedDigits() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<1_000 {
            let pin = PairingResponderService.mintPin(using: &rng)
            XCTAssertEqual(pin.count, 6)
            XCTAssertTrue(pin.allSatisfy(\.isASCII))
            XCTAssertTrue(pin.allSatisfy(\.isNumber))
        }
    }
}
