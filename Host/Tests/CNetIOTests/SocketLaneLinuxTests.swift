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
