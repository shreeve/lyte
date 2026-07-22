// ARQ frame vector authoring (W3): the data segment 0x07, the ACK 0x08,
// and the frame-sequence payload rule. Run once, commit, freeze. The
// circularity is broken by the hand-computed anchor bytes in
// ArqCodecTests, which pin the same nominal frames.

import LyteWire
import LyteWireTestKit

func makeArqVectorFile() throws -> ArqVectorFile {
    var vectors: [ArqVector] = []

    func segmentFrame(
        group: UInt16, seq: UInt16, endOfMessage: Bool, body: [UInt8]
    ) throws -> (ArqVector.Frame, [UInt8]) {
        let segment = try ArqSegment(
            group: ArqGroupId(rawValue: group),
            seq: ArqSegmentSeq(rawValue: seq),
            endOfMessage: endOfMessage,
            body: body
        )
        let frame = ArqVector.Frame(segment: ArqVector.Segment(
            group: group, seq: seq, endOfMessage: endOfMessage,
            bodyHex: Hex.string(body)
        ))
        return (frame, segment.encode())
    }

    func ackFrame(
        _ blocks: [(chan: UInt8, group: UInt16, cumulative: UInt16, bitmap: [UInt8])]
    ) throws -> (ArqVector.Frame, [UInt8]) {
        let ack = try ArqAck(blocks: blocks.map {
            try ArqAck.Block(
                channel: ChannelId(rawValue: $0.chan),
                group: ArqGroupId(rawValue: $0.group),
                cumulative: ArqSegmentSeq(rawValue: $0.cumulative),
                receivedBitmap: $0.bitmap
            )
        })
        let frame = ArqVector.Frame(ack: ArqVector.Ack(
            blocks: blocks.map {
                ArqVector.Ack.Block(
                    chan: $0.chan, group: $0.group,
                    cumulative: $0.cumulative,
                    bitmapHex: Hex.string($0.bitmap)
                )
            }
        ))
        return (frame, ack.encode())
    }

    // MARK: Round trips

    let (nominalSegment, nominalSegmentBytes) = try segmentFrame(
        group: 5, seq: 0x0203, endOfMessage: true, body: [0xAA, 0xBB, 0xCC]
    )
    vectors.append(ArqVector(
        name: "segment-nominal",
        description: "One-shot group 5, seq 0x0203, endOfMessage, 3-byte "
            + "body — the hand-computed anchor.",
        kind: .roundtrip,
        payloadHex: Hex.string(nominalSegmentBytes),
        frames: [nominalSegment]
    ))

    let (streamSegment, streamSegmentBytes) = try segmentFrame(
        group: 0, seq: 0, endOfMessage: false, body: counting(from: 1, count: 16)
    )
    vectors.append(ArqVector(
        name: "segment-stream-first",
        description: "The ordered stream's first segment: group 0, seq 0, "
            + "mid-message (endOfMessage clear).",
        kind: .roundtrip,
        payloadHex: Hex.string(streamSegmentBytes),
        frames: [streamSegment]
    ))

    let (maxSegment, maxSegmentBytes) = try segmentFrame(
        group: 1, seq: 7, endOfMessage: true,
        body: counting(from: 0, count: ArqBounds.maxSegmentBodyByteCount)
    )
    vectors.append(ArqVector(
        name: "segment-max-body",
        description: "A 1104-byte body: the frame fills the 1112 B "
            + "plaintext shard budget exactly.",
        kind: .roundtrip,
        payloadHex: Hex.string(maxSegmentBytes),
        frames: [maxSegment]
    ))

    let (wrapSegment, wrapSegmentBytes) = try segmentFrame(
        group: 9, seq: 0xFFFF, endOfMessage: false, body: [0x11]
    )
    vectors.append(ArqVector(
        name: "segment-seq-wrap-high",
        description: "seq 0xFFFF — the serial u16's wrap edge.",
        kind: .roundtrip,
        payloadHex: Hex.string(wrapSegmentBytes),
        frames: [wrapSegment]
    ))

    let (nominalAck, nominalAckBytes) = try ackFrame([
        (chan: 0, group: 5, cumulative: 0x0203, bitmap: [0x05])
    ])
    vectors.append(ArqVector(
        name: "ack-nominal",
        description: "CTRL group 5 received through 0x0203 plus bitmap "
            + "0x05 = seqs 0x0204 and 0x0206 (bits 0 and 2 past the "
            + "cumulative) — the hand-computed anchor.",
        kind: .roundtrip,
        payloadHex: Hex.string(nominalAckBytes),
        frames: [nominalAck]
    ))

    let (nothingAck, nothingAckBytes) = try ackFrame([
        (chan: 4, group: 12, cumulative: 0xFFFF, bitmap: [0x01])
    ])
    vectors.append(ArqVector(
        name: "ack-nothing-in-order",
        description: "cumulative 0xFFFF = initial − 1 (nothing in order "
            + "yet); the bitmap's bit 0 names seq 0 received out of "
            + "order.",
        kind: .roundtrip,
        payloadHex: Hex.string(nothingAckBytes),
        frames: [nothingAck]
    ))

    let (multiAck, multiAckBytes) = try ackFrame([
        (chan: 0, group: 0, cumulative: 41, bitmap: []),
        (chan: 0, group: 7, cumulative: 2, bitmap: [0xFF, 0x80]),
    ])
    vectors.append(ArqVector(
        name: "ack-two-blocks",
        description: "One frame reporting two groups: the stream clean "
            + "through 41 (empty bitmap), one-shot 7 with seqs 3…10 and "
            + "18 received past cumulative 2.",
        kind: .roundtrip,
        payloadHex: Hex.string(multiAckBytes),
        frames: [multiAck]
    ))

    // A coalesced datagram: ACK piggybacked ahead of two segments —
    // the frame-sequence rule as bytes.
    let (coSeg1, coSeg1Bytes) = try segmentFrame(
        group: 0, seq: 3, endOfMessage: false, body: counting(from: 0x40, count: 8)
    )
    let (coSeg2, coSeg2Bytes) = try segmentFrame(
        group: 0, seq: 4, endOfMessage: true, body: counting(from: 0x48, count: 4)
    )
    vectors.append(ArqVector(
        name: "coalesced-ack-then-segments",
        description: "One datagram payload = ACK frame then two stream "
            + "segments; decodeAll yields the sequence in order and "
            + "re-encodes byte-exactly.",
        kind: .roundtrip,
        payloadHex: Hex.string(nominalAckBytes + coSeg1Bytes + coSeg2Bytes),
        frames: [nominalAck, coSeg1, coSeg2]
    ))

    // MARK: Lenient decodes

    var reservedFlagsSegment = nominalSegmentBytes
    reservedFlagsSegment[1] |= 0xFE
    vectors.append(ArqVector(
        name: "segment-reserved-flags-ignored",
        description: "Reserved segment flag bits set: decodes (bit0 still "
            + "read), re-encode differs.",
        kind: .decodeLenient,
        payloadHex: Hex.string(reservedFlagsSegment),
        frames: [nominalSegment]
    ))

    var reservedFlagsAck = nominalAckBytes
    reservedFlagsAck[1] = 0x7F
    vectors.append(ArqVector(
        name: "ack-reserved-flags-ignored",
        description: "Reserved ACK flag byte set: decodes, re-encode "
            + "differs.",
        kind: .decodeLenient,
        payloadHex: Hex.string(reservedFlagsAck),
        frames: [nominalAck]
    ))

    // MARK: Decode rejects

    vectors.append(ArqVector(
        name: "empty-payload",
        description: "A zero-byte payload where a frame was promised.",
        kind: .decodeReject, payloadHex: "", error: "emptyPayload"
    ))
    vectors.append(ArqVector(
        name: "unknown-frame-type",
        description: "0x7F where a frame must start.",
        kind: .decodeReject, payloadHex: "7f", error: "unknownFrameType"
    ))
    vectors.append(ArqVector(
        name: "segment-truncated-header",
        description: "7 bytes of an 8-byte segment header.",
        kind: .decodeReject,
        payloadHex: Hex.string(nominalSegmentBytes.prefix(7)),
        error: "truncatedFrame"
    ))
    vectors.append(ArqVector(
        name: "segment-truncated-body",
        description: "bodyLen promises 3 bytes, payload carries 2.",
        kind: .decodeReject,
        payloadHex: Hex.string(nominalSegmentBytes.dropLast()),
        error: "truncatedFrame"
    ))
    var zeroBody = Array(nominalSegmentBytes.prefix(8))
    zeroBody[6] = 0
    zeroBody[7] = 0
    vectors.append(ArqVector(
        name: "segment-zero-length-body",
        description: "bodyLen 0 — a segment that carries nothing is a "
            + "fill bug, kept loud.",
        kind: .decodeReject,
        payloadHex: Hex.string(zeroBody),
        error: "zeroLengthSegmentBody"
    ))
    vectors.append(ArqVector(
        name: "trailing-garbage-after-frame",
        description: "A well-formed segment followed by a byte that is "
            + "not a frame type: the payload is exactly its frames.",
        kind: .decodeReject,
        payloadHex: Hex.string(nominalSegmentBytes + [0x00]),
        error: "unknownFrameType"
    ))
    vectors.append(ArqVector(
        name: "ack-zero-blocks",
        description: "blockCount 0 — an ACK reporting nothing is a fill "
            + "bug.",
        kind: .decodeReject,
        payloadHex: "080000",
        error: "zeroAckBlocks"
    ))
    var tooManyBlocks = nominalAckBytes
    tooManyBlocks[2] = UInt8(ArqBounds.maxAckBlocks + 1)
    vectors.append(ArqVector(
        name: "ack-too-many-blocks",
        description: "blockCount 17 rejects on the count byte.",
        kind: .decodeReject,
        payloadHex: Hex.string(tooManyBlocks),
        error: "tooManyAckBlocks"
    ))
    var longBitmap = nominalAckBytes
    longBitmap[8] = UInt8(ArqBounds.maxAckBitmapByteCount + 1)
    vectors.append(ArqVector(
        name: "ack-bitmap-too-long",
        description: "bitmapLen 33 — past the 256-seq window an ACK can "
            + "describe.",
        kind: .decodeReject,
        payloadHex: Hex.string(longBitmap),
        error: "ackBitmapTooLong"
    ))
    var nonCanonical = nominalAckBytes
    nonCanonical[8] = 2
    nonCanonical[9] = 0x05
    nonCanonical.append(0x00)
    vectors.append(ArqVector(
        name: "ack-bitmap-noncanonical",
        description: "A zero final bitmap byte: the bitmap is sized by "
            + "its highest set bit, so a zero tail means the sender "
            + "miscounted.",
        kind: .decodeReject,
        payloadHex: Hex.string(nonCanonical),
        error: "nonCanonicalAckBitmap"
    ))
    vectors.append(ArqVector(
        name: "ack-truncated-block",
        description: "The block promises a bitmap byte the payload does "
            + "not carry.",
        kind: .decodeReject,
        payloadHex: Hex.string(nominalAckBytes.dropLast()),
        error: "truncatedFrame"
    ))

    return ArqVectorFile(
        format: ArqVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        vectors: vectors
    )
}
