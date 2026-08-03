// The ARQ frame codecs (W3): the wire format of the reliable
// ordered-retransmit sublayer that CTRL, video-idle, and the feature
// channels ride (decision record §8.1). Two frame types, registered in
// the CTRL type space and used identically on every reliable channel:
//
//   0x07  data segment — one slice of one message in one group
//   0x08  ACK — cumulative + bitmap receive state per (chan, group)
//
// A reliable-channel datagram whose payload starts with either byte is
// wholly ARQ: the payload is a SEQUENCE of self-delimiting frames (an
// ACK piggybacks ahead of fresh segments in one datagram). ARQ-exempt
// CTRL traffic (beacons, path messages, handshake, IDR requests) never
// starts with these bytes, so the shell's one-byte peek routes cleanly.
//
// Sequencing is GROUP-SCOPED, not channel-scoped, and that is the load-
// bearing decision: envelope seqs on a reliable channel are shared with
// ARQ-exempt traffic, so a channel-scoped cumulative ACK could never be
// honest. Each group numbers its own segments with a serial u16 from 0
// (wire v1), which is also what makes groups independent — a fully-lost
// group leaves no hole in any other group's sequence space.
//
// Retransmission discipline (refining core-plan pin §2.2): the
// retransmission unit is the SEGMENT, re-sent byte-identical inside a
// FRESH datagram (fresh envelope seq, fresh AEAD nonce). The pin's
// guarantees survive intact — no plaintext is ever sealed twice under
// one nonce, the receiver admits each segment exactly once (dedupe is
// by group seq, not envelope seq), and ACK ambiguity cannot arise
// because ACKs name group seqs. What the refinement buys is liveness:
// a byte-identical DATAGRAM resend would re-enter the Noise replay
// window under its old counter and be rejected as stale once the
// channel had moved 64 datagrams on — a hazard, not a feature.
//
// Segment frame, fixed 8-byte header then body, little-endian:
//
//   offset size field
//   0      1    type          0x07
//   1      1    flags         bit0: endOfMessage — this segment ends a
//                             message; bits 1–7 reserved, MUST be 0 on
//                             send, ignored on receive
//   2      2    group         u16; 0 = the long-lived ordered stream,
//                             non-zero = a one-shot message group
//   4      2    segSeq        u16 group-scoped serial segment sequence
//   6      2    bodyLen       u16, 1…1104 (a zero-length segment is
//                             some layer's fill bug, kept loud)
//   8      …    body
//
// ACK frame, 3-byte header then blocks:
//
//   offset size field
//   0      1    type          0x08
//   1      1    flags         reserved, 0 on send, ignored on receive
//   2      1    blockCount    1…16
//
//   block (6 + bitmapLen bytes):
//   0      1    chan          the channel whose group this describes
//   1      2    group         u16
//   3      2    cumulative    u16: every segSeq serially ≤ this was
//                             received ("nothing yet" = initial − 1)
//   5      1    bitmapLen     u8 0…32
//   6      …    bitmap        bit n (byte n/8, bit n%8) set means
//                             segSeq cumulative+1+n was received;
//                             canonical: the final byte is non-zero
//
// An ACK is itself ARQ-exempt — a lost ACK is superseded by the next
// (the receiver re-ACKs on every arrival, duplicates included).

/// An ARQ group: 0 is the channel's long-lived ordered message stream;
/// any other value is an independent one-shot group carrying exactly one
/// message (a sparse idle frame, the final ratchet frame) — no group
/// ever waits on another (decision record §8.1).
public struct ArqGroupId: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The long-lived ordered message stream (CTRL, feature channels).
    public static let orderedStream = ArqGroupId(rawValue: 0)

    public var isOneShot: Bool {
        rawValue != 0
    }
}

/// A group-scoped segment sequence: serial u16 (RFC 1982 shape, the
/// ChannelSeq discipline). Wire v1 starts every group at 0; windows are
/// far below the 0x8000 half-space so comparisons stay unambiguous.
public struct ArqSegmentSeq: RawRepresentable, Hashable, Comparable, Sendable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public var next: ArqSegmentSeq {
        ArqSegmentSeq(rawValue: rawValue &+ 1)
    }

    /// Signed serial distance from `self` to `other`, through the wrap.
    public func distance(to other: ArqSegmentSeq) -> Int16 {
        Int16(bitPattern: other.rawValue &- rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.distance(to: rhs) > 0
    }
}

/// Structural bounds of the ARQ wire format. The endpoint's runtime
/// windows (ArqConfig) must fit inside these.
public enum ArqBounds {
    public static let segmentHeaderByteCount = 8
    /// The largest body that keeps a lone segment frame inside the
    /// 1112 B plaintext shard budget: 1112 − 8.
    public static let maxSegmentBodyByteCount =
        WireBudget.maxPlaintextShardByteCount - segmentHeaderByteCount
    public static let ackHeaderByteCount = 3
    public static let ackBlockFixedByteCount = 6
    /// Blocks per ACK frame; an endpoint with more groups to report
    /// emits additional frames.
    public static let maxAckBlocks = 16
    /// ceil(256 / 8): the bitmap describes at most 256 seqs past the
    /// cumulative, which is therefore the widest expressible receive
    /// window.
    public static let maxAckBitmapByteCount = 32
    /// The widest receive window an ACK can describe.
    public static let maxReceiveWindowSegments = maxAckBitmapByteCount * 8
}

/// One data segment: one slice of one message in one group.
public struct ArqSegment: Hashable, Sendable {
    public var group: ArqGroupId
    public var seq: ArqSegmentSeq
    /// This segment is the last of its message.
    public var endOfMessage: Bool
    public var body: [UInt8]

    /// Refuses empty and over-budget bodies, so `encode` cannot fail.
    public init(
        group: ArqGroupId,
        seq: ArqSegmentSeq,
        endOfMessage: Bool,
        body: [UInt8]
    ) throws {
        guard !body.isEmpty else {
            throw ArqFrameError.zeroLengthSegmentBody
        }
        guard body.count <= ArqBounds.maxSegmentBodyByteCount else {
            throw ArqFrameError.segmentBodyOverBudget(body.count)
        }
        self.group = group
        self.seq = seq
        self.endOfMessage = endOfMessage
        self.body = body
    }

    static let endOfMessageFlag: UInt8 = 0x01

    public var encodedByteCount: Int {
        ArqBounds.segmentHeaderByteCount + body.count
    }

    /// Encodes the frame, type byte included. Cannot fail (the init
    /// enforced the bounds).
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(encodedByteCount)
        out.append(CtrlMessageType.arqSegment)
        out.append(endOfMessage ? Self.endOfMessageFlag : 0)
        wireAppendLE(group.rawValue, to: &out)
        wireAppendLE(seq.rawValue, to: &out)
        wireAppendLE(UInt16(body.count), to: &out)
        out.append(contentsOf: body)
        return out
    }
}

/// One ACK frame: receive state for up to 16 (chan, group) pairs.
public struct ArqAck: Hashable, Sendable {
    /// One group's receive state.
    public struct Block: Hashable, Sendable {
        public var channel: ChannelId
        public var group: ArqGroupId
        /// Every segSeq serially ≤ this was received; a group that has
        /// received nothing in order reports initialSeq − 1.
        public var cumulative: ArqSegmentSeq
        /// Bit n set = segSeq cumulative+1+n received. Canonical: sized
        /// by the highest set bit (empty when nothing past cumulative).
        public private(set) var receivedBitmap: [UInt8]

        /// Refuses over-long and non-canonical bitmaps.
        public init(
            channel: ChannelId,
            group: ArqGroupId,
            cumulative: ArqSegmentSeq,
            receivedBitmap: [UInt8] = []
        ) throws {
            guard receivedBitmap.count <= ArqBounds.maxAckBitmapByteCount else {
                throw ArqFrameError.ackBitmapTooLong(receivedBitmap.count)
            }
            if let last = receivedBitmap.last {
                guard last != 0 else {
                    throw ArqFrameError.nonCanonicalAckBitmap
                }
            }
            self.channel = channel
            self.group = group
            self.cumulative = cumulative
            self.receivedBitmap = receivedBitmap
        }

        /// The seqs the bitmap marks received, past the cumulative.
        public var bitmapSeqs: [ArqSegmentSeq] {
            var seqs: [ArqSegmentSeq] = []
            for (byteOffset, byte) in receivedBitmap.enumerated() {
                for bit in 0..<8 where byte & (1 << bit) != 0 {
                    seqs.append(ArqSegmentSeq(
                        rawValue: cumulative.rawValue &+ 1
                            &+ UInt16(byteOffset * 8 + bit)
                    ))
                }
            }
            return seqs
        }

        /// The serially highest seq this block reports received:
        /// the top bitmap bit, or the cumulative when the bitmap is
        /// empty (which may itself mean "nothing", initial − 1 — the
        /// consumer's serial arithmetic handles that uniformly).
        public var highestReported: ArqSegmentSeq {
            guard let lastByte = receivedBitmap.last else { return cumulative }
            let topBit = 7 - lastByte.leadingZeroBitCount
            let offset = (receivedBitmap.count - 1) * 8 + topBit
            return ArqSegmentSeq(
                rawValue: cumulative.rawValue &+ 1 &+ UInt16(offset)
            )
        }

        public var encodedByteCount: Int {
            ArqBounds.ackBlockFixedByteCount + receivedBitmap.count
        }
    }

    public private(set) var blocks: [Block]

    /// Refuses empty and over-long block lists.
    public init(blocks: [Block]) throws {
        guard !blocks.isEmpty else {
            throw ArqFrameError.zeroAckBlocks
        }
        guard blocks.count <= ArqBounds.maxAckBlocks else {
            throw ArqFrameError.tooManyAckBlocks(blocks.count)
        }
        self.blocks = blocks
    }

    public var encodedByteCount: Int {
        ArqBounds.ackHeaderByteCount
            + blocks.reduce(0) { $0 + $1.encodedByteCount }
    }

    /// Encodes the frame, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(encodedByteCount)
        out.append(CtrlMessageType.arqAck)
        out.append(0)
        out.append(UInt8(blocks.count))
        for block in blocks {
            out.append(block.channel.rawValue)
            wireAppendLE(block.group.rawValue, to: &out)
            wireAppendLE(block.cumulative.rawValue, to: &out)
            out.append(UInt8(block.receivedBitmap.count))
            out.append(contentsOf: block.receivedBitmap)
        }
        return out
    }
}

/// One parsed ARQ frame; a datagram payload is a sequence of these.
public enum ArqFrame: Hashable, Sendable {
    case segment(ArqSegment)
    case ack(ArqAck)

    public var encodedByteCount: Int {
        switch self {
        case .segment(let segment): return segment.encodedByteCount
        case .ack(let ack): return ack.encodedByteCount
        }
    }

    public func encode() -> [UInt8] {
        switch self {
        case .segment(let segment): return segment.encode()
        case .ack(let ack): return ack.encode()
        }
    }

    /// Encodes a frame sequence into one datagram payload, enforcing
    /// the 1112 B plaintext shard budget.
    public static func encodeAll(_ frames: [ArqFrame]) throws -> [UInt8] {
        guard !frames.isEmpty else {
            throw ArqFrameError.emptyPayload
        }
        var out = [UInt8]()
        for frame in frames {
            out.append(contentsOf: frame.encode())
        }
        guard out.count <= WireBudget.maxPlaintextShardByteCount else {
            throw ArqFrameError.payloadOverBudget(out.count)
        }
        return out
    }

    /// Decodes a whole reliable-channel datagram payload into its frame
    /// sequence. Throws on truncation, unknown frame types, zero-length
    /// bodies, malformed ACK bounds, and empty payloads; never traps on
    /// hostile bytes. Reserved flag bits are ignored.
    public static func decodeAll(
        _ payload: ArraySlice<UInt8>
    ) throws -> [ArqFrame] {
        guard !payload.isEmpty else {
            throw ArqFrameError.emptyPayload
        }
        var frames: [ArqFrame] = []
        var cursor = payload.startIndex
        while cursor < payload.endIndex {
            switch payload[cursor] {
            case CtrlMessageType.arqSegment:
                let (segment, next) = try decodeSegment(payload, at: cursor)
                frames.append(.segment(segment))
                cursor = next
            case CtrlMessageType.arqAck:
                let (ack, next) = try decodeAck(payload, at: cursor)
                frames.append(.ack(ack))
                cursor = next
            default:
                throw ArqFrameError.unknownFrameType(payload[cursor])
            }
        }
        return frames
    }

    public static func decodeAll(_ payload: [UInt8]) throws -> [ArqFrame] {
        try decodeAll(payload[...])
    }

    private static func decodeSegment(
        _ payload: ArraySlice<UInt8>, at start: Int
    ) throws -> (ArqSegment, Int) {
        guard start + ArqBounds.segmentHeaderByteCount <= payload.endIndex else {
            throw ArqFrameError.truncatedFrame
        }
        let flags = payload[start + 1]
        let group: UInt16 = wireReadLE(payload, at: start + 2)
        let seq: UInt16 = wireReadLE(payload, at: start + 4)
        let bodyLen = Int(wireReadLE(payload, at: start + 6) as UInt16)
        guard bodyLen >= 1 else {
            throw ArqFrameError.zeroLengthSegmentBody
        }
        let bodyStart = start + ArqBounds.segmentHeaderByteCount
        guard bodyStart + bodyLen <= payload.endIndex else {
            throw ArqFrameError.truncatedFrame
        }
        let segment = try ArqSegment(
            group: ArqGroupId(rawValue: group),
            seq: ArqSegmentSeq(rawValue: seq),
            endOfMessage: flags & ArqSegment.endOfMessageFlag != 0,
            body: Array(payload[bodyStart..<bodyStart + bodyLen])
        )
        return (segment, bodyStart + bodyLen)
    }

    private static func decodeAck(
        _ payload: ArraySlice<UInt8>, at start: Int
    ) throws -> (ArqAck, Int) {
        guard start + ArqBounds.ackHeaderByteCount <= payload.endIndex else {
            throw ArqFrameError.truncatedFrame
        }
        let blockCount = Int(payload[start + 2])
        guard blockCount >= 1 else {
            throw ArqFrameError.zeroAckBlocks
        }
        guard blockCount <= ArqBounds.maxAckBlocks else {
            throw ArqFrameError.tooManyAckBlocks(blockCount)
        }
        var cursor = start + ArqBounds.ackHeaderByteCount
        var blocks: [ArqAck.Block] = []
        blocks.reserveCapacity(blockCount)
        for _ in 0..<blockCount {
            guard cursor + ArqBounds.ackBlockFixedByteCount <= payload.endIndex else {
                throw ArqFrameError.truncatedFrame
            }
            let channel = ChannelId(rawValue: payload[cursor])
            let group: UInt16 = wireReadLE(payload, at: cursor + 1)
            let cumulative: UInt16 = wireReadLE(payload, at: cursor + 3)
            let bitmapLen = Int(payload[cursor + 5])
            cursor += ArqBounds.ackBlockFixedByteCount
            guard bitmapLen <= ArqBounds.maxAckBitmapByteCount else {
                throw ArqFrameError.ackBitmapTooLong(bitmapLen)
            }
            guard cursor + bitmapLen <= payload.endIndex else {
                throw ArqFrameError.truncatedFrame
            }
            let block = try ArqAck.Block(
                channel: channel,
                group: ArqGroupId(rawValue: group),
                cumulative: ArqSegmentSeq(rawValue: cumulative),
                receivedBitmap: Array(payload[cursor..<cursor + bitmapLen])
            )
            blocks.append(block)
            cursor += bitmapLen
        }
        return (try ArqAck(blocks: blocks), cursor)
    }
}

/// Everything the ARQ frame codecs can refuse. Same doctrine as
/// WireError: hostile bytes throw, never trap. (Hashable so the
/// endpoint's ignore events can carry it.)
public enum ArqFrameError: Error, Hashable, Sendable {
    /// A frame header or body runs past the payload's end.
    case truncatedFrame
    /// A type byte that is neither 0x07 nor 0x08 where a frame must
    /// start — the datagram is not (wholly) ARQ.
    case unknownFrameType(UInt8)
    /// A zero-byte payload where at least one frame was promised.
    case emptyPayload
    /// bodyLen 0 — a segment that carries nothing is a fill bug.
    case zeroLengthSegmentBody
    /// A body over ArqBounds.maxSegmentBodyByteCount.
    case segmentBodyOverBudget(Int)
    /// blockCount 0 — an ACK that reports nothing is a fill bug.
    case zeroAckBlocks
    /// blockCount over ArqBounds.maxAckBlocks.
    case tooManyAckBlocks(Int)
    /// bitmapLen over ArqBounds.maxAckBitmapByteCount.
    case ackBitmapTooLong(Int)
    /// A bitmap whose final byte is zero: the bitmap is sized by its
    /// highest set bit, so a zero tail means the sender miscounted.
    case nonCanonicalAckBitmap
    /// An encoded frame sequence over the 1112 B shard budget.
    case payloadOverBudget(Int)
}
