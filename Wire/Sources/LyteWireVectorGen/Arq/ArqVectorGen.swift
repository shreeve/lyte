// Authors Vectors/arq-v1.json: the data segment 0x07, the ACK 0x08, and
// the frame-sequence payload rule. Anchored by ArqCodecTests.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeArqVectorFile() throws -> ArqVectorFile {
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

    func append(
        _ name: String, _ kind: ArqVector.Kind, _ description: String,
        _ payload: [UInt8], frames: [ArqVector.Frame]? = nil,
        error: String? = nil
    ) {
        vectors.append(ArqVector(
            name: name, description: description, kind: kind,
            payloadHex: Hex.string(payload), frames: frames, error: error
        ))
    }

    // MARK: Round trips

    let nominalSegment = try segmentFrame(
        group: 5, seq: 0x0203, endOfMessage: true, body: [0xAA, 0xBB, 0xCC]
    )
    let nominalAck = try ackFrame([
        (chan: 0, group: 5, cumulative: 0x0203, bitmap: [0x05])
    ])
    for (name, description, parts) in [
        ("segment-nominal",
         "One-shot group 5, seq 0x0203, endOfMessage, 3-byte body — the "
            + "hand-computed anchor.",
         [nominalSegment]),
        ("segment-stream-first",
         "The ordered stream's first segment: group 0, seq 0, mid-message "
            + "(endOfMessage clear).",
         [try segmentFrame(group: 0, seq: 0, endOfMessage: false,
                           body: counting(from: 1, count: 16))]),
        ("segment-max-body",
         "A 1104-byte body: the frame fills the 1112 B plaintext shard "
            + "budget exactly.",
         [try segmentFrame(
            group: 1, seq: 7, endOfMessage: true,
            body: counting(from: 0, count: ArqBounds.maxSegmentBodyByteCount)
         )]),
        ("segment-seq-wrap-high", "seq 0xFFFF — the serial u16's wrap edge.",
         [try segmentFrame(group: 9, seq: 0xFFFF, endOfMessage: false,
                           body: [0x11])]),
        ("ack-nominal",
         "CTRL group 5 received through 0x0203 plus bitmap 0x05 = seqs 0x0204 "
            + "and 0x0206 (bits 0 and 2 past the cumulative) — the "
            + "hand-computed anchor.",
         [nominalAck]),
        ("ack-nothing-in-order",
         "cumulative 0xFFFF = initial − 1 (nothing in order yet); the "
            + "bitmap's bit 0 names seq 0 received out of order.",
         [try ackFrame([(chan: 4, group: 12, cumulative: 0xFFFF,
                         bitmap: [0x01])])]),
        ("ack-two-blocks",
         "One frame reporting two groups: the stream clean through 41 (empty "
            + "bitmap), one-shot 7 with seqs 3…10 and 18 received past "
            + "cumulative 2.",
         [try ackFrame([
            (chan: 0, group: 0, cumulative: 41, bitmap: []),
            (chan: 0, group: 7, cumulative: 2, bitmap: [0xFF, 0x80]),
         ])]),
        // The frame-sequence rule as bytes: an ACK piggybacked ahead of
        // two segments in one datagram.
        ("coalesced-ack-then-segments",
         "One datagram payload = ACK frame then two stream segments; "
            + "decodeAll yields the sequence in order and re-encodes "
            + "byte-exactly.",
         [nominalAck,
          try segmentFrame(group: 0, seq: 3, endOfMessage: false,
                           body: counting(from: 0x40, count: 8)),
          try segmentFrame(group: 0, seq: 4, endOfMessage: true,
                           body: counting(from: 0x48, count: 4))]),
    ] {
        append(name, .roundtrip, description,
               parts.flatMap(\.1), frames: parts.map(\.0))
    }

    // MARK: Lenient decodes

    let segmentBytes = nominalSegment.1
    let ackBytes = nominalAck.1
    var reservedFlagsSegment = segmentBytes
    reservedFlagsSegment[1] |= 0xFE
    append("segment-reserved-flags-ignored", .decodeLenient,
           "Reserved segment flag bits set: decodes (bit0 still read), "
            + "re-encode differs.",
           reservedFlagsSegment, frames: [nominalSegment.0])
    var reservedFlagsAck = ackBytes
    reservedFlagsAck[1] = 0x7F
    append("ack-reserved-flags-ignored", .decodeLenient,
           "Reserved ACK flag byte set: decodes, re-encode differs.",
           reservedFlagsAck, frames: [nominalAck.0])

    // MARK: Decode rejects

    var zeroBody = Array(segmentBytes.prefix(8))
    zeroBody[6] = 0
    zeroBody[7] = 0
    var tooManyBlocks = ackBytes
    tooManyBlocks[2] = UInt8(ArqBounds.maxAckBlocks + 1)
    var longBitmap = ackBytes
    longBitmap[8] = UInt8(ArqBounds.maxAckBitmapByteCount + 1)
    var nonCanonical = ackBytes
    nonCanonical[8] = 2
    nonCanonical[9] = 0x05
    nonCanonical.append(0x00)
    for (name, description, payload, error) in [
        ("empty-payload", "A zero-byte payload where a frame was promised.",
         [], "emptyPayload"),
        ("unknown-frame-type", "0x7F where a frame must start.",
         [0x7F], "unknownFrameType"),
        ("segment-truncated-header", "7 bytes of an 8-byte segment header.",
         Array(segmentBytes.prefix(7)), "truncatedFrame"),
        ("segment-truncated-body",
         "bodyLen promises 3 bytes, payload carries 2.",
         Array(segmentBytes.dropLast()), "truncatedFrame"),
        ("segment-zero-length-body",
         "bodyLen 0 — a segment that carries nothing is a fill bug, kept loud.",
         zeroBody, "zeroLengthSegmentBody"),
        ("trailing-garbage-after-frame",
         "A well-formed segment followed by a byte that is not a frame type: "
            + "the payload is exactly its frames.",
         segmentBytes + [0x00], "unknownFrameType"),
        ("ack-zero-blocks",
         "blockCount 0 — an ACK reporting nothing is a fill bug.",
         [0x08, 0x00, 0x00], "zeroAckBlocks"),
        ("ack-too-many-blocks", "blockCount 17 rejects on the count byte.",
         tooManyBlocks, "tooManyAckBlocks"),
        ("ack-bitmap-too-long",
         "bitmapLen 33 — past the 256-seq window an ACK can describe.",
         longBitmap, "ackBitmapTooLong"),
        ("ack-bitmap-noncanonical",
         "A zero final bitmap byte: the bitmap is sized by its highest set "
            + "bit, so a zero tail means the sender miscounted.",
         nonCanonical, "nonCanonicalAckBitmap"),
        ("ack-truncated-block",
         "The block promises a bitmap byte the payload does not carry.",
         Array(ackBytes.dropLast()), "truncatedFrame"),
    ] as [(String, String, [UInt8], String)] {
        append(name, .decodeReject, description, payload, error: error)
    }

    return ArqVectorFile(vectors: vectors)
}
