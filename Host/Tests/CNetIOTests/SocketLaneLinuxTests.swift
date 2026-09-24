import CNetIO
import Glibc
import XCTest

final class SocketLaneLinuxTests: XCTestCase {
    func testTwoSendBuffersPreserveOneWireSourcePort() throws {
        var error = [CChar](repeating: 0, count: 256)
        let receiver = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        defer { lyte_netio_free(receiver) }
        let receiverPort = lyte_netio_local_port(receiver)

        let video = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        defer { lyte_netio_free(video) }
        let sharedPort = lyte_netio_local_port(video)
        let latency = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", sharedPort, &error, error.count))
        defer { lyte_netio_free(latency) }

        XCTAssertEqual(lyte_netio_local_port(latency), sharedPort)
        XCTAssertGreaterThan(lyte_netio_send_buffer_bytes(video), 0)
        XCTAssertGreaterThan(lyte_netio_send_buffer_bytes(latency), 0)
        XCTAssertEqual(lyte_netio_outq_bytes(video), 0)
        XCTAssertEqual(lyte_netio_outq_bytes(latency), 0)
        XCTAssertEqual(lyte_netio_set_priority(video, 4), 0)
        XCTAssertEqual(lyte_netio_set_priority(latency, 6), 0)

        for socket in [video, latency] {
            XCTAssertEqual(lyte_netio_set_peer(
                socket, "127.0.0.1", receiverPort,
                &error, error.count), 0)
        }
        var byte: UInt8 = 0xA5
        withUnsafeMutablePointer(to: &byte) { bytePointer in
            var packet = lyte_netio_pkt(
                data: bytePointer, len: 1, tos: 0xC0)
            XCTAssertEqual(lyte_netio_send_batch(
                video, &packet, 1, nil, &error, error.count), 1)
            bytePointer.pointee = 0x5A
            XCTAssertEqual(lyte_netio_send_batch(
                latency, &packet, 1, nil, &error, error.count), 1)
        }

        var storage = [UInt8](repeating: 0, count: 8)
        var slots = [lyte_netio_slot()]
        var sourcePorts: [UInt16] = []
        storage.withUnsafeMutableBufferPointer { bytes in
            slots[0].data = bytes.baseAddress
            slots[0].cap = bytes.count
            for _ in 0..<200 where sourcePorts.count < 2 {
                let count = slots.withUnsafeMutableBufferPointer {
                    lyte_netio_recv_batch(
                        receiver, $0.baseAddress, 1, &error, error.count)
                }
                if count == 1 {
                    sourcePorts.append(slots[0].src_port)
                } else {
                    usleep(100)
                }
            }
        }
        XCTAssertEqual(sourcePorts, [sharedPort, sharedPort])
    }
}

final class NetioErrnoClassTests: XCTestCase {
    /// Soft ICMP-driven errors are loss, not session death (B7).
    func testSoftNetworkErrorsAreTransient() {
        for code in [EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN, EPERM] {
            XCTAssertEqual(lyte_netio_errno_class(code), LYTE_NETIO_TRANSIENT,
                           "errno \(code)")
        }
    }

    func testRetryablePeerGoneAndFatalErrorsKeepTheirMeaning() {
        XCTAssertEqual(lyte_netio_errno_class(EAGAIN), 0)
        XCTAssertEqual(lyte_netio_errno_class(EWOULDBLOCK), 0)
        XCTAssertEqual(lyte_netio_errno_class(ENOBUFS), LYTE_NETIO_NO_BUFFER)
        XCTAssertEqual(lyte_netio_errno_class(ECONNREFUSED), LYTE_NETIO_PEER_GONE)
        XCTAssertEqual(lyte_netio_errno_class(EBADF), -1)
        XCTAssertEqual(lyte_netio_errno_class(EINVAL), -1)
    }
}

/// B3's kernel half: a connected UDP socket hears only its peer, so the
/// session port keeps one unconnected member. A second client's datagram
/// (a migrated path, the next handshake) must still land on the port.
final class ListeningSocketLinuxTests: XCTestCase {
    func testAnUnconnectedMemberHearsTuplesTheConnectedMembersRefuse() throws {
        var error = [CChar](repeating: 0, count: 256)
        let listening = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        defer { lyte_netio_free(listening) }
        let port = lyte_netio_local_port(listening)
        let media = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", port, &error, error.count))
        defer { lyte_netio_free(media) }

        let clientA = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        defer { lyte_netio_free(clientA) }
        let clientB = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        defer { lyte_netio_free(clientB) }
        XCTAssertEqual(lyte_netio_set_peer(
            media, "127.0.0.1", lyte_netio_local_port(clientA),
            &error, error.count), 0)

        for (client, byte) in [(clientA, UInt8(0xA1)), (clientB, UInt8(0xB2))] {
            XCTAssertEqual(lyte_netio_set_peer(
                client, "127.0.0.1", port, &error, error.count), 0)
            var payload = byte
            withUnsafeMutablePointer(to: &payload) { pointer in
                var packet = lyte_netio_pkt(data: pointer, len: 1, tos: 0)
                XCTAssertEqual(lyte_netio_send_batch(
                    client, &packet, 1, nil, &error, error.count), 1)
            }
        }

        var heard: [UInt16: UInt8] = [:]
        var storage = [UInt8](repeating: 0, count: 8)
        var slots = [lyte_netio_slot()]
        storage.withUnsafeMutableBufferPointer { bytes in
            slots[0].data = bytes.baseAddress
            slots[0].cap = bytes.count
            for _ in 0..<400 where heard.count < 2 {
                for socket in [listening, media] {
                    let count = slots.withUnsafeMutableBufferPointer {
                        lyte_netio_recv_batch(
                            socket, $0.baseAddress, 1, &error, error.count)
                    }
                    if count == 1 {
                        heard[slots[0].src_port] = bytes[0]
                    }
                }
                usleep(100)
            }
        }
        XCTAssertEqual(heard[lyte_netio_local_port(clientA)], 0xA1)
        XCTAssertEqual(heard[lyte_netio_local_port(clientB)], 0xB2,
            "the second client reaches the port through the listening member")
    }

    /// The failure the listening member prevents: with only a connected
    /// member on the port, another tuple's datagram is refused by the
    /// kernel (its sender reads ECONNREFUSED).
    func testAPortWithOnlyAConnectedMemberRefusesOtherTuples() throws {
        var error = [CChar](repeating: 0, count: 256)
        let media = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        defer { lyte_netio_free(media) }
        let port = lyte_netio_local_port(media)
        let clientA = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        defer { lyte_netio_free(clientA) }
        let clientB = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        defer { lyte_netio_free(clientB) }
        XCTAssertEqual(lyte_netio_set_peer(
            media, "127.0.0.1", lyte_netio_local_port(clientA),
            &error, error.count), 0)
        XCTAssertEqual(lyte_netio_set_peer(
            clientB, "127.0.0.1", port, &error, error.count), 0)
        var payload: UInt8 = 0xB2
        withUnsafeMutablePointer(to: &payload) { pointer in
            var packet = lyte_netio_pkt(data: pointer, len: 1, tos: 0)
            XCTAssertEqual(lyte_netio_send_batch(
                clientB, &packet, 1, nil, &error, error.count), 1)
        }
        var storage = [UInt8](repeating: 0, count: 8)
        var slots = [lyte_netio_slot()]
        var refused = false
        storage.withUnsafeMutableBufferPointer { bytes in
            slots[0].data = bytes.baseAddress
            slots[0].cap = bytes.count
            for _ in 0..<400 where !refused {
                let heard = slots.withUnsafeMutableBufferPointer {
                    lyte_netio_recv_batch(
                        media, $0.baseAddress, 1, &error, error.count)
                }
                XCTAssertEqual(heard, 0, "a connected member never hears B")
                refused = slots.withUnsafeMutableBufferPointer {
                    lyte_netio_recv_batch(
                        clientB, $0.baseAddress, 1, &error, error.count)
                } == LYTE_NETIO_PEER_GONE
                usleep(100)
            }
        }
        XCTAssertTrue(refused, "the kernel answered B with port-unreachable")
    }
}
