import LyteClientTestKit
import LyteTransport
import LyteWire
import LyteWireTestKit
import XCTest

/// A pairing run ends with the typed goodbye on the ordered stream, so the
/// host frees its session without waiting out an idle timeout.
final class PairingTeardownTests: XCTestCase {
    private final class PairingHostStandIn: ScriptedHost {
        var peer = SealedCtrlPeer<HostClock>()
        var handshakeOutbox: [[UInt8]] = []
        var received: [[UInt8]] = []
        var progressMark: Int { received.count }

        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            guard case .reliable(_, _, let events) =
                try peer.absorb(bytes, nowMicros: nowMicros)
            else { return }
            for case .message(_, let message) in events {
                received.append(message)
            }
        }
    }

    func testTheRunEndsWithATypedShuttingDownTeardown() throws {
        let host = PairingHostStandIn()
        let crypto = try NoiseTransportCrypto(
            hostAddress: "10.0.0.249", hostPort: 41_009,
            hostStaticPublicKey: host.staticKeys.publicKey,
            attempts: 2, attemptTimeoutMilliseconds: 200)
        try crypto.performHandshake(io: host)
        let outbound = LockedBytePile()
        let flow = try LytePairingFlow(
            crypto: crypto,
            hostStaticPublicKey: host.staticKeys.publicKey,
            pin: Array("123456".utf8),
            transmit: { outbound.append($0); return true })

        try flow.start(now: ClientTimestamp(microseconds: 1_000))
        try flow.sendTeardown(now: ClientTimestamp(microseconds: 2_000))
        for datagram in outbound.all {
            try host.absorb(datagram, nowMicros: 3_000)
        }

        XCTAssertEqual(host.received.count, 2)
        XCTAssertEqual(host.received.last,
                       SessionTeardown(reason: .shuttingDown).encode())
    }
}
