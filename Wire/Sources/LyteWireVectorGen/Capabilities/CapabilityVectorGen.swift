// Capability vector authoring (W7): the deterministic CBOR profile,
// the typed capability set, the intersect algebra as data, and the
// CTRL codecs 0x0F/0x11/0x12. Run once, commit, freeze. The
// circularity is broken by RFC 8949's appendix-A examples (transcribed
// into CborTests as external anchors) and the hand-computed set/
// message bytes in CapabilitiesTests / CapabilityCodecTests.

import LyteCore
import LyteWire
import LyteWireTestKit

func makeCapabilityVectorFile() throws -> CapabilityVectorFile {
    CapabilityVectorFile(
        format: CapabilityVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        cborVectors: try makeCborVectors(),
        setVectors: try makeSetVectors(),
        intersectVectors: try makeIntersectVectors(),
        messageVectors: try makeMessageVectors()
    )
}

// MARK: - The CBOR profile

private func makeCborVectors() throws -> [CapabilityCborVector] {
    var vectors: [CapabilityCborVector] = []

    func canonical(_ name: String, _ description: String, _ value: CborValue) throws {
        vectors.append(CapabilityCborVector(
            name: name, description: description, kind: .canonical,
            cborHex: Hex.string(try Cbor.encode(value))
        ))
    }
    func reject(_ name: String, _ description: String, _ hex: String, _ error: String) {
        vectors.append(CapabilityCborVector(
            name: name, description: description, kind: .decodeReject,
            cborHex: hex, error: error
        ))
    }

    try canonical(
        "unsigned-argument-widths",
        "Every shortest-form argument width in one array: 23 (immediate),"
            + " 24 (u8), 256 (u16), 65536 (u32), 2^32 (u64) — the RFC 8949"
            + " appendix-A ladder.",
        .array([
            .unsigned(23), .unsigned(24), .unsigned(256),
            .unsigned(65536), .unsigned(0x1_0000_0000),
        ])
    )
    try canonical(
        "negative-and-simple",
        "Negative integers (−1, −100) and the three profile simple"
            + " values.",
        .array([
            .negative(0), .negative(99), .bool(true), .bool(false), .null,
        ])
    )
    try canonical(
        "bytes-and-text",
        "RFC 8949 appendix-A byte and text strings: h'01020304' and"
            + " \"IETF\".",
        .array([.bytes([0x01, 0x02, 0x03, 0x04]), .text("IETF")])
    )
    try canonical(
        "nested-arrays",
        "RFC 8949 appendix-A [1, [2, 3], [4, 5]].",
        .array([
            .unsigned(1),
            .array([.unsigned(2), .unsigned(3)]),
            .array([.unsigned(4), .unsigned(5)]),
        ])
    )
    try canonical(
        "map-key-order",
        "Integer keys before text keys, bytewise over the encodings —"
            + " the §4.2.1 deterministic order.",
        .map([
            .init(key: .unsigned(1), value: .unsigned(2)),
            .init(key: .unsigned(100), value: .null),
            .init(key: .text("a"), value: .array([.unsigned(2), .unsigned(3)])),
        ])
    )

    reject(
        "non-shortest-u8",
        "Argument 23 in the one-byte form — well-formed CBOR, not the"
            + " shortest form, rejected.",
        "1817", "nonCanonicalArgument"
    )
    reject(
        "non-shortest-u16",
        "Argument 255 in the two-byte form.",
        "1900ff", "nonCanonicalArgument"
    )
    reject(
        "misordered-map-keys",
        "{2: 0, 1: 0} — keys out of bytewise order.",
        "a202000100", "misorderedMapKeys"
    )
    reject(
        "duplicate-map-key",
        "{1: 0, 1: 0}.",
        "a201000100", "duplicateMapKey"
    )
    reject(
        "indefinite-array",
        "The indefinite-length marker is outside the profile.",
        "9f00ff", "unsupportedItem"
    )
    reject(
        "tag",
        "Major type 6 (a tag) is outside the profile.",
        "c000", "unsupportedItem"
    )
    reject(
        "float",
        "Float16 0.0 — no floats in the profile.",
        "f90000", "unsupportedItem"
    )
    reject(
        "undefined",
        "Simple value `undefined` — only false/true/null pass.",
        "f7", "unsupportedItem"
    )
    reject(
        "truncated-argument",
        "A u16 argument cut mid-byte.",
        "1904", "truncatedItem"
    )
    reject(
        "trailing-bytes",
        "One item then garbage — the buffer is exactly one item.",
        "0000", "trailingBytes"
    )
    reject(
        "invalid-utf8",
        "A text string whose bytes are not UTF-8.",
        "62c328", "invalidUtf8"
    )
    reject(
        "nesting-too-deep",
        "Eight nested arrays put the innermost item at the depth cap.",
        String(repeating: "81", count: 8) + "00", "nestingTooDeep"
    )
    return vectors
}

// MARK: - The typed capability set

private func fullHouseSet() -> Capabilities {
    Capabilities(
        wireMinor: 3,
        videoCodecs: [CapabilityCodec.hevc, 2],
        chromaModes: [CapabilityChroma.yuv420, CapabilityChroma.yuv444],
        idleSilence: true,
        featureChannels: [
            CapabilityFeature.clipboard,
            CapabilityFeature.fileTransfer,
            CapabilityFeature.printing,
        ],
        audioExpress: true,
        resume: true,
        maxDatagramBytes: 1500
    )
}

private func makeSetVectors() throws -> [CapabilitySetVector] {
    var vectors: [CapabilitySetVector] = []

    vectors.append(CapabilitySetVector(
        name: "wire-default",
        description: "Capabilities.wireDefault — the hand-computed anchor"
            + " (CapabilitiesTests): minor 0, HEVC, 4:2:0, idle-silence,"
            + " no features, 1152 B ceiling.",
        kind: .roundtrip,
        cborHex: Hex.string(try Capabilities.wireDefault.encodeCbor()),
        set: CapabilitySetFields(Capabilities.wireDefault)
    ))
    vectors.append(CapabilitySetVector(
        name: "full-house",
        description: "Every v1 key at a non-default value, including a"
            + " foreign codec id (2) carried in the list.",
        kind: .roundtrip,
        cborHex: Hex.string(try fullHouseSet().encodeCbor()),
        set: CapabilitySetFields(fullHouseSet())
    ))
    var withUnknown = Capabilities.wireDefault
    withUnknown.unknownEntries = [
        CborMapEntry(key: .unsigned(100), value: .text("x"))
    ]
    vectors.append(CapabilitySetVector(
        name: "unknown-key-preserved",
        description: "wireDefault plus foreign key 100 → \"x\": the"
            + " unknown-key-ignored rule — decodes, typed fields"
            + " unaffected, re-encodes byte-exact.",
        kind: .roundtrip,
        cborHex: Hex.string(try withUnknown.encodeCbor()),
        set: CapabilitySetFields(withUnknown)
    ))
    let lean = try Cbor.encode(.map([
        .init(key: .unsigned(CapabilityKey.wireMinor), value: .unsigned(0)),
        .init(
            key: .unsigned(CapabilityKey.videoCodecs),
            value: .array([.unsigned(CapabilityCodec.hevc)])
        ),
        .init(
            key: .unsigned(CapabilityKey.chromaModes),
            value: .array([.unsigned(CapabilityChroma.yuv420)])
        ),
    ]))
    vectors.append(CapabilitySetVector(
        name: "required-keys-only",
        description: "Only the three required keys — the optional five"
            + " default to unsupported / the 1152 B floor. Decode-only:"
            + " a v1 re-encode emits all eight keys explicitly, so this"
            + " legal-but-lean form is not byte-stable.",
        kind: .decodeLenient,
        cborHex: Hex.string(lean),
        set: CapabilitySetFields(try Capabilities.decodeCbor(lean))
    ))

    func reject(_ name: String, _ description: String, _ hex: String, _ error: String) {
        vectors.append(CapabilitySetVector(
            name: name, description: description, kind: .decodeReject,
            cborHex: hex, error: error
        ))
    }
    reject(
        "missing-video-codecs",
        "wireMinor and chromaModes only — videoCodecs is required.",
        Hex.string(try Cbor.encode(.map([
            .init(key: .unsigned(1), value: .unsigned(0)),
            .init(key: .unsigned(3), value: .array([.unsigned(1)])),
        ]))),
        "missingKey"
    )
    reject(
        "wrong-type-minor",
        "wireMinor as a text string — registered keys carry their"
            + " registered types.",
        Hex.string(try Cbor.encode(.map([
            .init(key: .unsigned(1), value: .text("1")),
            .init(key: .unsigned(2), value: .array([.unsigned(1)])),
            .init(key: .unsigned(3), value: .array([.unsigned(1)])),
        ]))),
        "wrongValueType"
    )
    reject(
        "descending-id-list",
        "chromaModes [2, 1] — id lists are strictly ascending.",
        Hex.string(try Cbor.encode(.map([
            .init(key: .unsigned(1), value: .unsigned(0)),
            .init(key: .unsigned(2), value: .array([.unsigned(1)])),
            .init(
                key: .unsigned(3),
                value: .array([.unsigned(2), .unsigned(1)])
            ),
        ]))),
        "nonCanonicalIdList"
    )
    reject(
        "ceiling-below-floor",
        "maxDatagramBytes 1151 — below the 1152 B protocol floor.",
        Hex.string(try Cbor.encode(.map([
            .init(key: .unsigned(1), value: .unsigned(0)),
            .init(key: .unsigned(2), value: .array([.unsigned(1)])),
            .init(key: .unsigned(3), value: .array([.unsigned(1)])),
            .init(key: .unsigned(8), value: .unsigned(1151)),
        ]))),
        "datagramCeilingBelowFloor"
    )
    reject(
        "not-a-map",
        "A top-level array — a declaration body is a map.",
        "810a", "notAMap"
    )
    return vectors
}

// MARK: - The intersect algebra as data

private func makeIntersectVectors() throws -> [CapabilityIntersectVector] {
    var vectors: [CapabilityIntersectVector] = []

    func pin(
        _ name: String, _ description: String,
        _ a: Capabilities, _ b: Capabilities
    ) throws {
        let forward = a.intersecting(b)
        precondition(
            forward == b.intersecting(a),
            "intersect must be commutative before it is frozen"
        )
        vectors.append(CapabilityIntersectVector(
            name: name, description: description,
            aHex: Hex.string(try a.encodeCbor()),
            bHex: Hex.string(try b.encodeCbor()),
            agreedHex: Hex.string(try forward.encodeCbor())
        ))
    }

    let modest = Capabilities(
        wireMinor: 0,
        videoCodecs: [CapabilityCodec.hevc],
        chromaModes: [CapabilityChroma.yuv420],
        idleSilence: true,
        featureChannels: [CapabilityFeature.clipboard],
        audioExpress: false,
        resume: true,
        maxDatagramBytes: 1400
    )
    try pin(
        "nominal-asymmetric",
        "A full-house host against a modest client: min minor, HEVC"
            + " only, 4:2:0 only, clipboard only, AND'd booleans, min"
            + " ceiling.",
        fullHouseSet(), modest
    )
    try pin(
        "identical-idempotent",
        "A set against itself — the idempotence law as bytes.",
        fullHouseSet(), fullHouseSet()
    )
    var noFeatures = modest
    noFeatures.featureChannels = [CapabilityFeature.printing]
    noFeatures.resume = false
    try pin(
        "disjoint-features",
        "Disjoint feature lists intersect to empty — absence is"
            + " \"not supported\", never an error.",
        modest, noFeatures
    )
    var withUnknowns = modest
    withUnknowns.unknownEntries = [
        CborMapEntry(key: .unsigned(100), value: .unsigned(7)),
        CborMapEntry(key: .unsigned(101), value: .text("a")),
    ]
    var withSharedUnknown = fullHouseSet()
    withSharedUnknown.unknownEntries = [
        CborMapEntry(key: .unsigned(100), value: .unsigned(7)),
        CborMapEntry(key: .unsigned(101), value: .text("b")),
    ]
    try pin(
        "unknown-entries-byte-equal-rule",
        "Foreign keys survive intersection only on byte-equal"
            + " agreement: key 100 (equal values) survives, key 101"
            + " (differing values) drops.",
        withUnknowns, withSharedUnknown
    )
    return vectors
}

// MARK: - The message codecs

private func makeMessageVectors() throws -> [CapabilityMessageVector] {
    var vectors: [CapabilityMessageVector] = []

    let raiseParameters = [CapabilityParameter(
        key: CapabilityKey.maxDatagramBytes, value: .unsigned(1500)
    )]

    vectors.append(CapabilityMessageVector(
        name: "declaration-wire-default",
        description: "0x0F carrying Capabilities.wireDefault — the"
            + " hand-computed anchor (CapabilityCodecTests).",
        kind: .roundtrip, codec: .declaration,
        messageHex: Hex.string(
            try CapabilityDeclaration(capabilities: .wireDefault).encode()
        )
    ))
    vectors.append(CapabilityMessageVector(
        name: "declaration-full-house",
        description: "0x0F carrying every v1 key at a non-default"
            + " value.",
        kind: .roundtrip, codec: .declaration,
        messageHex: Hex.string(
            try CapabilityDeclaration(capabilities: fullHouseSet()).encode()
        )
    ))
    vectors.append(CapabilityMessageVector(
        name: "update-geometry-raise",
        description: "0x11 proposing maxDatagramBytes 1500 — the"
            + " DPLPMTUD raise, v1's one renegotiable key.",
        kind: .roundtrip, codec: .update,
        messageHex: Hex.string(
            try CapabilityUpdate(parameters: raiseParameters).encode()
        )
    ))
    vectors.append(CapabilityMessageVector(
        name: "ack-accepted",
        description: "0x12 status 0x01, echoing the raise proposal"
            + " verbatim.",
        kind: .roundtrip, codec: .updateAck,
        messageHex: Hex.string(try CapabilityUpdateAck(
            status: .accepted, parameters: raiseParameters
        ).encode())
    ))
    vectors.append(CapabilityMessageVector(
        name: "ack-rejected",
        description: "0x12 status 0x02 — a refused proposal, echoed.",
        kind: .roundtrip, codec: .updateAck,
        messageHex: Hex.string(try CapabilityUpdateAck(
            status: .rejected, parameters: raiseParameters
        ).encode())
    ))

    func reject(
        _ name: String, _ description: String,
        _ codec: CapabilityMessageVector.Codec,
        _ hex: String, _ error: String
    ) {
        vectors.append(CapabilityMessageVector(
            name: name, description: description, kind: .decodeReject,
            codec: codec, messageHex: hex, error: error
        ))
    }
    reject(
        "declaration-truncated",
        "The type byte alone — a declaration has a body.",
        .declaration, "0f", "truncatedMessage"
    )
    reject(
        "declaration-bad-type",
        "An IDR-request type byte fed to the declaration decoder.",
        .declaration, "10a0", "unexpectedType"
    )
    reject(
        "declaration-body-not-a-map",
        "A CBOR array where the capability map belongs.",
        .declaration, "0f810a", "malformedBody"
    )
    reject(
        "declaration-over-budget",
        "1025 bytes — past the 1024 B capability-message ceiling, the"
            + " anti-streaming stop, refused before any CBOR work.",
        .declaration, "0f" + String(repeating: "00", count: 1024),
        "messageOverBudget"
    )
    reject(
        "update-empty-map",
        "An empty proposal map — a no-op update is a bug, not a"
            + " message.",
        .update, "11a0", "emptyUpdate"
    )
    reject(
        "update-text-key",
        "{\"a\": 0} — parameter keys are registry numbers.",
        .update, "11a1616100", "nonIntegerParameterKey"
    )
    reject(
        "update-non-canonical-body",
        "A proposal whose CBOR argument (23 in the u8 form) is not"
            + " shortest-form — deterministic encoding is enforced end"
            + " to end.",
        .update, "11a1081817", "malformedBody"
    )
    reject(
        "ack-unknown-status",
        "Status 0x03 — unassigned.",
        .updateAck, "1203a1081905dc", "unknownStatus"
    )
    reject(
        "ack-zero-status",
        "Status 0x00 — the loud zero-fill bug, never a value.",
        .updateAck, "1200a1081905dc", "unknownStatus"
    )
    reject(
        "ack-truncated",
        "The type byte alone — an ack has a status and a body.",
        .updateAck, "12", "truncatedMessage"
    )
    return vectors
}
