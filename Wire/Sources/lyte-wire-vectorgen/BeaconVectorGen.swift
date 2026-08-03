// Beacon/feedback vector authoring (W4a). Run once, commit, freeze: a
// byte difference against the committed file is a wire-contract break to
// investigate, never a prompt to regenerate. The circularity (vectors
// produced by the codecs they test) is broken by the hand-computed anchor
// bytes in ClockBeaconTests/FeedbackReportTests, which pin the same
// nominal messages this file carries.

import LyteCore
import LyteWire
import LyteWireTestKit

func makeBeaconVectorFile() throws -> BeaconVectorFile {
    var beaconVectors: [BeaconVector] = []
    var feedbackVectors: [FeedbackVector] = []

    // MARK: Beacon round trips

    func beaconRoundtrip(name: String, description: String, _ beacon: ClockBeacon) {
        beaconVectors.append(
            BeaconVector(
                name: name, description: description,
                kind: .roundtrip, decoder: .beacon,
                beacon: BeaconFields(from: beacon),
                messageHex: Hex.string(beacon.encode())
            )
        )
    }

    func echoRoundtrip(name: String, description: String, _ echo: BeaconEcho) {
        beaconVectors.append(
            BeaconVector(
                name: name, description: description,
                kind: .roundtrip, decoder: .echo,
                echo: EchoFields(from: echo),
                messageHex: Hex.string(echo.encode())
            )
        )
    }

    beaconRoundtrip(
        name: "beacon-first",
        description: "Session-start beacon: seq 0, no echo received yet — "
            + "flags 0 and all-zero lastEcho bytes.",
        ClockBeacon(
            beaconSeq: 0,
            hostSend: HostTimestamp(microseconds: 1_000_000_000)
        )
    )

    let steadyBeacon = ClockBeacon(
        beaconSeq: 7,
        hostSend: HostTimestamp(microseconds: 0x0102_0304_0506_0708),
        lastEcho: ClockBeacon.LastEcho(
            beaconSeq: 6,
            clientSend: ClientTimestamp(microseconds: 0x1112_1314_1516_1718),
            hostReceive: HostTimestamp(microseconds: 0x2122_2324_2526_2728)
        )
    )
    beaconRoundtrip(
        name: "beacon-steady",
        description: "Steady-state beacon reporting the previous echo; every "
            + "field distinct so an endianness or offset slip is visible "
            + "byte-by-byte. Matches the hand-computed anchor in "
            + "ClockBeaconTests.",
        steadyBeacon
    )

    beaconRoundtrip(
        name: "beacon-seq-max",
        description: "All counters and clocks at their u32/u64 maxima.",
        ClockBeacon(
            beaconSeq: .max,
            hostSend: HostTimestamp(microseconds: .max),
            lastEcho: ClockBeacon.LastEcho(
                beaconSeq: .max,
                clientSend: ClientTimestamp(microseconds: .max),
                hostReceive: HostTimestamp(microseconds: .max)
            )
        )
    )

    let echoAnchor = BeaconEcho(
        beaconSeq: 0x0A0B_0C0D,
        hostSend: HostTimestamp(microseconds: 0x0102_0304_0506_0708),
        clientReceive: ClientTimestamp(microseconds: 0x1112_1314_1516_1718),
        clientSend: ClientTimestamp(microseconds: 0x2122_2324_2526_2728)
    )
    echoRoundtrip(
        name: "echo-nominal",
        description: "Every field distinct. Matches the hand-computed anchor "
            + "in ClockBeaconTests.",
        echoAnchor
    )

    // The worked example (README + clockWorkedExample below): true offset
    // 250,000 µs, forward path 3,000 µs, reverse 5,000 µs, turnaround
    // 500 µs.
    let workedEcho = BeaconEcho(
        beaconSeq: 12,
        hostSend: HostTimestamp(microseconds: 1_000_000),
        clientReceive: ClientTimestamp(microseconds: 1_253_000),
        clientSend: ClientTimestamp(microseconds: 1_253_500)
    )
    echoRoundtrip(
        name: "echo-worked-example",
        description: "The README's offset/RTT worked example: t1=1,000,000 "
            + "t2=1,253,000 t3=1,253,500 (t4=1,008,500 lives in "
            + "clockWorkedExample).",
        workedEcho
    )

    // MARK: Beacon lenient decode

    var reservedFlags = steadyBeacon.encode()
    reservedFlags[1] |= 0x80
    beaconVectors.append(
        BeaconVector(
            name: "beacon-reserved-flags-ignored",
            description: "Reserved flag bit 7 set: decodes identically to "
                + "beacon-steady, canonical re-encode differs.",
            kind: .decodeLenient, decoder: .beacon,
            beacon: BeaconFields(from: steadyBeacon),
            messageHex: Hex.string(reservedFlags)
        )
    )

    // MARK: Beacon rejects

    func beaconReject(
        name: String, description: String, decoder: BeaconVector.Decoder,
        bytes: [UInt8], error: BeaconError
    ) {
        beaconVectors.append(
            BeaconVector(
                name: name, description: description,
                kind: .decodeReject, decoder: decoder,
                messageHex: Hex.string(bytes),
                error: beaconErrorName(error)
            )
        )
    }

    beaconReject(
        name: "beacon-truncated",
        description: "33 of 34 bytes.",
        decoder: .beacon,
        bytes: Array(steadyBeacon.encode().dropLast()),
        error: .truncatedMessage
    )
    beaconReject(
        name: "beacon-trailing-byte",
        description: "35 bytes: the beacon is exactly its fixed layout, "
            + "nothing rides behind it.",
        decoder: .beacon,
        bytes: steadyBeacon.encode() + [0x00],
        error: .trailingBytes
    )
    beaconReject(
        name: "beacon-bad-type",
        description: "An echo's type byte (0x02) fed to the beacon decoder "
            + "at beacon length: a CTRL dispatcher's misrouting is loud.",
        decoder: .beacon,
        bytes: echoAnchor.encode() + [0x00, 0x00, 0x00, 0x00, 0x00],
        error: .unexpectedType(0x02)
    )
    var nonZeroAbsent = ClockBeacon(
        beaconSeq: 3, hostSend: HostTimestamp(microseconds: 42)
    ).encode()
    nonZeroAbsent[20] = 0xAA
    beaconReject(
        name: "beacon-nonzero-absent-echo",
        description: "flags bit0 clear but a lastEcho byte non-zero — some "
            + "other layer's fill bug, kept loud (the FecField none rule).",
        decoder: .beacon,
        bytes: nonZeroAbsent,
        error: .nonZeroAbsentEchoFields
    )
    beaconReject(
        name: "echo-truncated",
        description: "28 of 29 bytes.",
        decoder: .echo,
        bytes: Array(echoAnchor.encode().dropLast()),
        error: .truncatedMessage
    )
    beaconReject(
        name: "echo-trailing-byte",
        description: "30 bytes.",
        decoder: .echo,
        bytes: echoAnchor.encode() + [0x00],
        error: .trailingBytes
    )
    beaconReject(
        name: "echo-bad-type",
        description: "Unassigned type 0x7f at echo length.",
        decoder: .echo,
        bytes: [0x7F] + Array(echoAnchor.encode().dropFirst()),
        error: .unexpectedType(0x7F)
    )

    // MARK: Feedback round trips

    func feedbackRoundtrip(
        name: String, description: String, _ report: FeedbackReport
    ) throws {
        feedbackVectors.append(
            FeedbackVector(
                name: name, description: description, kind: .roundtrip,
                report: FeedbackFields(from: report),
                reportHex: Hex.string(try report.encode())
            )
        )
    }

    let nominalReport = FeedbackReport(
        pathId: 0,
        clientTimestamp: ClientTimestamp(microseconds: 0x4142_4344_4546_4748),
        channels: [
            .init(channel: .videoActive, highestSeq: ChannelSeq(rawValue: 0x1234),
                  received: 100_000, missing: 5, duplicates: 2),
            .init(channel: .audio, highestSeq: ChannelSeq(rawValue: 0xFFFF),
                  received: 200_000, missing: 0, duplicates: 0),
        ],
        dispersion: .init(
            base: ClientTimestamp(microseconds: 5_000_000),
            samples: [
                .init(channel: .videoActive, seq: ChannelSeq(rawValue: 0x1230),
                      arrivalDeltaMicroseconds: 0),
                .init(channel: .videoActive, seq: ChannelSeq(rawValue: 0x1231),
                      arrivalDeltaMicroseconds: 500),
                .init(channel: .videoActive, seq: ChannelSeq(rawValue: 0x1232),
                      arrivalDeltaMicroseconds: 1_000),
            ]
        ),
        nacks: [
            try .init(frame: FrameNumber(rawValue: 0x000A_0B0C),
                      missingShards: [0, 2]),
        ],
        extensions: [try WireExtension(type: 0x7F, value: [0xAA, 0xBB])]
    )
    try feedbackRoundtrip(
        name: "feedback-nominal",
        description: "Every section populated small: two channel ledgers, a "
            + "three-packet dispersion train, one NACK (frame 0x000a0b0c, "
            + "shards 0+2 → bitmap 0x05), one unknown TLV. Matches the "
            + "hand-computed anchor in FeedbackReportTests.",
        nominalReport
    )

    try feedbackRoundtrip(
        name: "feedback-empty-sections",
        description: "A quiet window: header only, 21 bytes, dispersionBase "
            + "zero by rule.",
        FeedbackReport(clientTimestamp: ClientTimestamp(microseconds: 123_456))
    )

    let maxedReport = FeedbackReport(
        pathId: 0,
        clientTimestamp: ClientTimestamp(microseconds: 0xFFFF_FFFF_FFFF_FFFF),
        channels: (0..<8).map {
            .init(channel: ChannelId(rawValue: $0),
                  highestSeq: ChannelSeq(rawValue: UInt16($0) &* 0x1111),
                  received: 0xFFFF_FFFF, missing: 0xFFFF_FFFF,
                  duplicates: 0xFFFF_FFFF)
        },
        dispersion: .init(
            base: ClientTimestamp(microseconds: 1),
            samples: (0..<112).map {
                .init(channel: .videoActive,
                      seq: ChannelSeq(rawValue: UInt16($0)),
                      arrivalDeltaMicroseconds: UInt32($0) * 0x02_4924)
            }
        ),
        nacks: try (0..<6).map {
            try .init(frame: FrameNumber(rawValue: UInt32($0)),
                      missingShards: Array(0...254))
        }
    )
    try feedbackRoundtrip(
        name: "feedback-bounds-maxed",
        description: "Every bound at its maximum — 8 channel blocks, 112 "
            + "samples, 6 NACKs with full 32-byte bitmaps — the 1035 B "
            + "structural ceiling, inside the 1112 B shard budget.",
        maxedReport
    )

    var fullBudget = maxedReport
    fullBudget.extensions = [
        try WireExtension(type: 0x7F,
                          value: (0..<74).map { UInt8($0) })
    ]
    try feedbackRoundtrip(
        name: "feedback-full-budget",
        description: "Bounds-maxed plus a 74-byte TLV: exactly 1112 bytes, "
            + "the largest legal report.",
        fullBudget
    )

    // MARK: Feedback lenient decode

    var feedbackReserved = try nominalReport.encode()
    feedbackReserved[1] |= 0x80
    feedbackVectors.append(
        FeedbackVector(
            name: "feedback-reserved-flags-ignored",
            description: "Reserved flag bit 7 set: decodes identically to "
                + "feedback-nominal, canonical re-encode differs.",
            kind: .decodeLenient,
            report: FeedbackFields(from: nominalReport),
            reportHex: Hex.string(feedbackReserved)
        )
    )

    // MARK: Feedback encode rejects

    func encodeReject(
        name: String, description: String, _ report: FeedbackReport,
        error: FeedbackError
    ) {
        feedbackVectors.append(
            FeedbackVector(
                name: name, description: description, kind: .encodeReject,
                report: FeedbackFields(from: report),
                error: feedbackErrorName(error)
            )
        )
    }

    var overChannels = nominalReport
    overChannels.channels = (0..<9).map {
        .init(channel: ChannelId(rawValue: $0),
              highestSeq: ChannelSeq(rawValue: 0), received: 0, missing: 0,
              duplicates: 0)
    }
    encodeReject(
        name: "feedback-too-many-channels",
        description: "9 channel blocks, bound is 8.",
        overChannels, error: .tooManyChannelBlocks(9)
    )

    var overSamples = nominalReport
    overSamples.dispersion = .init(
        base: ClientTimestamp(microseconds: 0),
        samples: (0..<113).map {
            .init(channel: .videoActive, seq: ChannelSeq(rawValue: UInt16($0)),
                  arrivalDeltaMicroseconds: UInt32($0))
        }
    )
    encodeReject(
        name: "feedback-too-many-samples",
        description: "113 dispersion samples, bound is 112.",
        overSamples, error: .tooManyDispersionSamples(113)
    )

    var overNacks = nominalReport
    overNacks.nacks = try (0..<7).map {
        try .init(frame: FrameNumber(rawValue: UInt32($0)), missingShards: [0])
    }
    encodeReject(
        name: "feedback-too-many-nacks",
        description: "7 NACK entries, bound is 6.",
        overNacks, error: .tooManyNackEntries(7)
    )

    var deltaOverflow = nominalReport
    deltaOverflow.dispersion = .init(
        base: ClientTimestamp(microseconds: 0),
        samples: [.init(channel: .videoActive, seq: ChannelSeq(rawValue: 0),
                        arrivalDeltaMicroseconds: 0x0100_0000)]
    )
    encodeReject(
        name: "feedback-delta-overflow",
        description: "A 2^24 µs sample delta: does not fit the u24 field, "
            + "rejected rather than silently truncated.",
        deltaOverflow, error: .arrivalDeltaOutOfRange(0x0100_0000)
    )

    var overBudget = maxedReport
    overBudget.extensions = [
        try WireExtension(type: 0x7F,
                          value: (0..<75).map { UInt8($0) })
    ]
    encodeReject(
        name: "feedback-over-budget-tlv",
        description: "Bounds-maxed plus a 75-byte TLV: 1113 bytes, one over "
            + "the 1112 B plaintext shard budget.",
        overBudget, error: .reportOverBudget(1113)
    )

    // MARK: Feedback decode rejects

    func decodeReject(
        name: String, description: String, bytes: [UInt8], error: FeedbackError
    ) {
        feedbackVectors.append(
            FeedbackVector(
                name: name, description: description, kind: .decodeReject,
                reportHex: Hex.string(bytes),
                error: feedbackErrorName(error)
            )
        )
    }

    let nominalBytes = try nominalReport.encode()
    let emptyBytes = try FeedbackReport(
        clientTimestamp: ClientTimestamp(microseconds: 1)
    ).encode()

    decodeReject(
        name: "feedback-truncated-header",
        description: "20 of the 21 fixed header bytes.",
        bytes: Array(emptyBytes.dropLast()),
        error: .truncatedReport
    )
    decodeReject(
        name: "feedback-truncated-sections",
        description: "feedback-nominal cut mid-channel-block.",
        bytes: Array(nominalBytes.prefix(30)),
        error: .truncatedReport
    )
    var overBoundsCount = emptyBytes
    overBoundsCount[19] = 200
    decodeReject(
        name: "feedback-sample-count-over-bounds",
        description: "sampleCount byte says 200, bound is 112: rejected on "
            + "the count itself, before any section parsing.",
        bytes: overBoundsCount,
        error: .tooManyDispersionSamples(200)
    )
    var nonZeroBase = emptyBytes
    nonZeroBase[10] = 0x01
    decodeReject(
        name: "feedback-nonzero-base-no-samples",
        description: "dispersionBase non-zero with sampleCount 0 — a fill "
            + "bug, kept loud.",
        bytes: nonZeroBase,
        error: .nonZeroBaseWithoutSamples
    )
    var bitmapZero = emptyBytes
    bitmapZero[20] = 1
    bitmapZero += [0x01, 0x00, 0x00, 0x00, 0x00]
    decodeReject(
        name: "feedback-nack-bitmap-count-zero",
        description: "A NACK entry with bitmapByteCount 0: a NACK must name "
            + "at least one shard.",
        bytes: bitmapZero,
        error: .nackBitmapByteCountOutOfRange(0)
    )
    var bitmapOversize = emptyBytes
    bitmapOversize[20] = 1
    bitmapOversize += [0x01, 0x00, 0x00, 0x00, 33]
        + [UInt8](repeating: 0xFF, count: 33)
    decodeReject(
        name: "feedback-nack-bitmap-count-oversize",
        description: "bitmapByteCount 33: 32 bytes already covers the whole "
            + "255-shard GF(2^8) block.",
        bytes: bitmapOversize,
        error: .nackBitmapByteCountOutOfRange(33)
    )
    var bitmapNonCanonical = emptyBytes
    bitmapNonCanonical[20] = 1
    bitmapNonCanonical += [0x01, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00]
    decodeReject(
        name: "feedback-nack-bitmap-noncanonical",
        description: "A two-byte bitmap whose final byte is zero: the bitmap "
            + "is sized by its highest set bit.",
        bytes: bitmapNonCanonical,
        error: .nonCanonicalNackBitmap
    )
    decodeReject(
        name: "feedback-trailing-bytes",
        description: "One byte past the report's end: the payload is exactly "
            + "the report.",
        bytes: nominalBytes + [0x00],
        error: .trailingBytes
    )
    decodeReject(
        name: "feedback-truncated-tlv",
        description: "feedback-nominal with the TLV value's last byte cut.",
        bytes: Array(nominalBytes.dropLast()),
        error: .truncatedReport
    )

    // MARK: The worked example

    let workedExample = ClockWorkedExample(
        description: "True offset (client − host) 250,000 µs; forward path "
            + "3,000 µs, reverse 5,000 µs, client turnaround 500 µs. "
            + "t1=1,000,000 (beacon hostSend), t2=1,253,000 (clientReceive), "
            + "t3=1,253,500 (clientSend), t4=1,008,500 (host receive, "
            + "measured locally). rtt = (t4−t1)−(t3−t2) = 8,000. offset = "
            + "((t2−t1)+(t3−t4))/2 = 249,000 — 1,000 µs shy of truth, "
            + "exactly the path asymmetry / 2 the timing doc's min-filter "
            + "accepts.",
        echoHex: Hex.string(workedEcho.encode()),
        hostReceiveHex: Hex.uint64String(1_008_500),
        offsetMicroseconds: 249_000,
        rttMicroseconds: 8_000
    )

    return BeaconVectorFile(
        format: BeaconVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        beaconVectors: beaconVectors,
        feedbackVectors: feedbackVectors,
        clockWorkedExample: workedExample
    )
}
