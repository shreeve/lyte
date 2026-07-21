// The (chan, seq) demux: every received datagram funnels through
// `ingest` — envelope decode via LyteWire, reserved-channel drop, the
// TransportCrypto unseal, then per-channel seq/frame/timestamp accounting.
// Thread-safe: the endpoint's receive thread writes, anyone may snapshot.

import Foundation
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
    public var seqMissing: UInt64 = 0
    public var seqDuplicates: UInt64 = 0
    public var seqLateFilled: UInt64 = 0
    public var seqBeyondWindow: UInt64 = 0
    public var seqWrapEvents: UInt64 = 0

    public var firstFrame: UInt32?
    public var lastFrame: UInt32?
    public var maxFrame: UInt32?
    /// Consecutive-arrival frame-number changes — approximates frames seen
    /// while shards of one frame arrive together (exact once CL-2 assembles).
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
}

public final class ReceiveDemux: @unchecked Sendable {
    private let crypto: TransportCrypto
    private let lock = NSLock()
    private var channels: [UInt8: ChannelAccount] = [:]
    private var totals = DemuxTotals()

    public init(crypto: TransportCrypto) {
        self.crypto = crypto
    }

    /// Feeds one raw datagram. `arrivalMicroseconds` is the client-monotonic
    /// arrival instant (kernel stamp when available).
    @discardableResult
    public func ingest(
        datagram: ArraySlice<UInt8>,
        arrivalMicroseconds: UInt64
    ) -> IngestOutcome {
        lock.lock()
        defer { lock.unlock() }
        totals.datagrams += 1

        let envelope: Envelope
        let payload: ArraySlice<UInt8>
        do {
            (envelope, payload) = try Envelope.decode(datagram)
        } catch let error as WireError {
            totals.malformed += 1
            return .malformed(error)
        } catch {
            totals.malformed += 1
            return .malformed(.truncatedEnvelope)
        }

        guard !envelope.channel.isReserved else {
            totals.reservedDropped += 1
            return .reservedChannel(envelope.channel.rawValue)
        }

        // The header rides as AAD: exactly the received bytes ahead of the
        // payload, fixed envelope + TLV block.
        let aad = datagram[datagram.startIndex..<payload.startIndex]
        let plaintext: ArraySlice<UInt8>
        do {
            plaintext = try crypto.unseal(wirePayload: payload, aad: aad, envelope: envelope)
        } catch {
            totals.unsealFailures += 1
            channels[envelope.channel.rawValue, default: ChannelAccount()].stats.unsealFailures += 1
            return .unsealFailed(error)
        }

        totals.accepted += 1
        channels[envelope.channel.rawValue, default: ChannelAccount()]
            .record(envelope, payloadByteCount: plaintext.count,
                    arrivalMicroseconds: arrivalMicroseconds)
        return .accepted(envelope: envelope, payload: Array(plaintext))
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
