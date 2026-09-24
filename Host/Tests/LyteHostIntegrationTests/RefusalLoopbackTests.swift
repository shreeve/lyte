import Foundation
import Glibc
@testable import lyte_host
import LyteWire
import XCTest

/// ICMP port-unreachable is unauthenticated: it may only corroborate
/// what the session's own authenticated silence already says.
final class RefusalLoopbackTests: XCTestCase {
    func testARefusalEndsOnlyASessionWhosePathIsAlreadySilent() {
        XCTAssertTrue(SessionWire.refusalEndsSession(lifecycle: .frozen))
        for live: SessionState? in [.active, .idle, .recovery, .closed, nil] {
            XCTAssertFalse(SessionWire.refusalEndsSession(lifecycle: live),
                "\(String(describing: live))")
        }
    }

    /// A client that exits without a teardown (the pairing client
    /// always does) still ends the session within a couple of seconds,
    /// not at the 30 s liveness close.
    func testAClientThatExitsEndsTheSessionOnceItsPathGoesSilent() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0), peer: nil,
            rateBitsPerSecond: 1_000_000)
        defer { wire.shutdown(reason: .shuttingDown, lingerSeconds: 0) }

        var client: LoopbackDialer? = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        try client?.dial()
        XCTAssertEqual(try awaitClient(
            wire, hostStatic: hostStatic, timeoutSeconds: 5
        ) {
            let reply = try XCTUnwrap(client?.awaitMessage2())
            try client?.confirm(message2: reply.payload)
        }, .established)

        client = nil // the socket closes; the port answers ICMP now
        let deadline = Date().addingTimeInterval(5)
        while !wire.takeLegSnapshot().ended, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertTrue(wire.takeLegSnapshot().ended)
        XCTAssertTrue(wire.peerGone, "ended by the corroborated refusal")
    }
}
