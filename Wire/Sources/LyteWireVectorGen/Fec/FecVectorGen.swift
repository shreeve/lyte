// Authors Vectors/fec-v1.json: field round trips, the parity ladder, and
// RS recovery matrices. Field vectors are anchored by FecFieldTests; RS
// parity by the k=1,m=1 identity case (parity is a byte-copy of the data
// shard) plus decode-recovers-encode across every matrix.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeFecVectorFile() throws -> FecVectorFile {
    var fieldVectors: [FecFieldVector] = []

    func shard(_ index: Int, k: Int, m: Int, bytes: Int) throws -> FecField {
        try FecField.reedSolomonShard(index, of: try FecGeometry(
            dataShards: k, parityShards: m, groupByteCount: bytes
        ))
    }

    // MARK: fec-field round trips

    for (name, description, field) in [
        ("none",
         "The all-zero field: no FEC-coded payload. What CTRL, feedback, and "
            + "idle datagrams carry.",
         FecField.none),
        ("rs-nominal-parity-shard",
         "k=4 m=2 over 4000 B, shard 5 (last parity). The hand-computed "
            + "anchor in FecFieldTests.",
         try shard(5, k: 4, m: 2, bytes: 4000)),
        ("rs-nominal-first-data-shard",
         "Same group, shard 0: only the shardIndex byte moves.",
         try shard(0, k: 4, m: 2, bytes: 4000)),
        ("rs-tiny-frame",
         "k=1 m=1 over 100 B — the ladder's heavy protection on a tiny damage "
            + "frame (100% parity).",
         try shard(0, k: 1, m: 1, bytes: 100)),
        ("rs-audio-4-2",
         "The audio interleave shape (W8): k=4 m=2, 480 B group, middle data "
            + "shard.",
         try shard(2, k: 4, m: 2, bytes: 480)),
        ("rs-parity-free",
         "m=0: a plain split with no protection. The ladder never yields it, "
            + "but the mechanism admits it and the field carries it.",
         try shard(2, k: 3, m: 0, bytes: 3000)),
        ("rs-max-block",
         "The largest lossy-regime block: k=204 m=51 (255 shards) over the "
            + "full 204×1112 B, last shard index 254.",
         try shard(254, k: 204, m: 51, bytes: 204 * 1112)),
    ] {
        fieldVectors.append(FecFieldVector(
            name: name, description: description, kind: .roundtrip,
            field: FecFieldFields(from: field),
            rawHex: Hex.uint64String(field.encoded)
        ))
    }

    // MARK: fec-field lenient decodes (reserved byte 7)

    let reservedNominal = try shard(5, k: 4, m: 2, bytes: 4000).encoded
        | 0xAB00_0000_0000_0000
    for (name, description, raw) in [
        ("rs-reserved-byte-ignored",
         "Byte 7 is reserved: MUST be 0 on send, ignored on receive — decodes "
            + "identically to rs-nominal-parity-shard.",
         reservedNominal),
        ("none-reserved-byte-ignored",
         "Scheme none with only byte 7 set: still none — the reserved-byte "
            + "rule applies to every scheme.",
         0x0100_0000_0000_0000),
    ] {
        fieldVectors.append(FecFieldVector(
            name: name, description: description, kind: .decodeLenient,
            field: FecFieldFields(from: try FecField.decode(raw)),
            rawHex: Hex.uint64String(raw)
        ))
    }

    // MARK: fec-field decode rejects

    for (name, description, raw, error) in [
        ("unknown-scheme", "Scheme byte 0x02 names nothing.",
         0x0000_0064_0201_0100, "unknownScheme"),
        ("non-zero-none",
         "Scheme none with geometry bytes set: some other layer's zero-fill "
            + "bug, kept loud.",
         0x0000_0000_0000_0100, "nonZeroNoneField"),
        ("zero-data-shards", "RS with k=0.",
         0x0000_0064_0102_0000, "dataShardsOutOfRange"),
        ("over-gf256-block",
         "k=200 m=60: 260 total shards bursts the GF(2^8) 255-shard block.",
         0x0003_0D40_013C_C800, "parityShardsOutOfRange"),
        ("group-over-budget", "k=1 over 1113 B: one byte past k x 1112.",
         0x0000_0459_0101_0100, "groupByteCountOutOfRange"),
        ("zero-group-bytes", "A group of zero bytes cannot need shards.",
         0x0000_0000_0101_0100, "groupByteCountOutOfRange"),
        ("over-provisioned-shards",
         "k=4 over 5 B: the balanced split (bs=2) would leave the trailing "
            + "shard empty — k over-provisioned for the bytes.",
         0x0000_0005_0102_0400, "overProvisionedDataShards"),
        ("shard-index-out-of-range",
         "Shard 6 of a 6-shard block (k=4 m=2): indices end at k+m-1.",
         0x0000_0FA0_0102_0406, "shardIndexOutOfRange"),
    ] as [(String, String, UInt64, String)] {
        fieldVectors.append(FecFieldVector(
            name: name, description: description, kind: .decodeReject,
            rawHex: Hex.uint64String(raw), error: error
        ))
    }

    // MARK: The parity ladder as data

    var geometryRows: [FecGeometryRow] = []
    let ladderProbes = [1, 2, 3, 4, 5, 8, 9, 20, 32, 33, 100, 204, 205, 231, 232, 255]
    for regime in [FecRegime.clean, .lossy] {
        for k in ladderProbes {
            geometryRows.append(FecGeometryRow(
                dataShards: k, regime: regime,
                parityShards: try? FecGeometryTable.parityShards(
                    forDataShards: k, regime: regime
                )
            ))
        }
    }

    // MARK: RS recovery matrices

    let reference = counting(from: 0x00, count: 48)
    var matrices: [FecRecoveryMatrix] = []
    for (name, description, k, m, group, erased, expect) in [
        ("k4m2-all-present",
         "The reference block: k=4 m=2 over 48 B (bs=12), no erasures. Pins "
            + "the encoder's parity bytes for every other k4m2 matrix.",
         4, 2, reference, [], FecRecoveryMatrix.Expect.recovered),
        ("k4m2-data-erasures-1-3",
         "Shards 1 and 3 erased — two data losses, both parity shards spent, "
            + "recovery byte-exact.",
         4, 2, reference, [1, 3], .recovered),
        ("k4m2-mixed-erasure",
         "One data shard (2) and one parity shard (4) erased: the surviving "
            + "parity covers the data gap.",
         4, 2, reference, [2, 4], .recovered),
        ("k4m2-parity-only-erasures",
         "Both parity shards erased, all data present: the no-recovery fast "
            + "path.",
         4, 2, reference, [4, 5], .recovered),
        ("k4m2-unrecoverable",
         "Shards 0, 2, 5 erased: two data gaps, one surviving parity — the "
            + "decoder must report unrecoverableGroup, never emit garbage.",
         4, 2, reference, [0, 2, 5], .unrecoverable),
        ("k3m1-trailing-pad",
         "32 B over k=3 (bs=11, trailing shard 10 B on the wire) with that "
            + "trailing shard erased: recovery must trim the pad byte-exact.",
         3, 1, counting(from: 0x20, count: 32), [2], .recovered),
        ("k1m1-identity",
         "k=1 m=1 over 5 B: nanors' codebook makes the parity shard a "
            + "byte-copy of the data shard — the eye-verifiable anchor for all "
            + "parity bytes in this file. Data erased, recovered from parity "
            + "alone.",
         1, 1, Array("lyte!".utf8), [0], .recovered),
        ("k1m2-tiny-lossy",
         "The lossy-regime tiny frame: k=1 m=2 over 3 B, data and first "
            + "parity erased, recovered from the second parity.",
         1, 2, [0xDE, 0xAD, 0x42], [0, 1], .recovered),
        ("k5m2-balanced-split",
         "53 B over k=5: bs=ceil(53/5)=11, trailing shard 9 B — the "
            + "balanced-split rule exercised off the bucket edges; last data "
            + "shard and one parity erased.",
         5, 2, counting(from: 0x80, count: 53), [4, 6], .recovered),
        ("k2m1-full-budget-shards",
         "2224 B = 2 x 1112: every shard at the full plaintext budget, first "
            + "data shard erased — the budget interaction at vector level.",
         2, 1, counting(from: 0x00, count: 2224), [0], .recovered),
    ] as [(String, String, Int, Int, [UInt8], [Int], FecRecoveryMatrix.Expect)] {
        let geometry = try FecGeometry(
            dataShards: k, parityShards: m, groupByteCount: group.count
        )
        matrices.append(FecRecoveryMatrix(
            name: name, description: description, geometry: geometry,
            groupHex: Hex.string(group),
            shardsHex: try FecEncoder.encode(group: group, geometry: geometry)
                .map(Hex.string),
            erasedIndices: erased, expect: expect
        ))
    }

    return FecVectorFile(
        fieldVectors: fieldVectors,
        geometryRows: geometryRows,
        recoveryMatrices: matrices
    )
}
