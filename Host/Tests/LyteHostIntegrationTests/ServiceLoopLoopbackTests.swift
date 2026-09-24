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
    private var error = [CChar](repeating: 0, count: 256)

    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
            .count
    }

    private func socket(to port: UInt16) throws -> OpaquePointer {
        let socket = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        XCTAssertEqual(lyte_netio_set_peer(
            socket, "127.0.0.1", port, &error, error.count), 0)
        return socket
    }

    private func send(_ bytes: [UInt8], on socket: OpaquePointer) {
        bytes.withUnsafeBufferPointer { buffer in
            var packet = lyte_netio_pkt(
                data: buffer.baseAddress, len: buffer.count, tos: 0)
            XCTAssertEqual(lyte_netio_send_batch(
                socket, &packet, 1, nil, &error, error.count), 1)
        }
    }

    /// Message 2's payload as the client receives it, and the port it
    /// left from.
    private func awaitMessage2(
        on socket: OpaquePointer
    ) -> (payload: [UInt8], sourcePort: UInt16)? {
        var storage = [UInt8](repeating: 0, count: 2_048)
        var slots = [lyte_netio_slot()]
        var found: ([UInt8], UInt16)?
        storage.withUnsafeMutableBufferPointer { bytes in
            slots[0].data = bytes.baseAddress
            slots[0].cap = bytes.count
            for _ in 0..<2_000 where found == nil {
                let count = slots.withUnsafeMutableBufferPointer {
                    lyte_netio_recv_batch(
                        socket, $0.baseAddress, 1, &error, error.count)
                }
                if count == 1,
                   let (envelope, payload) = try? Envelope.decode(
                       Array(bytes.prefix(slots[0].len))),
                   envelope.channel == .ctrl,
                   payload.first == CtrlMessageType.noiseHandshake2 {
                    found = (Array(payload.dropFirst()), slots[0].src_port)
                } else {
                    usleep(500)
                }
            }
        }
        return found
    }

    func testSessionsInTurnShareTheListenerAndLeaveNoDescriptors() throws {
        let hostStatic = NoiseKeyPair.generate()
        let listener = try HostListener(port: 0)
        let port = lyte_netio_local_port(listener.netio)
        let baseline = try openDescriptorCount()

        for round in 1...3 {
            let wire = try SessionWire(
                listener: listener, peer: nil, rateBitsPerSecond: 1_000_000)
            XCTAssertEqual(wire.localPort, port, "round \(round)")
            let client = try socket(to: port)
            var noise = try NoiseSession(
                role: .initiator, staticKeys: NoiseKeyPair.generate(),
                remoteStaticPublicKey: hostStatic.publicKey)
            send(try Envelope(
                channel: .ctrl, seq: ChannelSeq(rawValue: 1),
                frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
            ).encode(payload: [CtrlMessageType.noiseHandshake1]
                + (try noise.writeMessage1())), on: client)

            XCTAssertEqual(
                try wire.awaitClient(
                    hostStatic: hostStatic, timeoutSeconds: 5),
                .established, "round \(round)")
            let reply = try XCTUnwrap(
                awaitMessage2(on: client), "round \(round): message 2")
            XCTAssertEqual(reply.sourcePort, port,
                           "round \(round): message 2 leaves the session port")
            XCTAssertNoThrow(try noise.readMessage2(reply.payload[...]))

            wire.shutdown(reason: .shuttingDown, lingerSeconds: 0)
            wire.release()
            wire.release() // idempotent
            lyte_netio_free(client)
            XCTAssertEqual(
                try openDescriptorCount(), baseline,
                "round \(round): the session's media sockets and wake fd close")
        }
    }
}
