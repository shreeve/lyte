import Foundation
import LyteClientTestKit
import LyteTransport
import LyteWire
import XCTest

/// The production shell's start order: a host datagram that arrives the
/// instant the handshake completes reaches the session core instead of a
/// receive thread with no core behind it.
final class LyteUdpSessionStartTests: XCTestCase {
    /// A handshaking crypto that owns a loopback "host" socket. Its
    /// handshake learns the client's port from one probe, then fires a
    /// clock beacon back before returning — the host's session-start
    /// beacon, which leaves on the first advance after establishment.
    private final class EagerHostCrypto: HandshakingTransportCrypto,
        @unchecked Sendable
    {
        let hostAddress = "127.0.0.1"
        let hostPort: UInt16
        private let hostFd: Int32

        init() throws {
            let hostFd = socket(AF_INET, SOCK_DGRAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(hostFd, $0, length) == 0
                        && getsockname(hostFd, $0, &length) == 0
                }
            }
            guard hostFd >= 0, bound else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            self.hostFd = hostFd
            hostPort = UInt16(bigEndian: addr.sin_port)
        }

        deinit { close(hostFd) }

        var modeDescription: String { "test eager host" }
        func open() throws {}

        func performHandshake(io: any NoiseHandshakeIO) throws {
            try io.sendToHost([0x01])
            var buffer = [UInt8](repeating: 0, count: 64)
            var client = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &client) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(hostFd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard received > 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let beacon = try Envelope(
                channel: .ctrl, seq: ChannelSeq(rawValue: 0),
                frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
            ).encode(payload: ClockBeacon(
                beaconSeq: 0,
                hostSend: HostTimestamp(microseconds: 1_000)).encode())
            let sent = withUnsafePointer(to: &client) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(hostFd, beacon, beacon.count, 0, $0, length)
                }
            }
            guard sent == beacon.count else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            // Let the datagram land in the client's kernel buffer before
            // the handshake returns.
            usleep(20_000)
        }

        func unseal(
            wirePayload: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
            envelope: Envelope
        ) throws -> [UInt8] { Array(wirePayload) }

        func seal(
            plaintext: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
            envelope: Envelope
        ) throws -> [UInt8] { Array(plaintext) }
    }

    func testFirstHostDatagramAfterHandshakeReachesTheCore() throws {
        var config = LyteUdpSession.Config()
        config.bindAddress = "127.0.0.1"
        config.audioPlayback = false
        config.teardownLingerMilliseconds = 0
        let session = LyteUdpSession(
            crypto: try EagerHostCrypto(),
            config: config,
            videoSink: HeadlessVideoSink(),
            onEvent: { _ in })
        try session.start()
        defer { session.stop() }
        let core = try XCTUnwrap(session.core)
        let deadline = Date(timeIntervalSinceNow: 2)
        while core.echoResponder.snapshotStats().beaconsReceived == 0,
              Date() < deadline {
            usleep(5_000)
        }
        XCTAssertEqual(core.echoResponder.snapshotStats().beaconsReceived, 1,
                       "the beacon sent at establishment must not be dropped")
        XCTAssertEqual(
            session.endpoint?.demux.snapshotTotals().accepted, 1)
    }

    /// The stats rows both readers print: state first, the always-on
    /// input and network rows, and only the alarms in capitals.
    func testStatsRowsDescribeAFreshSession() throws {
        var config = LyteUdpSession.Config()
        config.bindAddress = "127.0.0.1"
        config.audioPlayback = false
        config.teardownLingerMilliseconds = 0
        let session = LyteUdpSession(
            crypto: try EagerHostCrypto(),
            config: config,
            videoSink: HeadlessVideoSink(),
            onEvent: { _ in })
        XCTAssertEqual(SessionStatsFormatter.rows(session: session), [])
        try session.start()
        defer { session.stop() }
        let core = try XCTUnwrap(session.core)
        let deadline = Date(timeIntervalSinceNow: 2)
        while core.echoResponder.snapshotStats().beaconsReceived == 0,
              Date() < deadline {
            usleep(5_000)
        }

        let rows = SessionStatsFormatter.rows(session: session)
        XCTAssertEqual(rows.map(\.label), ["session", "user", "network"])
        XCTAssertEqual(rows[0].value, "active")
        XCTAssertEqual(rows[1].value, "0 events sent to host")
        XCTAssertEqual(rows[2].value, "lost 0 of 1 host packets")

        var context = SessionStatsContext()
        context.inputCaptured = false
        context.radioLoose = true
        XCTAssertEqual(
            SessionStatsFormatter.rows(session: session, context: context)
                .first?.value,
            "active · keys+mouse NOT CAPTURED · AWDL LOOSE")
    }
}
