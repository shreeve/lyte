// The (chan, seq) demux: every received datagram funnels through
// `ingest` — envelope decode via LyteWire, reserved-channel drop, the
// TransportCrypto unseal, then per-channel seq/frame/timestamp accounting.
// Thread-safe: the endpoint's receive thread writes, anyone may snapshot.

import Foundation
import LyteClientCore
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

    public var seqHighest: UInt16?
    /// Datagrams still missing: gaps detected minus the late arrivals
    /// that filled them. Already net of `seqLateFilled` — subtracting
    /// that again double-counts every reordered datagram.
    public var seqMissing: UInt64 = 0
    public var seqDuplicates: UInt64 = 0
    public var seqLateFilled: UInt64 = 0
    public var seqBeyondWindow: UInt64 = 0
    public var seqWrapEvents: UInt64 = 0

    public var firstFrame: UInt32?
    public var lastFrame: UInt32?
    public var maxFrame: UInt32?
    /// Consecutive-arrival frame-number changes (approximates frames seen).
    public var frameTransitions: UInt64 = 0

    /// Sender-clock µs delta between the last two datagrams.
    public var lastTimestampDeltaMicros: Int64?
    /// Arrival-clock (kernel-stamp preferred) µs delta between the last two.
    public var lastArrivalDeltaMicros: Int64?

    public var unsealFailures: UInt64 = 0
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

/// One accepted datagram's arrival record, for the feedback report's
/// dispersion section.
public struct ArrivalSample: Sendable {
    public var channel: UInt8
    public var seq: UInt16
    /// SystemMonotonicClock µs; meaningful only as spacing.
    public var arrivalMicroseconds: UInt64
}

public final class ReceiveDemux: @unchecked Sendable {
    /// Arrival samples retained between feedback drains; sized for several
    /// windows of worst-case traffic.
    public static let maxRetainedArrivalSamples = 512

    private let crypto: TransportCrypto
    private let lock = NSLock()
    private var channels: [UInt8: ChannelAccount] = [:]
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
            channels[failure.envelope.channel.rawValue, default: ChannelAccount()]
                .stats.unsealFailures += 1
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
        channels[envelope.channel.rawValue, default: ChannelAccount()]
            .record(envelope, payloadByteCount: plaintext.count,
                    arrivalMicroseconds: arrivalMicroseconds)
        if arrivals.count < Self.maxRetainedArrivalSamples {
            arrivals.append(ArrivalSample(
                channel: envelope.channel.rawValue,
                seq: envelope.seq.rawValue,
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
        return channels.sorted { $0.key < $1.key }.map { ($0.key, $0.value.stats) }
    }

    public func stats(forChannel channel: UInt8) -> ChannelStats? {
        lock.lock()
        defer { lock.unlock() }
        return channels[channel]?.stats
    }
}

/// Sentinels that carry a refusal out of the `openDatagram` closure.
private struct ReservedChannel: Error { var envelope: Envelope }
private struct UnsealFailure: Error { var envelope: Envelope; var underlying: Error }

/// One channel's live accounting: the gap tracker plus last-seen state the
/// snapshot derives deltas from.
private struct ChannelAccount {
    var stats = ChannelStats()
    private var tracker = SeqGapTracker()
    private var lastTimestamp: UInt64?
    private var lastArrival: UInt64?

    mutating func record(
        _ envelope: Envelope,
        payloadByteCount: Int,
        arrivalMicroseconds: UInt64
    ) {
        tracker.record(envelope.seq)
        stats.datagrams += 1
        stats.payloadBytes += UInt64(payloadByteCount)
        stats.seqHighest = tracker.highest?.rawValue
        stats.seqMissing = tracker.datagramsMissing
        stats.seqDuplicates = tracker.duplicates
        stats.seqLateFilled = tracker.lateFilled
        stats.seqBeyondWindow = tracker.beyondWindow
        stats.seqWrapEvents = tracker.wrapEvents

        let frame = envelope.frame.rawValue
        if stats.firstFrame == nil {
            stats.firstFrame = frame
        } else if stats.lastFrame != frame {
            stats.frameTransitions += 1
        }
        stats.lastFrame = frame
        stats.maxFrame = max(stats.maxFrame ?? frame, frame)

        if let last = lastTimestamp {
            stats.lastTimestampDeltaMicros = Int64(bitPattern: envelope.timestamp &- last)
        }
        lastTimestamp = envelope.timestamp
        if let last = lastArrival {
            stats.lastArrivalDeltaMicros = Int64(bitPattern: arrivalMicroseconds &- last)
        }
        lastArrival = arrivalMicroseconds
    }
}
