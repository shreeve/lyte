import CNetIO
import Glibc
@testable import lyte_host
import LyteWire
import XCTest

/// B3 end to end on loopback: a spoofed message 1 arrives first and a
/// real client handshakes from another tuple. The listening host must
/// complete with the real client and answer it with message 2.
final class HandshakeLatchLoopbackTests: XCTestCase {
    private var error = [CChar](repeating: 0, count: 256)

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

    private func ctrl(_ payload: [UInt8]) throws -> [UInt8] {
        try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 1),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: payload)
    }

    func testAHandshakeAfterASpoofedFirstArrivalStillEstablishes() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listenPort: 0, peer: nil, rateBitsPerSecond: 1_000_000)
        defer { wire.shutdown(reason: .shuttingDown, lingerSeconds: 0) }

        let spoofer = try socket(to: wire.localPort)
        defer { lyte_netio_free(spoofer) }
        let client = try socket(to: wire.localPort)
        defer { lyte_netio_free(client) }

        send(try ctrl([CtrlMessageType.noiseHandshake1]
            + [UInt8](repeating: 0x42, count: 96)), on: spoofer)
        var noise = try NoiseSession(
            role: .initiator, staticKeys: NoiseKeyPair.generate(),
            remoteStaticPublicKey: hostStatic.publicKey)
        send(try ctrl([CtrlMessageType.noiseHandshake1]
            + (try noise.writeMessage1())), on: client)

        XCTAssertEqual(
            try wire.awaitClient(hostStatic: hostStatic, timeoutSeconds: 5),
            .established)

        var storage = [UInt8](repeating: 0, count: 2_048)
        var slots = [lyte_netio_slot()]
        var message2: [UInt8]?
        storage.withUnsafeMutableBufferPointer { bytes in
            slots[0].data = bytes.baseAddress
            slots[0].cap = bytes.count
            for _ in 0..<2_000 where message2 == nil {
                let count = slots.withUnsafeMutableBufferPointer {
                    lyte_netio_recv_batch(
                        client, $0.baseAddress, 1, &error, error.count)
                }
                if count == 1,
                   let (envelope, payload) = try? Envelope.decode(
                       Array(bytes.prefix(slots[0].len))),
                   envelope.channel == .ctrl,
                   payload.first == CtrlMessageType.noiseHandshake2 {
                    message2 = Array(payload.dropFirst())
                    XCTAssertEqual(slots[0].src_port, wire.localPort,
                        "message 2 leaves from the session port")
                } else {
                    usleep(500)
                }
            }
        }
        let reply = try XCTUnwrap(message2, "the real client gets message 2")
        XCTAssertNoThrow(try noise.readMessage2(reply[...]))
    }
}
