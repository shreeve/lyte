import CNetIO
import Foundation
import Glibc
@testable import lyte_host
import LyteWire
import XCTest

/// The service loop's socket half on loopback: sessions in turn share one
/// HostListener, each completes its own handshake on the same port, and a
/// released session leaves no descriptor behind.
final class ServiceLoopLoopbackTests: XCTestCase {
    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
            .count
    }

    func testSessionsInTurnShareTheListenerAndLeaveNoDescriptors() throws {
        let hostStatic = NoiseKeyPair.generate()
        let listener = try HostListener(hostStatic: hostStatic)
        let port = lyte_netio_local_port(listener.netio)
        let baseline = try openDescriptorCount()

        for round in 1...3 {
            let wire = try SessionWire(
                listener: listener, rateBitsPerSecond: 1_000_000)
            XCTAssertEqual(wire.localPort, port, "round \(round)")
            do {
                let client = try LoopbackDialer(
                    port: port, hostStaticPublicKey: hostStatic.publicKey)
                try client.dial()
                XCTAssertEqual(try awaitClient(
                    wire, timeoutSeconds: 5
                ) {
                    let reply = try XCTUnwrap(
                        client.awaitMessage2(), "round \(round): message 2")
                    XCTAssertEqual(reply.sourcePort, port,
                        "round \(round): message 2 leaves the session port")
                    try client.confirm(message2: reply.payload)
                }, .established, "round \(round)")
            }

            wire.shutdown(reason: .shuttingDown, lingerSeconds: 0)
            wire.release()
            wire.release() // idempotent
            XCTAssertEqual(
                try openDescriptorCount(), baseline,
                "round \(round): the session's media sockets and wake fd close")
        }
    }
}
