// The chan=3 feedback report the client sends every 25–50 ms (telemetry
// class, unreliable; a lost report is superseded by the next). It carries:
//
// - per-channel receive ledgers (loss/duplicate accounting),
// - burst-dispersion samples — per-packet arrival times for paced packet
//   trains (RFC 8888 semantics, compact encoding),
// - NACK entries naming FEC-impossible frames' missing shards,
// - the client clock at report build, and a path ID byte (0 in v1).
//
// Layout, all multi-byte fields little-endian. Fixed 21-byte header:
//
//   offset size field
//   0      1    pathId          0 in v1; carried verbatim either way
//   1      1    flags           bit0: TLV block present; bits 1–7
//                               reserved, MUST be 0 on send, ignored on
//                               receive
//   2      8    clientTimestamp client monotonic µs at report build
//   10     8    dispersionBase  client µs base for sample deltas; MUST be
//                               0 when sampleCount is 0 (rejects otherwise)
//   18     1    channelBlockCount   0…8
//   19     1    sampleCount         0…112
//   20     1    nackCount           0…6
//
// then the variable sections, in this order:
//
//   channel block, 15 bytes × channelBlockCount:
//     chan:u8  highestSeq:u16  received:u32  missing:u32  duplicates:u32
//     (cumulative session counters; u32 wraps in days at peak rate and
//     the host differences successive reports, so wrap is harmless)
//
//   dispersion sample, 6 bytes × sampleCount:
//     chan:u8  seq:u16  arrivalDelta:u24
//     (arrival = dispersionBase + delta µs; u24 spans 16.7 s — a delta
//     that does not fit rejects at encode rather than truncating)
//
//   NACK entry, (5 + bitmapByteCount) bytes × nackCount:
//     frame:u32  bitmapByteCount:u8  bitmap
//     (bit n of the bitmap — byte n/8, bit n%8 — set means shard index n
//     of that frame's FEC group is missing; 1…32 bytes covers the
//     255-shard GF(2⁸) block; the bitmap is canonical: sized by the
//     highest set bit, so a zero final byte rejects)
//
//   TLV block when flags bit0 (the envelope's scheme):
//   count:u8 (type:u8 len:u8 value)*; unknown types preserved verbatim.
//
// The payload is exactly the report: trailing bytes reject. FeedbackBounds
// cap the structural encoding at 1035 bytes; encode also enforces the
// 1112 B shard ceiling so a fat TLV set can never produce an unsendable
// datagram.

public enum FeedbackBounds {
    /// Channel blocks per report: the 5 registered channels plus feature
    /// headroom.
    public static let maxChannelBlocks = 8
    /// Dispersion samples per report: a worst-case protected IDR train
    /// (~80 data + ~20 parity shards) plus a 50 ms window's audio, with
    /// slack. Senders with more arrivals decimate.
    public static let maxDispersionSamples = 112
    /// NACK entries per report: more than 6 FEC-impossible frames in
    /// flight means the stream needs an IDR, not NACK repair.
    public static let maxNackEntries = 6
    /// ceil(255 / 8): one GF(2⁸) FEC block's worth of shard indices.
    public static let maxNackBitmapByteCount = 32
    /// The u24 sample-delta ceiling, µs.
    public static let maxArrivalDeltaMicroseconds: UInt32 = 0xFF_FFFF

    public static let fixedHeaderByteCount = 21
    public static let channelBlockByteCount = 15
    public static let dispersionSampleByteCount = 6

    /// The structural worst case (all bounds maxed, no TLVs): 21 + 8×15 +
    /// 112×6 + 6×37 = 1035, comfortably inside the 1112 B shard budget.
    public static let maxEncodedByteCountWithoutExtensions =
        fixedHeaderByteCount
        + maxChannelBlocks * channelBlockByteCount
        + maxDispersionSamples * dispersionSampleByteCount
        + maxNackEntries * (5 + maxNackBitmapByteCount)
}

public struct FeedbackReport: Hashable, Sendable, SliceDecodable {
    /// One channel's cumulative receive ledger.
    public struct ChannelStats: Hashable, Sendable {
        public var channel: ChannelId
        /// Highest seq seen on the channel (serial order).
        public var highestSeq: ChannelSeq
        /// Cumulative datagrams received (duplicates not counted).
        public var received: UInt32
        /// Cumulative gaps: datagrams the seq stream says existed but
        /// never arrived.
        public var missing: UInt32
        /// Cumulative duplicate arrivals.
        public var duplicates: UInt32

        public init(
            channel: ChannelId,
            highestSeq: ChannelSeq,
            received: UInt32,
            missing: UInt32,
            duplicates: UInt32
        ) {
            self.channel = channel
            self.highestSeq = highestSeq
            self.received = received
            self.missing = missing
            self.duplicates = duplicates
        }
    }

    /// The arrival-dispersion section: a base instant plus per-packet
    /// deltas. Absent entirely (nil) when the window saw nothing worth
    /// sampling; present means at least one sample.
    public struct Dispersion: Hashable, Sendable {
        public struct Sample: Hashable, Sendable {
            public var channel: ChannelId
            public var seq: ChannelSeq
            /// Arrival µs minus the section base; must fit u24.
            public var arrivalDeltaMicroseconds: UInt32

            public init(
                channel: ChannelId,
                seq: ChannelSeq,
                arrivalDeltaMicroseconds: UInt32
            ) {
                self.channel = channel
                self.seq = seq
                self.arrivalDeltaMicroseconds = arrivalDeltaMicroseconds
            }
        }

        /// Client monotonic µs the deltas are measured from.
        public var base: ClientTimestamp
        public var samples: [Sample]

        public init(base: ClientTimestamp, samples: [Sample]) {
            self.base = base
            self.samples = samples
        }
    }

    /// One FEC-impossible frame and its missing shard indices.
    public struct NackEntry: Hashable, Sendable {
        public var frame: FrameNumber
        /// Sorted, unique, non-empty; values are FEC shard indices,
        /// 0…255 on the wire. Consumers bound them by the frame's
        /// geometry (a GF(2⁸) block holds at most 255 shards).
        public private(set) var missingShards: [UInt8]

        /// Canonicalizes (sorts, dedupes) and refuses an empty list — a
        /// NACK that names nothing is some layer's bookkeeping bug.
        public init(frame: FrameNumber, missingShards: [UInt8]) throws {
            guard !missingShards.isEmpty else {
                throw FeedbackError.emptyNackShardList
            }
            self.frame = frame
            self.missingShards = Array(Set(missingShards)).sorted()
        }

        /// Bitmap bytes, sized by the highest set index (canonical form).
        var bitmap: [UInt8] {
            wireCanonicalBitmap(missingShards.map(Int.init))
        }
    }

    /// 0 in v1; the codec carries any value verbatim.
    public var pathId: UInt8
    /// Client monotonic µs at report build.
    public var clientTimestamp: ClientTimestamp
    public var channels: [ChannelStats]
    public var dispersion: Dispersion?
    public var nacks: [NackEntry]
    /// TLV extensions, unknown types preserved verbatim.
    public var extensions: [WireExtension]

    public init(
        pathId: UInt8 = 0,
        clientTimestamp: ClientTimestamp,
        channels: [ChannelStats] = [],
        dispersion: Dispersion? = nil,
        nacks: [NackEntry] = [],
        extensions: [WireExtension] = []
    ) {
        self.pathId = pathId
        self.clientTimestamp = clientTimestamp
        self.channels = channels
        self.dispersion = dispersion
        self.nacks = nacks
        self.extensions = extensions
    }

    private static let extensionsFlag: UInt8 = 0x01

    // MARK: Encode

    /// Encodes the report, enforcing every FeedbackBounds limit and the
    /// 1112 B plaintext shard budget. The result is the whole chan=3
    /// datagram payload.
    public func encode() throws -> [UInt8] {
        guard channels.count <= FeedbackBounds.maxChannelBlocks else {
            throw FeedbackError.tooManyChannelBlocks(channels.count)
        }
        let samples = dispersion?.samples ?? []
        if dispersion != nil {
            guard !samples.isEmpty else {
                throw FeedbackError.emptyDispersionSection
            }
        }
        guard samples.count <= FeedbackBounds.maxDispersionSamples else {
            throw FeedbackError.tooManyDispersionSamples(samples.count)
        }
        for sample in samples {
            guard sample.arrivalDeltaMicroseconds
                <= FeedbackBounds.maxArrivalDeltaMicroseconds
            else {
                throw FeedbackError.arrivalDeltaOutOfRange(
                    sample.arrivalDeltaMicroseconds
                )
            }
        }
        guard nacks.count <= FeedbackBounds.maxNackEntries else {
            throw FeedbackError.tooManyNackEntries(nacks.count)
        }
        guard extensions.count <= 0xFF else {
            throw FeedbackError.tooManyExtensions
        }

        var out = [UInt8]()
        out.append(pathId)
        out.append(extensions.isEmpty ? 0 : Self.extensionsFlag)
        wireAppendLE(clientTimestamp.microseconds, to: &out)
        wireAppendLE(dispersion?.base.microseconds ?? 0, to: &out)
        out.append(UInt8(channels.count))
        out.append(UInt8(samples.count))
        out.append(UInt8(nacks.count))

        for stats in channels {
            out.append(stats.channel.rawValue)
            wireAppendLE(stats.highestSeq.rawValue, to: &out)
            wireAppendLE(stats.received, to: &out)
            wireAppendLE(stats.missing, to: &out)
            wireAppendLE(stats.duplicates, to: &out)
        }
        for sample in samples {
            out.append(sample.channel.rawValue)
            wireAppendLE(sample.seq.rawValue, to: &out)
            wireAppendLE24(sample.arrivalDeltaMicroseconds, to: &out)
        }
        for nack in nacks {
            wireAppendLE(nack.frame.rawValue, to: &out)
            let bitmap = nack.bitmap
            out.append(UInt8(bitmap.count))
            out.append(contentsOf: bitmap)
        }
        if !extensions.isEmpty {
            WireExtension.appendBlock(extensions, to: &out)
        }

        guard out.count <= WireBudget.maxPlaintextShardByteCount else {
            throw FeedbackError.reportOverBudget(out.count)
        }
        return out
    }

    // MARK: Decode

    /// Decodes a whole chan=3 payload. Throws on truncation, trailing
    /// bytes, out-of-bounds section counts, non-canonical NACK bitmaps,
    /// and a non-zero base without samples; reserved flag bits are
    /// ignored and unknown TLV types decode successfully. Never traps on
    /// hostile bytes.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> FeedbackReport {
        var reader = WireReader(
            payload, truncated: FeedbackError.truncatedReport)
        let pathId = try reader.u8()
        let flags = try reader.u8()
        let clientTimestamp = try reader.u64()
        let dispersionBase = try reader.u64()
        let channelCount = Int(try reader.u8())
        let sampleCount = Int(try reader.u8())
        let nackCount = Int(try reader.u8())

        guard channelCount <= FeedbackBounds.maxChannelBlocks else {
            throw FeedbackError.tooManyChannelBlocks(channelCount)
        }
        guard sampleCount <= FeedbackBounds.maxDispersionSamples else {
            throw FeedbackError.tooManyDispersionSamples(sampleCount)
        }
        guard nackCount <= FeedbackBounds.maxNackEntries else {
            throw FeedbackError.tooManyNackEntries(nackCount)
        }
        if sampleCount == 0 {
            guard dispersionBase == 0 else {
                throw FeedbackError.nonZeroBaseWithoutSamples
            }
        }

        var channels = [ChannelStats]()
        channels.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            channels.append(
                ChannelStats(
                    channel: ChannelId(rawValue: try reader.u8()),
                    highestSeq: ChannelSeq(rawValue: try reader.u16()),
                    received: try reader.u32(),
                    missing: try reader.u32(),
                    duplicates: try reader.u32()
                )
            )
        }

        var samples = [Dispersion.Sample]()
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            samples.append(
                Dispersion.Sample(
                    channel: ChannelId(rawValue: try reader.u8()),
                    seq: ChannelSeq(rawValue: try reader.u16()),
                    arrivalDeltaMicroseconds: try reader.u24()
                )
            )
        }

        var nacks = [NackEntry]()
        nacks.reserveCapacity(nackCount)
        for _ in 0..<nackCount {
            let frame = FrameNumber(rawValue: try reader.u32())
            let bitmapByteCount = Int(try reader.u8())
            guard bitmapByteCount >= 1,
                  bitmapByteCount <= FeedbackBounds.maxNackBitmapByteCount
            else {
                throw FeedbackError.nackBitmapByteCountOutOfRange(bitmapByteCount)
            }
            let bitmap = try reader.bytes(bitmapByteCount)
            guard bitmap.last! != 0 else {
                throw FeedbackError.nonCanonicalNackBitmap
            }
            nacks.append(try NackEntry(
                frame: frame,
                missingShards: wireBitmapOffsets(bitmap).map(UInt8.init)
            ))
        }

        var extensions = [WireExtension]()
        if flags & extensionsFlag != 0 {
            extensions = try WireExtension.readBlock(from: &reader)
        }

        guard reader.isAtEnd else {
            throw FeedbackError.trailingBytes
        }

        return FeedbackReport(
            pathId: pathId,
            clientTimestamp: ClientTimestamp(microseconds: clientTimestamp),
            channels: channels,
            dispersion: samples.isEmpty
                ? nil
                : Dispersion(
                    base: ClientTimestamp(microseconds: dispersionBase),
                    samples: samples
                ),
            nacks: nacks,
            extensions: extensions
        )
    }
}

/// Everything the feedback codec can refuse: bounds violations and hostile
/// bytes throw — never trap, never truncate silently.
public enum FeedbackError: Error, Equatable, Sendable {
    /// Fewer bytes than the header + counts promise.
    case truncatedReport
    /// Bytes past the report's end: the payload is exactly the report.
    case trailingBytes
    /// Channel blocks over FeedbackBounds.maxChannelBlocks.
    case tooManyChannelBlocks(Int)
    /// Dispersion samples over FeedbackBounds.maxDispersionSamples.
    case tooManyDispersionSamples(Int)
    /// NACK entries over FeedbackBounds.maxNackEntries.
    case tooManyNackEntries(Int)
    /// A Dispersion section with zero samples: use nil instead.
    case emptyDispersionSection
    /// A sample delta that does not fit the u24 field.
    case arrivalDeltaOutOfRange(UInt32)
    /// sampleCount 0 but dispersionBase non-zero.
    case nonZeroBaseWithoutSamples
    /// A NACK entry naming no shards.
    case emptyNackShardList
    /// bitmapByteCount outside 1…32.
    case nackBitmapByteCountOutOfRange(Int)
    /// A NACK bitmap whose final byte is zero: the bitmap is sized by its
    /// highest set bit, so a zero tail means the sender miscounted.
    case nonCanonicalNackBitmap
    /// More than 255 TLVs; the count prefix is one byte.
    case tooManyExtensions
    /// The encoded report exceeds the 1112 B plaintext shard budget
    /// (only reachable through the TLV section; the structural bounds
    /// cap everything else at 1035 B).
    case reportOverBudget(Int)
}
