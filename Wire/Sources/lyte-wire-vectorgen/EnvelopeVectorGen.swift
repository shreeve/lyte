// Envelope vector authoring (W0), unchanged in content — hoisted out of
// main.swift when W1 made the tool multi-file. Run once, commit, freeze:
// a byte difference against the committed file is a wire-contract break
// to investigate, never a prompt to regenerate. The circularity (vectors
// produced by the codec they test) is broken by the hand-computed anchor
// bytes in EnvelopeTests.

import LyteWire
import LyteWireTestKit

func makeEnvelopeVectorFile() throws -> EnvelopeVectorFile {
    var vectors: [EnvelopeVector] = []

    func fields(_ envelope: Envelope) -> EnvelopeFields {
        EnvelopeFields(from: envelope)
    }

    func roundtrip(
        name: String, description: String, envelope: Envelope, payload: [UInt8]
    ) throws {
        let datagram = try envelope.encode(payload: payload)
        vectors.append(
            EnvelopeVector(
                name: name,
                description: description,
                kind: .roundtrip,
                envelope: fields(envelope),
                encoder: nil,
                payloadHex: Hex.string(payload),
                datagramHex: Hex.string(datagram),
                error: nil
            )
        )
    }

    // MARK: Round trips

    let nominal = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 0x1234),
        frame: FrameNumber(rawValue: 0x0A0B_0C0D),
        timestamp: 0x0102_0304_0506_0708,
        fec: 0x1122_3344_5566_7788
    )
    try roundtrip(
        name: "nominal-video-shard",
        description: "Every field distinct so an endianness or offset slip is "
            + "visible byte-by-byte. Matches the hand-computed anchor in "
            + "EnvelopeTests.",
        envelope: nominal,
        payload: Array("lyte".utf8)
    )

    try roundtrip(
        name: "nominal-audio",
        description: "Audio-shaped datagram: chan=1, small frame counter, "
            + "96-byte counting payload.",
        envelope: Envelope(
            channel: .audio,
            seq: ChannelSeq(rawValue: 1),
            frame: FrameNumber(rawValue: 42),
            timestamp: 0x0000_0018_2CC8_2AA1,
            fec: 0x0000_0001_0204_0600
        ),
        payload: counting(from: 0x40, count: 96)
    )

    try roundtrip(
        name: "empty-payload",
        description: "Zero-length payload: the datagram is exactly the 24 "
            + "fixed envelope bytes.",
        envelope: Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: 0,
            fec: 0
        ),
        payload: []
    )

    try roundtrip(
        name: "max-plaintext-shard",
        description: "1112-byte payload — the plaintext shard budget, the "
            + "largest a packetizer may hand to the AEAD. Datagram is 1136 B.",
        envelope: Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 7),
            frame: FrameNumber(rawValue: 1000),
            timestamp: 0x0000_5AF3_107A_4000,
            fec: 0x0304_0500_0000_0000
        ),
        payload: counting(from: 0, count: 1112)
    )

    try roundtrip(
        name: "max-wire-payload",
        description: "1128-byte payload — ciphertext + tag ceiling. The "
            + "datagram is exactly the 1152 B budget.",
        envelope: Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 8),
            frame: FrameNumber(rawValue: 1001),
            timestamp: 0x0000_5AF3_107B_0000,
            fec: 0x0404_0500_0000_0000
        ),
        payload: counting(from: 0x80, count: 1128)
    )

    try roundtrip(
        name: "seq-wrap-high",
        description: "seq at 0xFFFF, the last value before the serial space "
            + "wraps; pairs with seq-wrap-low and the seqComparisons table.",
        envelope: Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 0xFFFF),
            frame: FrameNumber(rawValue: 0xFFFF_FFFF),
            timestamp: 0xFFFF_FFFF_FFFF_FFFF,
            fec: 0xFFFF_FFFF_FFFF_FFFF
        ),
        payload: counting(from: 0xF0, count: 16)
    )

    try roundtrip(
        name: "seq-wrap-low",
        description: "seq at 0x0000 immediately after a wrap; the successor of "
            + "seq-wrap-high on the same channel.",
        envelope: Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 0x0000),
            frame: FrameNumber(rawValue: 0xFFFF_FFFF),
            timestamp: 0xFFFF_FFFF_FFFF_FFFF,
            fec: 0xFFFF_FFFF_FFFF_FFFF
        ),
        payload: counting(from: 0xF0, count: 16)
    )

    try roundtrip(
        name: "tlv-reserved-types",
        description: "The two reserved TLV types W0 pins: connectionId (0x01, "
            + "8 bytes) and wireVersion (0x02, 1 byte). Codecs land at W5; the "
            + "numbers and skippability are contract now.",
        envelope: Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 100),
            frame: FrameNumber(rawValue: 5),
            timestamp: 0x0000_0000_0098_9680,
            fec: 0,
            extensions: [
                try WireExtension(
                    type: WireExtension.ReservedType.connectionId,
                    value: [0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7]
                ),
                try WireExtension(
                    type: WireExtension.ReservedType.wireVersion,
                    value: [WireVersion.major]
                ),
            ]
        ),
        payload: counting(from: 0x10, count: 32)
    )

    try roundtrip(
        name: "tlv-unknown-skipped",
        description: "An unassigned TLV type (0x7F): decoders must carry it "
            + "and deliver the payload intact — unknown TLVs are skipped by "
            + "consumers, never rejected by parsers.",
        envelope: Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 0x00FF),
            frame: FrameNumber(rawValue: 77),
            timestamp: 0x0000_0000_3B9A_CA00,
            fec: 0x0102_0300_0000_0000,
            extensions: [
                try WireExtension(type: 0x7F, value: [0xAA, 0xBB, 0xCC])
            ]
        ),
        payload: Array("payload survives unknown tlv".utf8)
    )

    // MARK: Lenient decodes (decode succeeds; canonical re-encode differs)

    let nominalDatagram = try nominal.encode(payload: Array("lyte".utf8))

    var reservedFlags = nominalDatagram
    reservedFlags[1] = 0x80
    vectors.append(
        EnvelopeVector(
            name: "reserved-flag-bits-ignored",
            description: "Flags 0x80: reserved bits MUST be 0 on send but are "
                + "ignored on receive — decodes identically to "
                + "nominal-video-shard.",
            kind: .decodeLenient,
            envelope: fields(nominal),
            encoder: nil,
            payloadHex: Hex.string(Array("lyte".utf8)),
            datagramHex: Hex.string(reservedFlags),
            error: nil
        )
    )

    var emptyTlvBlock = nominalDatagram
    emptyTlvBlock[1] = 0x01
    emptyTlvBlock.insert(0x00, at: 24)
    vectors.append(
        EnvelopeVector(
            name: "tlv-flag-empty-block",
            description: "Flags bit0 set with a zero TLV count: legal but "
                + "non-canonical (the canonical encoding omits the block). "
                + "Decodes to the nominal envelope with no extensions.",
            kind: .decodeLenient,
            envelope: fields(nominal),
            encoder: nil,
            payloadHex: Hex.string(Array("lyte".utf8)),
            datagramHex: Hex.string(emptyTlvBlock),
            error: nil
        )
    )

    // MARK: Encode rejects

    vectors.append(
        EnvelopeVector(
            name: "shard-over-budget",
            description: "1113 plaintext bytes: one over the 1112 B shard "
                + "budget; the shard encoder must reject at encode time.",
            kind: .encodeReject,
            envelope: fields(nominal),
            encoder: .plaintextShard,
            payloadHex: Hex.string(counting(from: 0, count: 1113)),
            datagramHex: nil,
            error: "shardOverBudget"
        )
    )

    vectors.append(
        EnvelopeVector(
            name: "payload-over-budget",
            description: "1129 wire-payload bytes: one over the 1128 B "
                + "ciphertext+tag ceiling.",
            kind: .encodeReject,
            envelope: fields(nominal),
            encoder: .payload,
            payloadHex: Hex.string(counting(from: 0, count: 1129)),
            datagramHex: nil,
            error: "payloadOverBudget"
        )
    )

    let tlvPush = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 9),
        frame: FrameNumber(rawValue: 1002),
        timestamp: 0x0000_5AF3_107C_0000,
        fec: 0x0504_0500_0000_0000,
        extensions: [
            try WireExtension(type: 0x7F, value: counting(from: 0, count: 21))
        ]
    )
    vectors.append(
        EnvelopeVector(
            name: "datagram-over-budget-tlv",
            description: "A 1128 B payload plus a 24-byte TLV block: each "
                + "budget passes alone, the 1152 B datagram ceiling rejects "
                + "the sum.",
            kind: .encodeReject,
            envelope: fields(tlvPush),
            encoder: .payload,
            payloadHex: Hex.string(counting(from: 0x80, count: 1128)),
            datagramHex: nil,
            error: "datagramOverBudget"
        )
    )

    // MARK: Decode rejects

    vectors.append(
        EnvelopeVector(
            name: "truncated-envelope",
            description: "23 bytes: one short of the fixed envelope.",
            kind: .decodeReject,
            envelope: nil,
            encoder: nil,
            payloadHex: nil,
            datagramHex: Hex.string(Array(nominalDatagram.prefix(23))),
            error: "truncatedEnvelope"
        )
    )

    var truncatedTlv = Array(nominalDatagram.prefix(24))
    truncatedTlv[1] = 0x01
    truncatedTlv += [0x01, 0x7F, 0x05, 0xAA, 0xBB]
    vectors.append(
        EnvelopeVector(
            name: "truncated-tlv-block",
            description: "Flags promise one TLV of length 5 but the datagram "
                + "ends after 2 value bytes.",
            kind: .decodeReject,
            envelope: nil,
            encoder: nil,
            payloadHex: nil,
            datagramHex: Hex.string(truncatedTlv),
            error: "truncatedExtensions"
        )
    )

    let oversize = Array(nominalDatagram.prefix(24)) + counting(from: 0, count: 1129)
    vectors.append(
        EnvelopeVector(
            name: "oversize-datagram",
            description: "1153 bytes: one over the datagram budget; receivers "
                + "reject before parsing.",
            kind: .decodeReject,
            envelope: nil,
            encoder: nil,
            payloadHex: nil,
            datagramHex: Hex.string(oversize),
            error: "datagramOverBudget"
        )
    )

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
        format: EnvelopeVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        vectors: vectors,
        seqComparisons: seqComparisons
    )
}
