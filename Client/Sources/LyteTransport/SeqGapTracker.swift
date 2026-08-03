// Per-channel (chan, u16 seq) gap accounting over LyteWire's serial
// arithmetic. A sliding seen-window distinguishes a reordered late arrival
// (fills a previously counted gap) from a duplicate, so `datagramsMissing`
// converges to the true loss count under reordering — the property the
// CL-1 demux test pins with seeded shuffles across the 0xFFFF wrap.

import LyteWire

public struct SeqGapTracker: Sendable {
    /// How a recorded seq related to the stream when it arrived.
    public enum Observation: Equatable, Sendable {
        /// First datagram on the channel; establishes the reference.
        case first
        /// The next expected seq (distance +1 from the highest seen).
        case inOrder
        /// Ahead by more than one: `skipped` datagrams were jumped over.
        case gap(skipped: UInt16)
        /// Behind the highest seen, not seen before: fills a counted gap.
        case lateFill
        /// Behind the stream base near startup — the first arrival was not
        /// the stream's lowest seq; the base extends backward and the slots
        /// between count as detected gaps.
        case baseExtended
        /// Seen before (or exactly the highest again).
        case duplicate
        /// Behind by at least the window size (or the unordered 0x8000
        /// case) — too old to classify against the seen-window.
        case beyondWindow
    }

    /// Seqs tracked behind the highest; 4096 ≫ any plausible reorder depth
    /// at ≤ 3.6 s per full wrap, and small enough to clear on huge jumps.
    public static let windowSize = 4096

    public private(set) var received: UInt64 = 0
    public private(set) var duplicates: UInt64 = 0
    /// Cumulative datagrams skipped past when the highest seq advanced.
    public private(set) var gapsDetected: UInt64 = 0
    /// Gap entries later filled by reordered arrivals.
    public private(set) var lateFilled: UInt64 = 0
    /// Arrivals too far behind the highest to classify.
    public private(set) var beyondWindow: UInt64 = 0
    /// Times the highest seq crossed 0xFFFF → 0x0000.
    public private(set) var wrapEvents: UInt64 = 0
    public private(set) var highest: ChannelSeq?

    /// Datagrams currently believed lost: detected gaps minus late fills.
    public var datagramsMissing: UInt64 {
        gapsDetected >= lateFilled ? gapsDetected - lateFilled : 0
    }

    // One bit per seq in (highest - windowSize, highest], indexed by
    // rawValue % windowSize; slots are cleared as the window advances.
    private var seen = [UInt64](repeating: 0, count: SeqGapTracker.windowSize / 64)

    // The stream's lowest seq, tracked only near startup: a reordered first
    // burst delivers seqs behind the first arrival, which are not gap fills
    // but the stream's real beginning. Retired (nil) once the highest has
    // advanced a full window — by then serial distance to `base` would go
    // ambiguous, and every behind-slot has been gap-accounted anyway.
    private var base: ChannelSeq?
    private var advanceFromStart: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func record(_ seq: ChannelSeq) -> Observation {
        received += 1

        guard let high = highest else {
            highest = seq
            base = seq
            setSeen(seq)
            return .first
        }

        let distance = high.distance(to: seq)
        if distance == 0 {
            duplicates += 1
            return .duplicate
        }

        if distance > 0 {
            if seq.rawValue < high.rawValue {
                wrapEvents += 1
            }
            let skipped = UInt16(distance) - 1
            gapsDetected += UInt64(skipped)
            advanceWindow(from: high, by: distance)
            highest = seq
            setSeen(seq)
            advanceFromStart += UInt64(distance)
            if advanceFromStart >= UInt64(Self.windowSize) {
                base = nil
            }
            return skipped == 0 ? .inOrder : .gap(skipped: skipped)
        }

        // Behind the highest. Int16.min (the unordered 0x8000 case) lands
        // here too: -Int(Int16.min) is 32768, beyond any window.
        let behind = -Int(distance)
        guard behind < Self.windowSize else {
            beyondWindow += 1
            return .beyondWindow
        }
        if isSeen(seq) {
            duplicates += 1
            return .duplicate
        }
        setSeen(seq)

        // Behind the stream base: not a gap fill — the stream started
        // earlier than the first arrival. Extend the base and account the
        // slots strictly between as detected gaps (they may fill later).
        if let b = base {
            let fromBase = b.distance(to: seq)
            if fromBase < 0 {
                gapsDetected += UInt64(-Int(fromBase)) - 1
                base = seq
                return .baseExtended
            }
        }

        lateFilled += 1
        return .lateFill
    }

    // MARK: Seen-window bitmap

    private mutating func advanceWindow(from high: ChannelSeq, by distance: Int16) {
        if Int(distance) >= Self.windowSize {
            seen = [UInt64](repeating: 0, count: Self.windowSize / 64)
            return
        }
        var cursor = high
        for _ in 0..<distance {
            cursor = cursor.next
            clearSeen(cursor)
        }
    }

    private func slot(_ seq: ChannelSeq) -> (word: Int, bit: UInt64) {
        let index = Int(seq.rawValue) % Self.windowSize
        return (index / 64, 1 << UInt64(index % 64))
    }

    private func isSeen(_ seq: ChannelSeq) -> Bool {
        let s = slot(seq)
        return seen[s.word] & s.bit != 0
    }

    private mutating func setSeen(_ seq: ChannelSeq) {
        let s = slot(seq)
        seen[s.word] |= s.bit
    }

    private mutating func clearSeen(_ seq: ChannelSeq) {
        let s = slot(seq)
        seen[s.word] &= ~s.bit
    }
}
