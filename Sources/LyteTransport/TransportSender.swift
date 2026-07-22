// The client's first send path (CL-3). Until this slice the client only
// listened; feedback (chan=3), beacon echoes, and IDR requests (CTRL) all
// need datagrams flowing client→host, so this is the outbound mirror of
// ReceiveDemux's discipline:
//
//   plaintext → envelope header (exact wire bytes, the AAD) →
//   TransportCrypto.seal → header + wire payload → transmit
//
// The header is encoded once via Envelope.encode(payload: []) so the AAD
// the seal sees is byte-identical to what the receiver's unseal will see —
// the same rule the receive path pins (header-as-AAD, master plan §4.1).
// Per-channel u16 seqs are allocated here, one counter per channel, so
// every outbound channel gets the serial stream the far side's gap
// tracking expects.
//
// `transmit` is injected: the CLI hands it UdpReceiveEndpoint.sendToPeer,
// tests hand it a capture closure. Transmission failures are counted, not
// thrown — these are all fire-and-forget telemetry-class datagrams whose
// loss the next cadence tick supersedes (build plan §4.11).

import Foundation
import LyteWire

/// Outbound counters, snapshotted for the CLI's stats lines.
public struct TransportSenderStats: Sendable {
    public var datagramsSent: UInt64 = 0
    public var sendFailures: UInt64 = 0
    public var sealFailures: UInt64 = 0
}

public final class TransportSender: @unchecked Sendable {
    private let crypto: TransportCrypto
    private let transmit: @Sendable ([UInt8]) -> Bool
    private let lock = NSLock()
    private var seqByChannel: [UInt8: ChannelSeq] = [:]
    private var stats = TransportSenderStats()

    /// - Parameter transmit: hands one encoded datagram to the socket;
    ///   returns false when it could not be sent (no peer yet, EAGAIN).
    public init(
        crypto: TransportCrypto,
        transmit: @escaping @Sendable ([UInt8]) -> Bool
    ) {
        self.crypto = crypto
        self.transmit = transmit
    }

    /// Seals and sends one plaintext payload on `channel`, allocating the
    /// next seq. `timestamp` is client monotonic µs (the envelope rule for
    /// client-sent datagrams). `extensions` ride in the envelope's TLV
    /// block, inside the AAD (the conn-id tag on reliable CTRL, CL-7).
    /// Returns true when the datagram left. Envelope/budget violations
    /// throw (a caller bug, kept loud); transmit failures only count.
    @discardableResult
    public func send(
        channel: ChannelId,
        frame: FrameNumber = FrameNumber(rawValue: 0),
        timestamp: ClientTimestamp,
        plaintext: [UInt8],
        extensions: [WireExtension] = []
    ) throws -> Bool {
        lock.lock()
        let seq = seqByChannel[channel.rawValue] ?? ChannelSeq(rawValue: 0)
        seqByChannel[channel.rawValue] = seq.next
        lock.unlock()

        let envelope = Envelope(
            channel: channel,
            seq: seq,
            frame: frame,
            timestamp: timestamp.microseconds,
            fec: 0,
            extensions: extensions
        )
        // The header bytes double as the AAD — exactly what the receiver
        // will slice off ahead of the payload.
        let header = try envelope.encode(payload: [])
        let sealed: [UInt8]
        do {
            sealed = try crypto.seal(
                plaintext: plaintext[...], aad: header[...], envelope: envelope)
        } catch {
            lock.lock()
            stats.sealFailures += 1
            lock.unlock()
            throw error
        }
        let datagram = try envelope.encode(payload: sealed)

        let sent = transmit(datagram)
        lock.lock()
        if sent { stats.datagramsSent += 1 } else { stats.sendFailures += 1 }
        lock.unlock()
        return sent
    }

    public func snapshotStats() -> TransportSenderStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }
}
