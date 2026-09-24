// The client's sealed send path — feedback (chan=3), beacon echoes, IDR
// requests and reliable CTRL all leave through here. The outbound mirror
// of ReceiveDemux's discipline:
//
//   plaintext → Envelope.sealedDatagram (header as AAD, TransportCrypto
//   seal) → transmit
//
// Per-channel u16 seqs come from LyteClientSession's
// ClientEnvelopeSequencer, one serial stream per channel.
//
// `transmit` is injected: the CLI hands it UdpReceiveEndpoint.sendToPeer,
// tests hand it a capture closure. Transmission failures are counted, not
// thrown — these are all fire-and-forget telemetry-class datagrams whose
// loss the next cadence tick supersedes (build plan §4.11).

import Foundation
import LyteClientSession
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
    private var sequencer = ClientEnvelopeSequencer()
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
        // Allocation and seal are ONE critical section (v1-final
        // analysis, finding 4): NoiseTransport commits the extended
        // counter at seal time and demands strict per-channel
        // monotonicity, and chan 0 has three senders on three threads
        // (ARQ service, beacon echo, IDR requester). Sealing outside
        // the lock let a later-allocated seq commit first, so the
        // earlier one's seal threw sendSequenceNotMonotonic — and the
        // ARQ pass that lost the race abandoned its whole packed
        // batch for a PTO, exactly during the loss storms where all
        // three collide. Holding the lock across allocate→seal makes
        // allocation order the commit order by construction; only
        // transmit (the syscall) stays outside. Lock order is
        // sender→crypto everywhere, so this cannot deadlock.
        lock.lock()
        let envelope = sequencer.envelope(
            channel: channel,
            frame: frame,
            timestamp: timestamp.microseconds,
            extensions: extensions
        )
        let datagram: [UInt8]
        do {
            // The header bytes double as the AAD (Envelope.sealedDatagram
            // owns that rule), so the receiver authenticates exactly what
            // it slices off ahead of the payload.
            datagram = try envelope.sealedDatagram(plaintext[...]) {
                plaintext, aad in
                do {
                    return try crypto.seal(
                        plaintext: plaintext, aad: aad, envelope: envelope)
                } catch {
                    stats.sealFailures += 1
                    throw error
                }
            }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

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
