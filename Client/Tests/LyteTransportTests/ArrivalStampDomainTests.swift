import Darwin
import Foundation
import LyteClientTestKit
import LyteIO
@testable import LyteTransport
import LyteWire
import XCTest

/// The endpoint's arrival stamp is a kernel monotonic stamp in the
/// SystemMonotonicClock domain — never wall-clock time.
final class ArrivalStampDomainTests: XCTestCase {
    private final class Stamps: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(arrival: UInt64, handled: UInt64)] = []
        func append(_ arrival: UInt64) {
            let handled = SystemMonotonicClock.nowMicroseconds
            lock.withLock { stored.append((arrival, handled)) }
        }
        var all: [(arrival: UInt64, handled: UInt64)] { lock.withLock { stored } }
    }

    func testKernelArrivalStampSitsInsideTheMonotonicBracket() throws {
        let stamps = Stamps()
        let endpoint = UdpReceiveEndpoint(
            port: 0, bindAddress: "127.0.0.1",
            crypto: PassthroughTransportCrypto(),
            onDatagram: { _, arrival in stamps.append(arrival) })
        try endpoint.start()
        defer { endpoint.stop() }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.boundPort.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let datagram = try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: [0x7F])
        let before = SystemMonotonicClock.nowMicroseconds
        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, datagram, datagram.count, 0, $0,
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, datagram.count)
        let deadline = Date(timeIntervalSinceNow: 2)
        while stamps.all.isEmpty, Date() < deadline { usleep(2_000) }

        let stamp = try XCTUnwrap(stamps.all.first)
        XCTAssertEqual(endpoint.kernelStampedArrivals.load(ordering: .relaxed), 1,
                       "the stamp must come from the kernel cmsg")
        XCTAssertGreaterThanOrEqual(stamp.arrival, before)
        XCTAssertLessThanOrEqual(stamp.arrival, stamp.handled)
    }

    func testControlMessageParsesOnlyTheMonotonicStamp() {
        var control = [UInt8](repeating: 0, count: 20)
        withUnsafeBytes(of: Int32(20)) { control.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: SOL_SOCKET) { control.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: SCM_TIMESTAMP_MONOTONIC) {
            control.replaceSubrange(8..<12, with: $0)
        }
        let ticks: UInt64 = 24_000_000_000
        withUnsafeBytes(of: ticks) { control.replaceSubrange(12..<20, with: $0) }
        let expected = UdpReceiveEndpoint.machTicksToNanoseconds(ticks) / 1_000
        XCTAssertEqual(control.withUnsafeBytes {
            UdpReceiveEndpoint.monotonicArrivalMicroseconds(control: $0)
        }, expected)

        withUnsafeBytes(of: SCM_TIMESTAMP) {
            control.replaceSubrange(8..<12, with: $0)
        }
        XCTAssertNil(control.withUnsafeBytes {
            UdpReceiveEndpoint.monotonicArrivalMicroseconds(control: $0)
        }, "a wall-clock stamp must never be read as monotonic")
    }
}
