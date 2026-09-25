import CNetIO
import Foundation
import Glibc
import HostSession
@testable import lyte_host
import LyteWire
import XCTest

/// A loopback client for the listening host: dials with Noise message 1,
/// reads message 2 and proves key possession with one sealed datagram —
/// the host commits to a client only then.
final class LoopbackDialer {
    let socket: OpaquePointer
    private(set) var noise: NoiseSession
    private(set) var message1Datagram: [UInt8] = []
    private var error = [CChar](repeating: 0, count: 256)

    init(port: UInt16, hostStaticPublicKey: [UInt8]) throws {
        socket = try XCTUnwrap(lyte_netio_new(
            "127.0.0.1", 0, &error, error.count))
        XCTAssertEqual(lyte_netio_set_peer(
            socket, "127.0.0.1", port, &error, error.count), 0)
        noise = try NoiseSession(
            role: .initiator, staticKeys: NoiseKeyPair.generate(),
            remoteStaticPublicKey: hostStaticPublicKey)
    }

    deinit { lyte_netio_free(socket) }

    var localPort: UInt16 { lyte_netio_local_port(socket) }

    func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            var packet = lyte_netio_pkt(
                data: buffer.baseAddress, len: buffer.count, tos: 0)
            XCTAssertEqual(lyte_netio_send_batch(
                socket, &packet, 1, nil, &error, error.count), 1)
        }
    }

    static func ctrl(_ payload: [UInt8], seq: UInt16 = 0) throws -> [UInt8] {
        try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: payload)
    }

    /// Writes message 1 without sending it (what an observer captures).
    func writeMessage1() throws {
        message1Datagram = try Self.ctrl(
            [CtrlMessageType.noiseHandshake1] + (try noise.writeMessage1()))
    }

    /// Sends (and remembers) message 1.
    func dial() throws {
        try writeMessage1()
        send(message1Datagram)
    }

    /// Discards whatever is queued on the socket.
    func drain() {
        var storage = [UInt8](repeating: 0, count: 2_048)
        var slots = [lyte_netio_slot()]
        storage.withUnsafeMutableBufferPointer { bytes in
            slots[0].data = bytes.baseAddress
            slots[0].cap = bytes.count
            while slots.withUnsafeMutableBufferPointer({
                lyte_netio_recv_batch(socket, $0.baseAddress, 1, &error, error.count)
            }) == 1 {}
        }
    }

    /// Message 2's payload as received, and the port it left from; nil
    /// after about a second without one.
    func awaitMessage2() -> (payload: [UInt8], sourcePort: UInt16)? {
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

    /// The client's transport once `confirm` has run.
    private var transport: NoiseTransport?
    private var feedbackSeq: UInt16 = 0

    /// Completes the handshake from `message2` and sends one sealed CTRL
    /// datagram: the proof of key possession.
    func confirm(message2: [UInt8]) throws {
        _ = try noise.readMessage2(message2[...])
        var transport = try noise.makeTransport()
        send(try transport.sealDatagram(
            Envelope(
                channel: .ctrl, seq: ChannelSeq(rawValue: 1),
                frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0),
            plaintext: [CtrlMessageType.arqAck, 0, 0][...]))
        self.transport = transport
    }

    /// One sealed feedback datagram: media-path evidence for the host's
    /// lifecycle, whatever its interior says.
    func sendFeedback() throws {
        guard var transport else { return }
        feedbackSeq &+= 1
        send(try transport.sealDatagram(
            Envelope(
                channel: .feedback, seq: ChannelSeq(rawValue: feedbackSeq),
                frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0),
            plaintext: [0][...]))
        self.transport = transport
    }
}

extension HostListener {
    /// A listener admitting dials to `hostStatic`, on a kernel-picked port
    /// unless `port` names one.
    convenience init(
        port: UInt16 = 0, hostStatic: NoiseKeyPair = .generate()
    ) throws {
        try self.init(
            port: port,
            acceptor: HandshakeAcceptor.Config(hostStatic: hostStatic))
    }
}

/// Runs `awaitClient` on a worker thread while `client` plays the client
/// on the calling one; returns the wait's outcome.
func awaitClient(
    _ wire: SessionWire, timeoutSeconds: Double,
    while client: () throws -> Void
) throws -> SessionWire.ClientAwaitOutcome {
    nonisolated(unsafe) var result: Result<SessionWire.ClientAwaitOutcome, any Error>?
    nonisolated(unsafe) let wire = wire
    let done = DispatchSemaphore(value: 0)
    Thread {
        result = Result {
            try wire.awaitClient(timeoutSeconds: timeoutSeconds)
        }
        done.signal()
    }.start()
    try client()
    done.wait()
    return try result!.get()
}
