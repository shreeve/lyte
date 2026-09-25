import Foundation
@testable import lyte_host
import LyteWire
import XCTest

/// Between sessions the listener sleeps on its socket: its idle pass
/// (clipboard and Avahi service) runs at the janitor's 10 ms cadence,
/// not hundreds of times a second, and a datagram still wakes it at once.
final class IdleListenerLoopbackTests: XCTestCase {
    func testAnIdleListenerPassesAtTheJanitorCadence() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0),
            rateBitsPerSecond: 1_000_000)
        defer { wire.shutdown(reason: .shuttingDown, lingerSeconds: 0) }
        var passes = 0
        XCTAssertThrowsError(try wire.awaitClient(
            hostStatic: hostStatic, timeoutSeconds: 1, idle: { passes += 1 }))
        print("idle listener: \(passes) passes in 1 s")
        XCTAssertGreaterThan(passes, 50, "organs are still serviced")
        XCTAssertLessThan(passes, 150, "no 2 ms spin")
    }

    func testADialStillWakesTheListenerAtOnce() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0),
            rateBitsPerSecond: 1_000_000)
        defer { wire.shutdown(reason: .shuttingDown, lingerSeconds: 0) }
        let client = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        try client.dial()
        let start = Date()
        XCTAssertEqual(try awaitClient(
            wire, hostStatic: hostStatic, timeoutSeconds: 5
        ) {
            let reply = try XCTUnwrap(client.awaitMessage2())
            try client.confirm(message2: reply.payload)
        }, .established)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
