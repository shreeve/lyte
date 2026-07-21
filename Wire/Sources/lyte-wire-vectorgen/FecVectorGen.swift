// FEC vector authoring (W1): fec-field round trips, the parity ladder as
// data, and RS recovery matrices. Same freeze discipline as the envelope
// file. Circularity note: the field vectors are anchored by hand-computed
// bytes in FecFieldTests; the RS parity bytes are anchored by the k=1,m=1
// identity case (nanors' codebook makes that parity shard a byte-copy of
// the data shard — verifiable by eye) plus decode-recovers-encode across
// every matrix, and byte-equality across both platforms.

import LyteWire
import LyteWireTestKit

func makeFecVectorFile() throws -> FecVectorFile {
    var fieldVectors: [FecFieldVector] = []

    func roundtrip(name: String, description: String, field: FecField) {
        fieldVectors.append(
            FecFieldVector(
                name: name,
                description: description,
                kind: .roundtrip,
                field: FecFieldFields(from: field),
                rawHex: Hex.uint64String(field.encoded),
                error: nil
            )
        )
    }

    func reject(name: String, description: String, raw: UInt64, error: String) {
        fieldVectors.append(
            FecFieldVector(
                name: name,
                description: description,
                kind: .decodeReject,
                field: nil,
                rawHex: Hex.uint64String(raw),
                error: error
            )
        )
    }

    // MARK: fec-field round trips

    roundtrip(
        name: "none",
        description: "The all-zero field: no FEC-coded payload. What CTRL, "
            + "feedback, and idle datagrams carry.",
        field: .none
    )

    let nominal = try FecGeometry(
        dataShards: 4, parityShards: 2, groupByteCount: 4000
    )
    roundtrip(
        name: "rs-nominal-parity-shard",
        description: "k=4 m=2 over 4000 B, shard 5 (last parity). The "
            + "hand-computed anchor in FecFieldTests.",
        field: try FecField.reedSolomonShard(5, of: nominal)
    )
    roundtrip(
        name: "rs-nominal-first-data-shard",
        description: "Same group, shard 0: only the shardIndex byte moves.",
        field: try FecField.reedSolomonShard(0, of: nominal)
    )

    roundtrip(
        name: "rs-tiny-frame",
        description: "k=1 m=1 over 100 B — the ladder's heavy protection on "
            + "a tiny damage frame (100% parity).",
        field: try FecField.reedSolomonShard(
            0,
            of: try FecGeometry(dataShards: 1, parityShards: 1, groupByteCount: 100)
        )
    )

    roundtrip(
        name: "rs-audio-4-2",
        description: "The audio interleave shape (W8): k=4 m=2, 480 B group, "
            + "middle data shard.",
        field: try FecField.reedSolomonShard(
            2,
            of: try FecGeometry(dataShards: 4, parityShards: 2, groupByteCount: 480)
        )
    )

    roundtrip(
        name: "rs-parity-free",
        description: "m=0: a plain split with no protection. The ladder never "
            + "yields it, but the mechanism admits it and the field carries it.",
        field: try FecField.reedSolomonShard(
            2,
            of: try FecGeometry(dataShards: 3, parityShards: 0, groupByteCount: 3000)
        )
    )

    roundtrip(
        name: "rs-max-block",
        description: "The largest lossy-regime block: k=204 m=51 (255 shards) "
            + "over the full 204×1112 B, last shard index 254.",
        field: try FecField.reedSolomonShard(
            254,
            of: try FecGeometry(
                dataShards: 204, parityShards: 51, groupByteCount: 204 * 1112
            )
        )
    )

    // MARK: fec-field lenient decodes (reserved byte 7)

    let nominalRaw = try FecField.reedSolomonShard(5, of: nominal).encoded
    fieldVectors.append(
        FecFieldVector(
            name: "rs-reserved-byte-ignored",
            description: "Byte 7 is reserved: MUST be 0 on send, ignored on "
                + "receive — decodes identically to rs-nominal-parity-shard.",
            kind: .decodeLenient,
            field: FecFieldFields(
                from: try FecField.decode(nominalRaw | 0xAB00_0000_0000_0000)
            ),
            rawHex: Hex.uint64String(nominalRaw | 0xAB00_0000_0000_0000),
            error: nil
        )
    )
    fieldVectors.append(
        FecFieldVector(
            name: "none-reserved-byte-ignored",
            description: "Scheme none with only byte 7 set: still none — the "
                + "reserved-byte rule applies to every scheme.",
            kind: .decodeLenient,
            field: FecFieldFields(from: FecField.none),
            rawHex: Hex.uint64String(0x0100_0000_0000_0000),
            error: nil
        )
    )

    // MARK: fec-field decode rejects

    reject(
        name: "unknown-scheme",
        description: "Scheme byte 0x02 names nothing.",
        raw: 0x0000_0064_0201_0100,
        error: "unknownScheme"
    )
    reject(
        name: "non-zero-none",
        description: "Scheme none with geometry bytes set: some other "
            + "layer's zero-fill bug, kept loud.",
        raw: 0x0000_0000_0000_0100,
        error: "nonZeroNoneField"
    )
    reject(
        name: "zero-data-shards",
        description: "RS with k=0.",
        raw: 0x0000_0064_0102_0000,
        error: "dataShardsOutOfRange"
    )
    reject(
        name: "over-gf256-block",
        description: "k=200 m=60: 260 total shards bursts the GF(2^8) "
            + "255-shard block.",
        raw: 0x0003_0D40_013C_C800,
        error: "parityShardsOutOfRange"
    )
    reject(
        name: "group-over-budget",
        description: "k=1 over 1113 B: one byte past k x 1112.",
        raw: 0x0000_0459_0101_0100,
        error: "groupByteCountOutOfRange"
    )
    reject(
        name: "zero-group-bytes",
        description: "A group of zero bytes cannot need shards.",
        raw: 0x0000_0000_0101_0100,
        error: "groupByteCountOutOfRange"
    )
    reject(
        name: "over-provisioned-shards",
        description: "k=4 over 5 B: the balanced split (bs=2) would leave "
            + "the trailing shard empty — k over-provisioned for the bytes.",
        raw: 0x0000_0005_0102_0400,
        error: "overProvisionedDataShards"
    )
    reject(
        name: "shard-index-out-of-range",
        description: "Shard 6 of a 6-shard block (k=4 m=2): indices end "
            + "at k+m-1.",
        raw: 0x0000_0FA0_0102_0406,
        error: "shardIndexOutOfRange"
    )

    // MARK: The parity ladder as data (resiliency §5.2)

    var geometryRows: [FecGeometryRow] = []
    let ladderProbes = [1, 2, 3, 4, 5, 8, 9, 20, 32, 33, 100, 204, 205, 231, 232, 255]
    for regime in FecRegime.allCases {
        for k in ladderProbes {
            geometryRows.append(
                FecGeometryRow(
                    dataShards: k,
                    regime: regime,
                    parityShards: try? FecGeometryTable.parityShards(
                        forDataShards: k, regime: regime
                    )
                )
            )
        }
    }

    // MARK: RS recovery matrices

    var matrices: [FecRecoveryMatrix] = []

    func matrix(
        name: String,
        description: String,
        geometry: FecGeometry,
        group: [UInt8],
        erased: [Int],
        expect: FecRecoveryMatrix.Expect
    ) throws {
        let shards = try FecEncoder.encode(group: group, geometry: geometry)
        matrices.append(
            FecRecoveryMatrix(
                name: name,
                description: description,
                geometry: geometry,
                groupHex: Hex.string(group),
                shardsHex: shards.map(Hex.string),
                erasedIndices: erased,
                expect: expect
            )
        )
    }

    try matrix(
        name: "k4m2-all-present",
        description: "The reference block: k=4 m=2 over 48 B (bs=12), no "
            + "erasures. Pins the encoder's parity bytes for every other "
            + "k4m2 matrix.",
        geometry: try FecGeometry(dataShards: 4, parityShards: 2, groupByteCount: 48),
        group: counting(from: 0x00, count: 48),
        erased: [],
        expect: .recovered
    )

    try matrix(
        name: "k4m2-data-erasures-1-3",
        description: "Shards 1 and 3 erased — two data losses, both parity "
            + "shards spent, recovery byte-exact.",
        geometry: try FecGeometry(dataShards: 4, parityShards: 2, groupByteCount: 48),
        group: counting(from: 0x00, count: 48),
        erased: [1, 3],
        expect: .recovered
    )

    try matrix(
        name: "k4m2-mixed-erasure",
        description: "One data shard (2) and one parity shard (4) erased: "
            + "the surviving parity covers the data gap.",
        geometry: try FecGeometry(dataShards: 4, parityShards: 2, groupByteCount: 48),
        group: counting(from: 0x00, count: 48),
        erased: [2, 4],
        expect: .recovered
    )

    try matrix(
        name: "k4m2-parity-only-erasures",
        description: "Both parity shards erased, all data present: the "
            + "no-recovery fast path.",
        geometry: try FecGeometry(dataShards: 4, parityShards: 2, groupByteCount: 48),
        group: counting(from: 0x00, count: 48),
        erased: [4, 5],
        expect: .recovered
    )

    try matrix(
        name: "k4m2-unrecoverable",
        description: "Shards 0, 2, 5 erased: two data gaps, one surviving "
            + "parity — the decoder must report unrecoverableGroup, never "
            + "emit garbage.",
        geometry: try FecGeometry(dataShards: 4, parityShards: 2, groupByteCount: 48),
        group: counting(from: 0x00, count: 48),
        erased: [0, 2, 5],
        expect: .unrecoverable
    )

    try matrix(
        name: "k3m1-trailing-pad",
        description: "32 B over k=3 (bs=11, trailing shard 10 B on the "
            + "wire) with that trailing shard erased: recovery must trim "
            + "the pad byte-exact.",
        geometry: try FecGeometry(dataShards: 3, parityShards: 1, groupByteCount: 32),
        group: counting(from: 0x20, count: 32),
        erased: [2],
        expect: .recovered
    )

    try matrix(
        name: "k1m1-identity",
        description: "k=1 m=1 over 5 B: nanors' codebook makes the parity "
            + "shard a byte-copy of the data shard — the eye-verifiable "
            + "anchor for all parity bytes in this file. Data erased, "
            + "recovered from parity alone.",
        geometry: try FecGeometry(dataShards: 1, parityShards: 1, groupByteCount: 5),
        group: Array("lyte!".utf8),
        erased: [0],
        expect: .recovered
    )

    try matrix(
        name: "k1m2-tiny-lossy",
        description: "The lossy-regime tiny frame: k=1 m=2 over 3 B, data "
            + "and first parity erased, recovered from the second parity.",
        geometry: try FecGeometry(dataShards: 1, parityShards: 2, groupByteCount: 3),
        group: [0xDE, 0xAD, 0x42],
        erased: [0, 1],
        expect: .recovered
    )

    try matrix(
        name: "k5m2-balanced-split",
        description: "53 B over k=5: bs=ceil(53/5)=11, trailing shard 9 B — "
            + "the balanced-split rule exercised off the bucket edges; last "
            + "data shard and one parity erased.",
        geometry: try FecGeometry(dataShards: 5, parityShards: 2, groupByteCount: 53),
        group: counting(from: 0x80, count: 53),
        erased: [4, 6],
        expect: .recovered
    )

    try matrix(
        name: "k2m1-full-budget-shards",
        description: "2224 B = 2 x 1112: every shard at the full plaintext "
            + "budget, first data shard erased — the budget interaction at "
            + "vector level.",
        geometry: try FecGeometry(dataShards: 2, parityShards: 1, groupByteCount: 2224),
        group: counting(from: 0x00, count: 2224),
        erased: [0],
        expect: .recovered
    )

    return FecVectorFile(
        format: FecVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        fieldVectors: fieldVectors,
        geometryRows: geometryRows,
        recoveryMatrices: matrices
    )
}
