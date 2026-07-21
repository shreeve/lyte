// The chan=3 feedback report (W4a): the one datagram payload the client
// sends every 25–50 ms (build plan §4.11 — telemetry class, unreliable by
// design; a lost report is superseded by the next). It carries everything
// the host's estimator and NACK responder consume:
//
// - per-channel receive ledgers (loss/duplicate accounting, HS-16's
//   post-FEC loss regime input),
// - burst-dispersion samples — per-packet arrival timestamps for the
//   packet trains the sender paced, resiliency §2.2's delivery-rate and
//   queue-gradient measurement (RFC 8888 semantics, compact encoding),
// - NACK entries naming FEC-impossible frames' missing shards
//   (resiliency §1.1 rule 2; emitted from CL-3, honored at HS-17),
// - the client clock at report build, and a path ID byte (0 in v1) so
//   multi-path later is new instances, not a wire change (resiliency §6).
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
//                               0 when sampleCount is 0 (loud fill-bug
//                               rule), non-zero base without samples
//                               rejects
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
//     (arrival = dispersionBase + delta µs; u24 spans 16.7 s, far beyond
//     any 25–50 ms report window — a delta that does not fit rejects at
//     encode rather than silently truncating)
//
//   NACK entry, (5 + bitmapByteCount) bytes × nackCount:
//     frame:u32  bitmapByteCount:u8  bitmap
//     (bit n of the bitmap — byte n/8, bit n%8 — set means shard index n
//     of that frame's FEC group is missing; 1…32 bytes covers the
//     255-shard GF(2⁸) block; the bitmap is canonical: sized by the
//     highest set bit, so a zero final byte rejects)
//
//   TLV block when flags bit0 (the envelope's exact scheme, WireExtension
//   types): count:u8 (type:u8 len:u8 value)* — the escape hatch for v1.x
//   fields this slice cannot foresee; unknown types are skipped by
//   consumers and preserved verbatim by the codec.
//
// The payload is exactly the report: trailing bytes reject. Budget: the
// section bounds (FeedbackBounds) cap the structural encoding at 1035
// bytes — inside the 1112 B plaintext shard budget with 77 bytes of TLV
// headroom — and encode additionally enforces the 1112 B ceiling so a fat
// TLV set can never produce an unsendable datagram.

public enum FeedbackBounds {
    /// Channel blocks per report: the 5 registered channels plus feature
    /// headroom.
    public static let maxChannelBlocks = 8
    /// Dispersion samples per report: a worst-case protected IDR train
    /// (~80 data + ~20 parity shards, resiliency §2.2's "superb chirp")
    /// plus the 10-packet audio probe of a 50 ms window, with slack.
    /// Senders with more arrivals than this decimate; the estimator
    /// weights trains, it does not need every packet.
    public static let maxDispersionSamples = 112
    /// NACK entries per report: more than 6 FEC-impossible frames in
    /// flight means the stream is past NACK repair and into IDR-request
    /// territory (resiliency §1.1 rule 4) anyway.
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

public struct FeedbackReport: Hashable, Sendable {
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
        /// Sorted, unique, non-empty; values are FEC shard indices
        /// (0…254, the GF(2⁸) block).
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
            let byteCount = Int(missingShards.last!) / 8 + 1
            var bytes = [UInt8](repeating: 0, count: byteCount)
            for index in missingShards {
                bytes[Int(index) / 8] |= 1 << (index % 8)
            }
            return bytes
        }
    }

    /// 0 in v1 (resiliency §6); the codec carries any value verbatim.
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
            out.append(UInt8(extensions.count))
            for ext in extensions {
                out.append(ext.type)
                out.append(UInt8(ext.value.count))
                out.append(contentsOf: ext.value)
            }
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
        guard payload.count >= FeedbackBounds.fixedHeaderByteCount else {
            throw FeedbackError.truncatedReport
        }
        let base = payload.startIndex
        let pathId = payload[base]
        let flags = payload[base + 1]
        let clientTimestamp: UInt64 = wireReadLE(payload, at: base + 2)
        let dispersionBase: UInt64 = wireReadLE(payload, at: base + 10)
        let channelCount = Int(payload[base + 18])
        let sampleCount = Int(payload[base + 19])
        let nackCount = Int(payload[base + 20])

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

        var cursor = base + FeedbackBounds.fixedHeaderByteCount

        var channels = [ChannelStats]()
        channels.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            guard cursor + FeedbackBounds.channelBlockByteCount <= payload.endIndex else {
                throw FeedbackError.truncatedReport
            }
            channels.append(
                ChannelStats(
                    channel: ChannelId(rawValue: payload[cursor]),
                    highestSeq: ChannelSeq(rawValue: wireReadLE(payload, at: cursor + 1)),
                    received: wireReadLE(payload, at: cursor + 3),
                    missing: wireReadLE(payload, at: cursor + 7),
                    duplicates: wireReadLE(payload, at: cursor + 11)
                )
            )
            cursor += FeedbackBounds.channelBlockByteCount
        }

        var samples = [Dispersion.Sample]()
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            guard cursor + FeedbackBounds.dispersionSampleByteCount <= payload.endIndex else {
                throw FeedbackError.truncatedReport
            }
            samples.append(
                Dispersion.Sample(
                    channel: ChannelId(rawValue: payload[cursor]),
                    seq: ChannelSeq(rawValue: wireReadLE(payload, at: cursor + 1)),
                    arrivalDeltaMicroseconds: wireReadLE24(payload, at: cursor + 3)
                )
            )
            cursor += FeedbackBounds.dispersionSampleByteCount
        }

        var nacks = [NackEntry]()
        nacks.reserveCapacity(nackCount)
        for _ in 0..<nackCount {
            guard cursor + 5 <= payload.endIndex else {
                throw FeedbackError.truncatedReport
            }
            let frame = FrameNumber(rawValue: wireReadLE(payload, at: cursor))
            let bitmapByteCount = Int(payload[cursor + 4])
            cursor += 5
            guard bitmapByteCount >= 1,
                  bitmapByteCount <= FeedbackBounds.maxNackBitmapByteCount
            else {
                throw FeedbackError.nackBitmapByteCountOutOfRange(bitmapByteCount)
            }
            guard cursor + bitmapByteCount <= payload.endIndex else {
                throw FeedbackError.truncatedReport
            }
            let bitmap = payload[cursor..<cursor + bitmapByteCount]
            cursor += bitmapByteCount
            guard bitmap.last! != 0 else {
                throw FeedbackError.nonCanonicalNackBitmap
            }
            var missing = [UInt8]()
            for (byteOffset, byte) in bitmap.enumerated() {
                for bit in 0..<8 where byte & (1 << bit) != 0 {
                    missing.append(UInt8(byteOffset * 8 + bit))
                }
            }
            nacks.append(try NackEntry(frame: frame, missingShards: missing))
        }

        var extensions = [WireExtension]()
        if flags & extensionsFlag != 0 {
            guard cursor < payload.endIndex else {
                throw FeedbackError.truncatedReport
            }
            let count = Int(payload[cursor])
            cursor += 1
            extensions.reserveCapacity(count)
            for _ in 0..<count {
                guard cursor + 2 <= payload.endIndex else {
                    throw FeedbackError.truncatedReport
                }
                let type = payload[cursor]
                let length = Int(payload[cursor + 1])
                cursor += 2
                guard cursor + length <= payload.endIndex else {
                    throw FeedbackError.truncatedReport
                }
                extensions.append(
                    try WireExtension(
                        type: type,
                        value: Array(payload[cursor..<cursor + length])
                    )
                )
                cursor += length
            }
        }

        guard cursor == payload.endIndex else {
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

    public static func decode(_ payload: [UInt8]) throws -> FeedbackReport {
        try decode(payload[...])
    }
}

/// Everything the feedback codec can refuse. Same doctrine as WireError:
/// bounds violations and hostile bytes throw — never trap, never truncate
/// silently.
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
    /// sampleCount 0 but dispersionBase non-zero — a fill bug, kept loud.
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
