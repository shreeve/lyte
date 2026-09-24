// The client's sealed send path: plaintext → Envelope.sealedDatagram
// (header as AAD) → injected `transmit`. Per-channel seqs come from
// ClientEnvelopeSequencer. Transmit failures are counted, not thrown.

import Foundation
import LyteClientSession
import LyteWire

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

    /// Seals and sends one payload on `channel` with the next seq.
    /// `timestamp` is client monotonic µs; `extensions` ride inside the
    /// AAD. Returns true when the datagram left. Envelope/budget violations
    /// throw; transmit failures only count.
    @discardableResult
    public func send(
        channel: ChannelId,
        frame: FrameNumber = FrameNumber(rawValue: 0),
        timestamp: ClientTimestamp,
        plaintext: [UInt8],
        extensions: [WireExtension] = []
    ) throws -> Bool {
        // Allocation and seal are one critical section: NoiseTransport
        // demands strict per-channel seq monotonicity at seal time, and
        // chan 0 has senders on several threads. Only transmit stays
        // outside. Lock order is sender→crypto everywhere.
        lock.lock()
        let envelope = sequencer.envelope(
            channel: channel,
            frame: frame,
            timestamp: timestamp.microseconds,
            extensions: extensions
        )
        let datagram: [UInt8]
        do {
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
