import LyteClientSession
import LyteWire
import XCTest

/// The pairing initiator's machine discipline, without a host: a host
/// reject is terminal, a dead machine stays silent, hostile bytes never
/// throw, and the run opens once.
final class ClientPairingTests: XCTestCase {
    private func pairing(pin: String) throws -> ClientPairing {
        try ClientPairing(
            pin: Array(pin.utf8),
            clientStaticPublicKey: NoiseKeyPair.generate().publicKey,
            hostStaticPublicKey: NoiseKeyPair.generate().publicKey,
            noiseHandshakeHash: [UInt8](repeating: 7, count: 32))
    }

    func testHostRejectSurfacesAndKillsTheRun() throws {
        var pairing = try pairing(pin: "111111")
        _ = try pairing.start()
        let output = try XCTUnwrap(pairing.handleReliableCtrl(
            PairingReject(reason: .confirmationFailed).encode()))
        XCTAssertEqual(output.events, [.hostRejected(.confirmationFailed)])
        XCTAssertTrue(output.replies.isEmpty)
        XCTAssertTrue(pairing.isTerminal)

        // Dead machine: a late share B draws silence, not state.
        let late = try XCTUnwrap(pairing.handleReliableCtrl(
            try PairingShareB(
                share: [UInt8](repeating: 1, count: 32),
                confirmationTag: [UInt8](repeating: 2, count: 64)
            ).encode()))
        XCTAssertTrue(late.events.isEmpty)
        XCTAssertTrue(late.replies.isEmpty)
        XCTAssertNil(pairing.pairedHostStaticPublicKey)
    }

    func testForeignAndHostileBytesNeverThrow() throws {
        var pairing = try pairing(pin: "222222")
        _ = try pairing.start()

        // Non-pairing types are not ours: nil, untouched.
        XCTAssertNil(pairing.handleReliableCtrl([0x7F, 1, 2, 3]))
        XCTAssertNil(pairing.handleReliableCtrl([]))

        // Client-role messages arriving at the client: hostile/confused.
        XCTAssertEqual(
            pairing.handleReliableCtrl(
                try PairingShareA(
                    share: [UInt8](repeating: 3, count: 32)).encode()
            )?.events,
            [.malformed])

        // A truncated share B: malformed, run still alive.
        XCTAssertEqual(
            pairing.handleReliableCtrl(
                [CtrlMessageType.pairingShareB, 0x01, 0x02])?.events,
            [.malformed])
        XCTAssertFalse(pairing.isTerminal)

        // start() is once-only.
        XCTAssertThrowsError(try pairing.start())
    }
}
