import XCTest
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// Live-socket integration: spin the endpoint on 127.0.0.1, fire hand-built
// datagrams (valid via LyteWire encode, plus malformed ones), and assert
// the counters, gap tracking, and reject behavior the CL-1 gate names.

final class LoopbackEndpointTests: XCTestCase {

    func testNoiseEndpointFailsLoudlyWhenNoHostAnswers() throws {
        // A dead loopback port: the handshake must retry, then refuse the
        // whole endpoint start — Noise mode never falls open.
        let crypto = try NoiseTransportCrypto(
            hostAddress: "127.0.0.1", hostPort: 9,
            hostStaticPublicKey: NoiseKeyPair.generate().publicKey,
            attempts: 2, attemptTimeoutMilliseconds: 40)
        let endpoint = UdpReceiveEndpoint(
            port: 0, bindAddress: "127.0.0.1", crypto: crypto)
        XCTAssertThrowsError(try endpoint.start()) { error in
            guard case TransportCryptoError.handshakeFailed = error else {
                return XCTFail("expected handshakeFailed, got \(error)")
            }
        }
    }

    func testInsecureTransportOpensImmediately() throws {
        let endpoint = UdpReceiveEndpoint(
            port: 0, bindAddress: "127.0.0.1", crypto: InsecureTransportCrypto())
        try endpoint.start()
        defer { endpoint.stop() }
        XCTAssertNotEqual(endpoint.boundPort, 0, "port 0 bind must learn the real port")
    }

    func testLiveDatagramsCountedGapsTrackedRejectsRejected() throws {
        let endpoint = UdpReceiveEndpoint(
            port: 0, bindAddress: "127.0.0.1", crypto: InsecureTransportCrypto())
        try endpoint.start()
        defer { endpoint.stop() }

        let sender = try LoopbackSender(port: endpoint.boundPort)
        defer { sender.close() }

        // Valid video shards: seqs 0, 1, 2, 4 — a deliberate gap at 3.
        var expectedVideoBytes: UInt64 = 0
        for (i, seq) in [0, 1, 2, 4].enumerated() {
            let payload = [UInt8](repeating: UInt8(0xA0 + i), count: 100 + i)
            expectedVideoBytes += UInt64(payload.count)
            let envelope = Envelope(
                channel: .videoActive,
                seq: ChannelSeq(rawValue: UInt16(seq)),
                frame: FrameNumber(rawValue: UInt32(seq / 2)),
                timestamp: UInt64(seq) * 16_667,
                fec: 0x1122_3344_5566_7788
            )
            try sender.send(envelope.encode(payload: payload))
        }

        // One audio datagram with a TLV, exercising the header-as-AAD shape.
        let audioEnvelope = Envelope(
            channel: .audio,
            seq: ChannelSeq(rawValue: 500),
            frame: FrameNumber(rawValue: 9000),
            timestamp: 123_456_789,
            fec: 0,
            extensions: [try WireExtension(type: 0x7F, value: [1, 2, 3])]
        )
        try sender.send(audioEnvelope.encode(payload: [UInt8](repeating: 0x0B, count: 48)))

        // Malformed: truncated (23 B), a promised-but-missing TLV block,
        // and an over-budget 1153 B datagram.
        try sender.send([UInt8](repeating: 0, count: 23))
        var promisedTlv = try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 1),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: [])
        promisedTlv[1] = 0x01   // flags promise a TLV block that isn't there
        try sender.send(promisedTlv)
        try sender.send([UInt8](repeating: 0x42, count: 1153))

        // Reserved channel 5: decodes fine, dropped at the demux.
        let reserved = try Envelope(
            channel: ChannelId(rawValue: 5), seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: [1])
        try sender.send(reserved)

        // 9 datagrams total; wait for the receive thread to account them.
        try waitUntil(timeoutSeconds: 5) {
            endpoint.demux.snapshotTotals().datagrams == 9
        }

        let totals = endpoint.demux.snapshotTotals()
        XCTAssertEqual(totals.datagrams, 9)
        XCTAssertEqual(totals.accepted, 5)
        XCTAssertEqual(totals.malformed, 3)
        XCTAssertEqual(totals.reservedDropped, 1)
        XCTAssertEqual(totals.unsealFailures, 0)

        guard let video = endpoint.demux.stats(forChannel: ChannelId.videoActive.rawValue) else {
            return XCTFail("no video-active stats")
        }
        XCTAssertEqual(video.datagrams, 4)
        XCTAssertEqual(video.payloadBytes, expectedVideoBytes)
        XCTAssertEqual(video.seqHighest, 4)
        XCTAssertEqual(video.seqMissing, 1, "the skipped seq 3 must count as a gap")
        XCTAssertEqual(video.seqDuplicates, 0)
        XCTAssertEqual(video.firstFrame, 0)
        XCTAssertEqual(video.maxFrame, 2)

        guard let audio = endpoint.demux.stats(forChannel: ChannelId.audio.rawValue) else {
            return XCTFail("no audio stats")
        }
        XCTAssertEqual(audio.datagrams, 1)
        XCTAssertEqual(audio.payloadBytes, 48)
        XCTAssertEqual(audio.seqHighest, 500)

        XCTAssertNil(endpoint.demux.stats(forChannel: 5),
                     "reserved channels must never accumulate accepted stats")
    }

    // MARK: CL-3's return leg

    func testSendToPeerReachesTheDatagramSource() throws {
        let endpoint = UdpReceiveEndpoint(
            port: 0, bindAddress: "127.0.0.1", crypto: InsecureTransportCrypto())
        try endpoint.start()
        defer { endpoint.stop() }

        // No peer yet: sends report false instead of throwing.
        XCTAssertFalse(endpoint.hasPeer)
        XCTAssertFalse(endpoint.sendToPeer([1, 2, 3]),
                       "no datagram has arrived, so there is nobody to reply to")

        // A connected sender (wire-send's shape): its one datagram
        // teaches the endpoint the reply address.
        let sender = try LoopbackSender(port: endpoint.boundPort)
        defer { sender.close() }
        let hello = try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: [0x7F])
        try sender.send(hello)
        try waitUntil(timeoutSeconds: 5) { endpoint.hasPeer }

        // The reply leaves from the endpoint's bound socket and lands on
        // the sender's connected socket.
        let reply: [UInt8] = [0xC0, 0xFF, 0xEE]
        XCTAssertTrue(endpoint.sendToPeer(reply))
        XCTAssertEqual(try sender.receive(timeoutSeconds: 5), reply)
    }

    // MARK: Helpers

    private func waitUntil(
        timeoutSeconds: Double,
        _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("timed out waiting for datagrams to be accounted")
            }
            usleep(20_000)
        }
    }
}

/// Minimal UDP sender to 127.0.0.1:port.
private final class LoopbackSender {
    private let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func send(_ bytes: [UInt8]) throws {
        let sent = bytes.withUnsafeBufferPointer { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
        guard sent == bytes.count else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Blocks for one datagram on the connected socket (the CL-3 return
    /// leg lands here).
    func receive(timeoutSeconds: Double) throws -> [UInt8] {
        var tv = timeval(tv_sec: Int(timeoutSeconds),
                         tv_usec: Int32((timeoutSeconds.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBufferPointer { buf in
            recv(fd, buf.baseAddress, buf.count, 0)
        }
        guard n > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Array(buffer[0..<n])
    }

    func close() {
        Darwin.close(fd)
    }
}
