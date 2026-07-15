import Foundation
import Network

/// Sends SS_PING datagrams (16-byte token + BE32 counter) every 500 ms.
/// Sunshine learns where to send video/audio RTP from these pings, so the
/// socket that pings a port is the socket that will receive that stream.
public final class UdpPinger: @unchecked Sendable {
    private let connection: NWConnection
    private let payload: Data
    private var sequence: UInt32 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "lyte-udp-ping")

    public init(host: String, port: UInt16, pingPayload: Data) {
        self.payload = pingPayload
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port),
            using: .udp)
    }

    public func start() {
        connection.start(queue: queue)
        // Keep receiving so the socket stays hot (M3 reads RTP from here).
        receiveLoop()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.ping() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        connection.cancel()
    }

    private func ping() {
        sequence += 1
        var packet = payload
        packet.append(UInt8((sequence >> 24) & 0xff))
        packet.append(UInt8((sequence >> 16) & 0xff))
        packet.append(UInt8((sequence >> 8) & 0xff))
        packet.append(UInt8(sequence & 0xff))
        connection.send(content: packet, completion: .idempotent)
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] _, _, _, error in
            guard error == nil else { return }
            self?.receiveLoop()
        }
    }
}
