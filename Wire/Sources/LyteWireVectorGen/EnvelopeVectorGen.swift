// Authors Vectors/envelope-v1.json. The hand-computed anchor bytes in
// EnvelopeTests keep the codec from grading its own vectors.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeEnvelopeVectorFile() throws -> EnvelopeVectorFile {
    var vectors: [EnvelopeVector] = []

    func envelope(
        _ channel: ChannelId, seq: UInt16, frame: UInt32,
        timestamp: UInt64, fec: UInt64, extensions: [WireExtension] = []
    ) -> Envelope {
        Envelope(
            channel: channel, seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: frame),
            timestamp: timestamp, fec: fec, extensions: extensions
        )
    }

    // MARK: Round trips

    let nominal = envelope(
        .videoActive, seq: 0x1234, frame: 0x0A0B_0C0D,
        timestamp: 0x0102_0304_0506_0708, fec: 0x1122_3344_5566_7788
    )
    let lyte = Array("lyte".utf8)
    let wrapped = [0xFFFF, 0x0000].map {
        envelope(.videoActive, seq: $0, frame: 0xFFFF_FFFF,
                 timestamp: .max, fec: .max)
    }
    for (name, description, envelope, payload) in [
        ("nominal-video-shard",
         "Every field distinct so an endianness or offset slip is visible "
            + "byte-by-byte. Matches the hand-computed anchor in EnvelopeTests.",
         nominal, lyte),
        ("nominal-audio",
         "Audio-shaped datagram: chan=1, small frame counter, 96-byte "
            + "counting payload.",
         envelope(.audio, seq: 1, frame: 42,
                  timestamp: 0x0000_0018_2CC8_2AA1, fec: 0x0000_0001_0204_0600),
         counting(from: 0x40, count: 96)),
        ("empty-payload",
         "Zero-length payload: the datagram is exactly the 24 fixed envelope "
            + "bytes.",
         envelope(.ctrl, seq: 0, frame: 0, timestamp: 0, fec: 0), []),
        ("max-plaintext-shard",
         "1112-byte payload — the plaintext shard budget, the largest a "
            + "packetizer may hand to the AEAD. Datagram is 1136 B.",
         envelope(.videoActive, seq: 7, frame: 1000,
                  timestamp: 0x0000_5AF3_107A_4000, fec: 0x0304_0500_0000_0000),
         counting(from: 0, count: 1112)),
        ("max-wire-payload",
         "1128-byte payload — ciphertext + tag ceiling. The datagram is "
            + "exactly the 1152 B budget.",
         envelope(.videoActive, seq: 8, frame: 1001,
                  timestamp: 0x0000_5AF3_107B_0000, fec: 0x0404_0500_0000_0000),
         counting(from: 0x80, count: 1128)),
        ("seq-wrap-high",
         "seq at 0xFFFF, the last value before the serial space wraps; pairs "
            + "with seq-wrap-low and the seqComparisons table.",
         wrapped[0], counting(from: 0xF0, count: 16)),
        ("seq-wrap-low",
         "seq at 0x0000 immediately after a wrap; the successor of "
            + "seq-wrap-high on the same channel.",
         wrapped[1], counting(from: 0xF0, count: 16)),
        ("tlv-reserved-types",
         "The two reserved TLV types W0 pins: connectionId (0x01, 8 bytes) "
            + "and wireVersion (0x02, 1 byte). Codecs land at W5; the numbers "
            + "and skippability are contract now.",
         envelope(.ctrl, seq: 100, frame: 5,
                  timestamp: 0x0000_0000_0098_9680, fec: 0, extensions: [
                    try WireExtension(
                        type: WireExtension.ReservedType.connectionId,
                        value: [0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7]
                    ),
                    try WireExtension(
                        type: WireExtension.ReservedType.wireVersion,
                        value: [WireVersion.major]
                    ),
                  ]),
         counting(from: 0x10, count: 32)),
        ("tlv-unknown-skipped",
         "An unassigned TLV type (0x7F): decoders must carry it and deliver "
            + "the payload intact — unknown TLVs are skipped by consumers, "
            + "never rejected by parsers.",
         envelope(.videoActive, seq: 0x00FF, frame: 77,
                  timestamp: 0x0000_0000_3B9A_CA00, fec: 0x0102_0300_0000_0000,
                  extensions: [
                    try WireExtension(type: 0x7F, value: [0xAA, 0xBB, 0xCC]),
                  ]),
         Array("payload survives unknown tlv".utf8)),
    ] {
        vectors.append(EnvelopeVector(
            name: name, description: description, kind: .roundtrip,
            envelope: EnvelopeFields(from: envelope),
            payloadHex: Hex.string(payload),
            datagramHex: Hex.string(try envelope.encode(payload: payload))
        ))
    }

    // MARK: Lenient decodes (decode succeeds; canonical re-encode differs)

    let nominalDatagram = try nominal.encode(payload: lyte)
    var reservedFlags = nominalDatagram
    reservedFlags[1] = 0x80
    var emptyTlvBlock = nominalDatagram
    emptyTlvBlock[1] = 0x01
    emptyTlvBlock.insert(0x00, at: 24)
    for (name, description, datagram) in [
        ("reserved-flag-bits-ignored",
         "Flags 0x80: reserved bits MUST be 0 on send but are ignored on "
            + "receive — decodes identically to nominal-video-shard.",
         reservedFlags),
        ("tlv-flag-empty-block",
         "Flags bit0 set with a zero TLV count: legal but non-canonical (the "
            + "canonical encoding omits the block). Decodes to the nominal "
            + "envelope with no extensions.",
         emptyTlvBlock),
    ] {
        vectors.append(EnvelopeVector(
            name: name, description: description, kind: .decodeLenient,
            envelope: EnvelopeFields(from: nominal),
            payloadHex: Hex.string(lyte), datagramHex: Hex.string(datagram)
        ))
    }

    // MARK: Encode rejects

    let tlvPush = envelope(
        .videoActive, seq: 9, frame: 1002,
        timestamp: 0x0000_5AF3_107C_0000, fec: 0x0504_0500_0000_0000,
        extensions: [
            try WireExtension(type: 0x7F, value: counting(from: 0, count: 21)),
        ]
    )
    for (name, description, envelope, encoder, payload, error) in [
        ("shard-over-budget",
         "1113 plaintext bytes: one over the 1112 B shard budget; the shard "
            + "encoder must reject at encode time.",
         nominal, EnvelopeVector.Encoder.plaintextShard,
         counting(from: 0, count: 1113), "shardOverBudget"),
        ("payload-over-budget",
         "1129 wire-payload bytes: one over the 1128 B ciphertext+tag "
            + "ceiling.",
         nominal, .payload, counting(from: 0, count: 1129),
         "payloadOverBudget"),
        ("datagram-over-budget-tlv",
         "A 1128 B payload plus a 24-byte TLV block: each budget passes "
            + "alone, the 1152 B datagram ceiling rejects the sum.",
         tlvPush, .payload, counting(from: 0x80, count: 1128),
         "datagramOverBudget"),
    ] {
        vectors.append(EnvelopeVector(
            name: name, description: description, kind: .encodeReject,
            envelope: EnvelopeFields(from: envelope), encoder: encoder,
            payloadHex: Hex.string(payload), error: error
        ))
    }

    // MARK: Decode rejects

    var truncatedTlv = Array(nominalDatagram.prefix(24))
    truncatedTlv[1] = 0x01
    truncatedTlv += [0x01, 0x7F, 0x05, 0xAA, 0xBB]
    for (name, description, datagram, error) in [
        ("truncated-envelope", "23 bytes: one short of the fixed envelope.",
         Array(nominalDatagram.prefix(23)), "truncatedEnvelope"),
        ("truncated-tlv-block",
         "Flags promise one TLV of length 5 but the datagram ends after 2 "
            + "value bytes.",
         truncatedTlv, "truncatedExtensions"),
        ("oversize-datagram",
         "1153 bytes: one over the datagram budget; receivers reject before "
            + "parsing.",
         Array(nominalDatagram.prefix(24)) + counting(from: 0, count: 1129),
         "datagramOverBudget"),
    ] {
        vectors.append(EnvelopeVector(
            name: name, description: description, kind: .decodeReject,
            datagramHex: Hex.string(datagram), error: error
        ))
    }

    // MARK: Serial-arithmetic table

    let seqComparisons: [SeqComparison] = [
        SeqComparison(a: 0, b: 1, aBeforeB: true, distance: 1),
        SeqComparison(a: 1, b: 0, aBeforeB: false, distance: -1),
        SeqComparison(a: 5000, b: 5000, aBeforeB: false, distance: 0),
        SeqComparison(a: 0xFFFF, b: 0, aBeforeB: true, distance: 1),
        SeqComparison(a: 0, b: 0xFFFF, aBeforeB: false, distance: -1),
        SeqComparison(a: 0xFFFE, b: 1, aBeforeB: true, distance: 3),
        SeqComparison(a: 60000, b: 4464, aBeforeB: true, distance: 10000),
        SeqComparison(a: 4464, b: 60000, aBeforeB: false, distance: -10000),
        // Exactly half the space apart: unordered by rule — both `<` false,
        // distance reports Int16.min from either side.
        SeqComparison(a: 100, b: 32868, aBeforeB: false, distance: -32768),
        SeqComparison(a: 32868, b: 100, aBeforeB: false, distance: -32768),
    ]

    return EnvelopeVectorFile(
        vectors: vectors,
        seqComparisons: seqComparisons
    )
}
