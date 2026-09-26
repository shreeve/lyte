// The (chan, seq) demux: every received datagram funnels through
// `ingest` — envelope decode via LyteWire, reserved-channel drop, the
// TransportCrypto unseal, then per-channel seq accounting.
// Thread-safe: the endpoint's receive thread writes, anyone may snapshot.

import Foundation
import LyteClientCore
import LyteClientSession
import LyteWire

/// What became of one datagram fed to the demux.
public enum IngestOutcome: Sendable {
    case accepted(envelope: Envelope, payload: [UInt8])
    /// Channels 5–7: never sent, dropped on receive (ChannelId registry).
    case reservedChannel(UInt8)
    /// LyteWire refused the bytes (truncation, over-budget, bad TLVs).
    case malformed(WireError)
    /// The crypto seam refused the payload.
    case unsealFailed(Error)
}

/// Running per-channel statistics, snapshotted for display and tests.
public struct ChannelStats: Sendable {
    public var datagrams: UInt64 = 0
    public var payloadBytes: UInt64 = 0
    public var unsealFailures: UInt64 = 0
    public var seq = SeqGapTracker()

    public var seqHighest: UInt16? { seq.highest?.rawValue }
    /// Datagrams still missing: gaps detected minus the late arrivals
    /// that filled them. Already net of late fills — subtracting those
    /// again double-counts every reordered datagram.
    public var seqMissing: UInt64 { seq.datagramsMissing }
    public var seqDuplicates: UInt64 { seq.duplicates }
}

/// Demux totals across channels, including everything that never reached one.
public struct DemuxTotals: Sendable {
    public var datagrams: UInt64 = 0
    public var accepted: UInt64 = 0
    public var malformed: UInt64 = 0
    public var reservedDropped: UInt64 = 0
    public var unsealFailures: UInt64 = 0
    /// Arrival samples dropped because a feedback drain fell behind.
    public var arrivalSamplesDropped: UInt64 = 0
}

/// One accepted datagram's arrival record (SystemMonotonicClock µs,
/// meaningful only as spacing), for the feedback report's dispersion
/// section.
public typealias ArrivalSample = ClientFeedbackReporter.Arrival

public final class ReceiveDemux: @unchecked Sendable {
    private let crypto: TransportCrypto
    private let lock = NSLock()
    private var channels: [UInt8: ChannelStats] = [:]
    private var totals = DemuxTotals()
    private var arrivals: [ArrivalSample] = []

    public init(crypto: TransportCrypto) {
        self.crypto = crypto
    }

    /// Feeds one raw datagram. `arrivalMicroseconds` (SystemMonotonicClock)
    /// feeds arrival spacing only. Decode and unseal run outside the lock;
    /// the lock covers only the books.
    @discardableResult
    public func ingest(
        datagram: ArraySlice<UInt8>,
        arrivalMicroseconds: UInt64
    ) -> IngestOutcome {
        let envelope: Envelope
        let plaintext: [UInt8]
        do {
            // The reserved-channel check runs before any AEAD work.
            (envelope, plaintext) = try Envelope.openDatagram(datagram) {
                envelope, wirePayload, aad in
                guard !envelope.channel.isReserved else {
                    throw ReservedChannel(envelope: envelope)
                }
                do {
                    return try crypto.unseal(
                        wirePayload: wirePayload, aad: aad, envelope: envelope)
                } catch {
                    throw UnsealFailure(envelope: envelope, underlying: error)
                }
            }
        } catch let reserved as ReservedChannel {
            lock.lock()
            totals.datagrams += 1
            totals.reservedDropped += 1
            lock.unlock()
            return .reservedChannel(reserved.envelope.channel.rawValue)
        } catch let failure as UnsealFailure {
            lock.lock()
            totals.datagrams += 1
            totals.unsealFailures += 1
            channels[failure.envelope.channel.rawValue, default: ChannelStats()]
                .unsealFailures += 1
            lock.unlock()
            return .unsealFailed(failure.underlying)
        } catch {
            let wireError = error as? WireError ?? .truncatedEnvelope
            lock.lock()
            totals.datagrams += 1
            totals.malformed += 1
            lock.unlock()
            return .malformed(wireError)
        }

        lock.lock()
        defer { lock.unlock() }
        totals.datagrams += 1
        totals.accepted += 1
        channels[envelope.channel.rawValue, default: ChannelStats()]
            .record(envelope.seq, payloadByteCount: plaintext.count)
        if arrivals.count < ClientFeedbackReporter.maxRetainedArrivals {
            arrivals.append(ArrivalSample(
                channel: envelope.channel,
                seq: envelope.seq,
                arrivalMicroseconds: arrivalMicroseconds))
        } else {
            // Drop the newest and count it.
            totals.arrivalSamplesDropped += 1
        }
        return .accepted(envelope: envelope, payload: plaintext)
    }

    /// Removes and returns the arrival samples since the last drain.
    public func drainArrivalSamples() -> [ArrivalSample] {
        lock.lock()
        defer { lock.unlock() }
        let drained = arrivals
        arrivals.removeAll(keepingCapacity: true)
        return drained
    }

    public func snapshotTotals() -> DemuxTotals {
        lock.lock()
        defer { lock.unlock() }
        return totals
    }

    /// Per-channel stats keyed by raw channel number, sorted for display.
    public func snapshotChannels() -> [(channel: UInt8, stats: ChannelStats)] {
        lock.lock()
        defer { lock.unlock() }
        return channels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public func stats(forChannel channel: UInt8) -> ChannelStats? {
        lock.lock()
        defer { lock.unlock() }
        return channels[channel]
    }
}

/// Sentinels that carry a refusal out of the `openDatagram` closure.
private struct ReservedChannel: Error { var envelope: Envelope }
private struct UnsealFailure: Error { var envelope: Envelope; var underlying: Error }

extension ChannelStats {
    mutating func record(_ seq: ChannelSeq, payloadByteCount: Int) {
        self.seq.record(seq)
        datagrams += 1
        payloadBytes += UInt64(payloadByteCount)
    }
}
