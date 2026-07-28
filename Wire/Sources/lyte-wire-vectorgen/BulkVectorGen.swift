// Bulk-channel vector authoring (W10 / F-2 — design record
// docs/20260728-053300-lyte-bulk-channel.md): the transfer sextet
// 0x1C–0x21, the key-11 capability spine, and the worked
// multi-session transfer traces. Run once, commit, freeze. The
// circularity is broken by the hand-computed anchor bytes in
// BulkCodecTests, which pin the same nominal messages; the transfer
// traces are pinned self-consistent (no external oracle covers our
// composition) and replay through the same TestKit harness the suite
// uses.

import LyteWire
import LyteWireTestKit

func makeBulkVectorFile() throws -> BulkVectorFile {
    BulkVectorFile(
        format: BulkVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        messageVectors: try makeBulkMessageVectors(),
        capabilityVectors: try makeBulkCapabilityVectors(),
        transferVectors: try makeBulkTransferVectors()
    )
}

// MARK: - Message vectors

private func makeBulkMessageVectors() throws -> [BulkMessageVector] {
    var vectors: [BulkMessageVector] = []

    let id: UInt64 = 0x1122_3344_5566_7788
    let sha = counting(from: 0xA0, count: 32)

    // MARK: offer roundtrips

    let offerNominal = try BulkOffer(
        transferId: id,
        totalByteCount: 300_000,
        chunkByteCount: 65_536,
        sha256: sha,
        name: "report.pdf",
        mimeHint: "application/pdf"
    )
    vectors.append(BulkMessageVector(
        name: "offer-nominal",
        description: "The hand-computed anchor: 300,000 B under the "
            + "default 64 KiB chunk (5 chunks, final 37,856 B), "
            + "counting-byte sha from 0xA0.",
        kind: .roundtrip, codec: .offer,
        messageHex: Hex.string(offerNominal.encode()),
        transferIdHex: Hex.uint64String(id),
        totalByteCountHex: Hex.uint64String(300_000),
        chunkByteCount: 65_536,
        sha256Hex: Hex.string(sha),
        nameUtf8Hex: Hex.string(Array("report.pdf".utf8)),
        mimeUtf8Hex: Hex.string(Array("application/pdf".utf8))
    ))

    let offerMinimum = try BulkOffer(
        transferId: 1,
        totalByteCount: 1,
        chunkByteCount: UInt32(BulkWire.minChunkByteCount),
        sha256: counting(from: 0, count: 32),
        name: "a",
        mimeHint: ""
    )
    vectors.append(BulkMessageVector(
        name: "offer-minimum-shape",
        description: "The smallest legal offer: 1-byte blob, the "
            + "4,096 B chunk floor, 1-byte name, empty MIME hint.",
        kind: .roundtrip, codec: .offer,
        messageHex: Hex.string(offerMinimum.encode()),
        transferIdHex: Hex.uint64String(1),
        totalByteCountHex: Hex.uint64String(1),
        chunkByteCount: BulkWire.minChunkByteCount,
        sha256Hex: Hex.string(counting(from: 0, count: 32)),
        nameUtf8Hex: Hex.string(Array("a".utf8)),
        mimeUtf8Hex: ""
    ))

    // Printable-ASCII cycle (the clipboard ceiling pattern) for the
    // maxed variable fields.
    let printable = { (count: Int) -> String in
        String(decoding: (0..<count).map { UInt8(0x20 + $0 % 0x5F) },
               as: UTF8.self)
    }
    let offerMaxed = try BulkOffer(
        transferId: UInt64.max,
        totalByteCount: UInt64.max,
        chunkByteCount: UInt32(BulkWire.maxChunkByteCount),
        sha256: counting(from: 0x40, count: 32),
        name: printable(BulkWire.maxNameByteCount),
        mimeHint: printable(BulkWire.maxMimeHintByteCount)
    )
    vectors.append(BulkMessageVector(
        name: "offer-maxed-fields",
        description: "Every bound at its edge and legal: u64-max "
            + "transferId AND totalByteCount (the no-size-ceiling "
            + "claim as bytes — chunkCount math must not overflow), "
            + "the 131,072 B chunk ceiling, 255-byte name and MIME "
            + "hint (printable-ASCII cycle, auditable by eye).",
        kind: .roundtrip, codec: .offer,
        messageHex: Hex.string(offerMaxed.encode()),
        transferIdHex: Hex.uint64String(UInt64.max),
        totalByteCountHex: Hex.uint64String(UInt64.max),
        chunkByteCount: BulkWire.maxChunkByteCount,
        sha256Hex: Hex.string(counting(from: 0x40, count: 32)),
        nameUtf8Hex: Hex.string(
            Array(printable(BulkWire.maxNameByteCount).utf8)
        ),
        mimeUtf8Hex: Hex.string(
            Array(printable(BulkWire.maxMimeHintByteCount).utf8)
        )
    ))

    let unicodeName = "résumé — 🙂.txt"
    let offerUnicode = try BulkOffer(
        transferId: id,
        totalByteCount: 8_192,
        chunkByteCount: 4_096,
        sha256: sha,
        name: unicodeName,
        mimeHint: "text/plain"
    )
    vectors.append(BulkMessageVector(
        name: "offer-unicode-name",
        description: "2-, 3-, and 4-byte UTF-8 sequences in the name "
            + "round-trip byte-exact (é, —, 🙂).",
        kind: .roundtrip, codec: .offer,
        messageHex: Hex.string(offerUnicode.encode()),
        transferIdHex: Hex.uint64String(id),
        totalByteCountHex: Hex.uint64String(8_192),
        chunkByteCount: 4_096,
        sha256Hex: Hex.string(sha),
        nameUtf8Hex: Hex.string(Array(unicodeName.utf8)),
        mimeUtf8Hex: Hex.string(Array("text/plain".utf8))
    ))

    // MARK: accept roundtrips

    vectors.append(try creditMapVector(
        name: "accept-fresh",
        description: "A fresh transfer's accept: empty possession, "
            + "the default 16-chunk opening credit.",
        codec: .accept, transferId: id, credit: 16,
        contiguous: 0, bitmap: []
    ))
    vectors.append(try creditMapVector(
        name: "accept-resume-prefix",
        description: "The ordinary teardown resume: in-order ARQ "
            + "carriage leaves a hole-free prefix, so the map is "
            + "cumulative-only — 950 chunks held, no bitmap.",
        codec: .accept, transferId: id, credit: 16,
        contiguous: 950, bitmap: []
    ))
    vectors.append(try creditMapVector(
        name: "accept-resume-holes",
        description: "A holed resume state: chunks 0-2 plus 5 and 6 "
            + "held — bitmap 0x06 = bits 1,2 = chunks "
            + "contiguous+1+n = 5,6 (hand-checkable).",
        codec: .accept, transferId: id, credit: 4,
        contiguous: 3, bitmap: [0x06]
    ))
    vectors.append(try creditMapVector(
        name: "accept-zero-credit",
        description: "creditTotal 0 is legal: accept-but-hold — "
            + "backpressure from the first byte.",
        codec: .accept, transferId: id, credit: 0,
        contiguous: 0, bitmap: []
    ))

    // MARK: chunk roundtrips

    let chunkNominal = try BulkChunk(
        transferId: id, chunkIndex: 7,
        data: counting(from: 0x10, count: 48)
    )
    vectors.append(BulkMessageVector(
        name: "chunk-nominal",
        description: "The hand-computed anchor: chunk 7, 48 "
            + "counting bytes from 0x10.",
        kind: .roundtrip, codec: .chunk,
        messageHex: Hex.string(chunkNominal.encode()),
        transferIdHex: Hex.uint64String(id),
        chunkIndexHex: Hex.uint64String(7),
        dataHex: Hex.string(counting(from: 0x10, count: 48))
    ))
    let chunkMax = try BulkChunk(
        transferId: id, chunkIndex: 0,
        data: counting(from: 0, count: BulkWire.maxChunkByteCount)
    )
    vectors.append(BulkMessageVector(
        name: "chunk-max-budget",
        description: "Exactly 131,072 data bytes (counting pattern) "
            + "— the chunk ceiling is legal to the byte.",
        kind: .roundtrip, codec: .chunk,
        messageHex: Hex.string(chunkMax.encode()),
        transferIdHex: Hex.uint64String(id),
        chunkIndexHex: Hex.uint64String(0),
        dataHex: Hex.string(
            counting(from: 0, count: BulkWire.maxChunkByteCount)
        )
    ))
    let chunkTiny = try BulkChunk(
        transferId: id, chunkIndex: 4, data: [0x5A]
    )
    vectors.append(BulkMessageVector(
        name: "chunk-single-byte",
        description: "One data byte — the smallest legal final-chunk "
            + "remainder shape.",
        kind: .roundtrip, codec: .chunk,
        messageHex: Hex.string(chunkTiny.encode()),
        transferIdHex: Hex.uint64String(id),
        chunkIndexHex: Hex.uint64String(4),
        dataHex: "5a"
    ))

    // MARK: ack roundtrips

    vectors.append(try creditMapVector(
        name: "ack-nominal",
        description: "The steady-state heartbeat: 8 chunks held "
            + "hole-free, credit raised to 24.",
        codec: .ack, transferId: id, credit: 24,
        contiguous: 8, bitmap: []
    ))
    vectors.append(try creditMapVector(
        name: "ack-with-bitmap",
        description: "A holed report: bitmap 0x05 = bits 0,2 = "
            + "chunks 6 and 8 held past the 5-chunk prefix.",
        codec: .ack, transferId: id, credit: 12,
        contiguous: 5, bitmap: [0x05]
    ))
    vectors.append(try creditMapVector(
        name: "ack-max-bitmap",
        description: "Exactly 1,024 bitmap bytes, all 0xFF — the "
            + "bitmap ceiling is legal to the byte (8,192 chunks "
            + "described past the first hole; beyond it the map "
            + "under-claims, which is always legal).",
        codec: .ack, transferId: id, credit: 9_000,
        contiguous: 0,
        bitmap: [UInt8](
            repeating: 0xFF, count: BulkWire.maxBitmapByteCount
        )
    ))

    // MARK: complete + abort roundtrips (the whole reason space —
    // the lifecycle discipline)

    vectors.append(BulkMessageVector(
        name: "complete-nominal",
        description: "Exactly type ‖ transferId — the success "
            + "verdict, sent only after the digest matched.",
        kind: .roundtrip, codec: .complete,
        messageHex: Hex.string(
            try BulkComplete(transferId: id).encode()
        ),
        transferIdHex: Hex.uint64String(id)
    ))
    for reason in BulkAbortReason.allCases {
        vectors.append(BulkMessageVector(
            name: "abort-\(bulkAbortReasonName(reason))",
            description: "The abort reason space pinned whole: "
                + "\(bulkAbortReasonName(reason)) "
                + "(0x0\(reason.rawValue)).",
            kind: .roundtrip, codec: .abort,
            messageHex: Hex.string(
                try BulkAbort(transferId: id, reason: reason).encode()
            ),
            transferIdHex: Hex.uint64String(id),
            reason: bulkAbortReasonName(reason)
        ))
    }

    // MARK: decode rejects — offer

    let offerBytes = offerNominal.encode()
    vectors.append(reject(
        "offer-empty-payload", .offer, "",
        "truncatedMessage",
        "An empty payload rejects — no type byte to dispatch on."
    ))
    vectors.append(reject(
        "offer-bad-type", .offer,
        Hex.string([0x7F] + offerBytes.dropFirst()),
        "unexpectedType",
        "A stranger's type byte (0x7F) rejects with what it found."
    ))
    vectors.append(reject(
        "offer-truncated-header", .offer,
        Hex.string(offerBytes.prefix(53)),
        "truncatedMessage",
        "The fixed head cut one byte short of nameLen."
    ))
    vectors.append(reject(
        "offer-truncated-name", .offer,
        Hex.string(offerBytes.prefix(58)),
        "truncatedMessage",
        "nameLen promises more name bytes than the payload holds."
    ))
    vectors.append(reject(
        "offer-missing-mime-length", .offer,
        Hex.string(offerBytes.prefix(64)),
        "truncatedMessage",
        "The payload ends exactly where mimeLen must sit."
    ))
    vectors.append(reject(
        "offer-truncated-mime", .offer,
        Hex.string(offerBytes.dropLast(1)),
        "truncatedMessage",
        "mimeLen promises more MIME bytes than the payload holds."
    ))
    vectors.append(reject(
        "offer-trailing-byte", .offer,
        Hex.string(offerBytes + [0x00]),
        "trailingBytes",
        "The message is exactly its layout — one extra byte rejects."
    ))
    vectors.append(reject(
        "offer-zero-transfer-id", .offer,
        Hex.string(mutating(offerBytes) {
            for i in 1...8 { $0[i] = 0 }
        }),
        "zeroTransferId",
        "transferId 0 is always some layer's zero-fill bug."
    ))
    vectors.append(reject(
        "offer-zero-total", .offer,
        Hex.string(mutating(offerBytes) {
            for i in 9...16 { $0[i] = 0 }
        }),
        "emptyTransfer",
        "totalByteCount 0 rejects — v1 does not transfer empty blobs."
    ))
    vectors.append(reject(
        "offer-chunk-below-floor", .offer,
        Hex.string(mutating(offerBytes) {
            // 4,095 = 0x0FFF LE
            $0[17] = 0xFF; $0[18] = 0x0F; $0[19] = 0; $0[20] = 0
        }),
        "chunkSizeOutOfBounds",
        "chunkByteCount 4,095 — one below the floor."
    ))
    vectors.append(reject(
        "offer-chunk-above-ceiling", .offer,
        Hex.string(mutating(offerBytes) {
            // 131,073 = 0x020001 LE
            $0[17] = 0x01; $0[18] = 0x00; $0[19] = 0x02; $0[20] = 0
        }),
        "chunkSizeOutOfBounds",
        "chunkByteCount 131,073 — one above the ceiling."
    ))
    vectors.append(reject(
        "offer-empty-name", .offer,
        Hex.string(
            Array(offerBytes.prefix(53)) + [0x00, 0x00]
        ),
        "emptyName",
        "nameLen 0 rejects — a nameless offer is unreviewable by a "
            + "consent UI."
    ))
    vectors.append(reject(
        "offer-invalid-utf8-name", .offer,
        Hex.string(
            Array(offerBytes.prefix(53)) + [0x02, 0x68, 0xFF, 0x00]
        ),
        "invalidUtf8",
        "0xFF is never valid UTF-8 — the name rejects, never "
            + "replaces."
    ))
    vectors.append(reject(
        "offer-invalid-utf8-mime", .offer,
        Hex.string(
            Array(offerBytes.prefix(53)) + [0x01, 0x61, 0x01, 0xC3]
        ),
        "invalidUtf8",
        "A 2-byte UTF-8 lead with no continuation in the MIME hint "
            + "rejects."
    ))

    // MARK: decode rejects — accept / ack (the shared layout, both
    // codecs pinned)

    let acceptBytes = try BulkAccept(
        transferId: id, creditTotal: 16,
        possession: BulkChunkMap(contiguousCount: 3, bitmap: [0x06])
    ).encode()
    vectors.append(reject(
        "accept-truncated-header", .accept,
        Hex.string(acceptBytes.prefix(26)),
        "truncatedMessage",
        "The fixed head cut one byte short of bitmapLen."
    ))
    vectors.append(reject(
        "accept-truncated-bitmap", .accept,
        Hex.string(acceptBytes.dropLast(1)),
        "truncatedMessage",
        "bitmapLen promises more bitmap bytes than the payload holds."
    ))
    vectors.append(reject(
        "accept-trailing-byte", .accept,
        Hex.string(acceptBytes + [0x00]),
        "trailingBytes",
        "One byte past the bitmap rejects."
    ))
    vectors.append(reject(
        "accept-bitmap-over-budget", .accept,
        Hex.string(creditMapRaw(
            type: CtrlMessageType.bulkAccept, transferId: id,
            credit: 16, contiguous: 0, bitmapLen: 1_025,
            bitmap: [UInt8](repeating: 0xFF, count: 1_025)
        )),
        "bitmapOverBudget",
        "1,025 bitmap bytes — one over the ceiling — reject on the "
            + "length field."
    ))
    vectors.append(reject(
        "accept-noncanonical-bitmap", .accept,
        Hex.string(creditMapRaw(
            type: CtrlMessageType.bulkAccept, transferId: id,
            credit: 16, contiguous: 0, bitmapLen: 2,
            bitmap: [0x01, 0x00]
        )),
        "nonCanonicalBitmap",
        "A zero final bitmap byte means the sender miscounted — the "
            + "bitmap is sized by its highest set bit."
    ))
    vectors.append(reject(
        "accept-zero-transfer-id", .accept,
        Hex.string(mutating(acceptBytes) {
            for i in 1...8 { $0[i] = 0 }
        }),
        "zeroTransferId",
        "transferId 0 rejects on the shared layout too."
    ))
    vectors.append(reject(
        "accept-bad-type", .accept,
        Hex.string(mutating(acceptBytes) {
            $0[0] = CtrlMessageType.bulkAck
        }),
        "unexpectedType",
        "An ack fed to the accept decoder rejects — same bytes, "
            + "different meaning, never cross-decoded."
    ))
    let ackBytes = try BulkAck(
        transferId: id, creditTotal: 24,
        possession: BulkChunkMap(contiguousCount: 8)
    ).encode()
    vectors.append(reject(
        "ack-truncated-header", .ack,
        Hex.string(ackBytes.prefix(20)),
        "truncatedMessage",
        "A truncated ack head rejects."
    ))
    vectors.append(reject(
        "ack-trailing-byte", .ack,
        Hex.string(ackBytes + [0xAA]),
        "trailingBytes",
        "One byte past an empty bitmap rejects."
    ))
    vectors.append(reject(
        "ack-noncanonical-bitmap", .ack,
        Hex.string(creditMapRaw(
            type: CtrlMessageType.bulkAck, transferId: id,
            credit: 24, contiguous: 8, bitmapLen: 1, bitmap: [0x00]
        )),
        "nonCanonicalBitmap",
        "The canonicality rule holds for acks identically."
    ))

    // MARK: decode rejects — chunk

    vectors.append(reject(
        "chunk-truncated-header", .chunk,
        Hex.string(chunkNominal.encode().prefix(16)),
        "truncatedMessage",
        "A chunk header cut mid-index rejects."
    ))
    vectors.append(reject(
        "chunk-empty-data", .chunk,
        Hex.string(chunkNominal.encode().prefix(17)),
        "emptyChunkData",
        "A chunk with no data is some layer's fill bug, kept loud."
    ))
    vectors.append(reject(
        "chunk-over-budget", .chunk,
        Hex.string(
            Array(chunkNominal.encode().prefix(17))
                + counting(from: 0, count: BulkWire.maxChunkByteCount + 1)
        ),
        "chunkDataOverBudget",
        "131,073 data bytes — one over the chunk ceiling."
    ))
    vectors.append(reject(
        "chunk-zero-transfer-id", .chunk,
        Hex.string(mutating(chunkNominal.encode()) {
            for i in 1...8 { $0[i] = 0 }
        }),
        "zeroTransferId",
        "transferId 0 rejects on chunks too."
    ))
    vectors.append(reject(
        "chunk-bad-type", .chunk,
        Hex.string(mutating(chunkNominal.encode()) { $0[0] = 0x7F }),
        "unexpectedType",
        "A foreign type byte rejects."
    ))

    // MARK: decode rejects — complete / abort

    let completeBytes = try BulkComplete(transferId: id).encode()
    vectors.append(reject(
        "complete-truncated", .complete,
        Hex.string(completeBytes.prefix(8)),
        "truncatedMessage",
        "A complete cut mid-id rejects."
    ))
    vectors.append(reject(
        "complete-trailing-byte", .complete,
        Hex.string(completeBytes + [0x00]),
        "trailingBytes",
        "Complete is exactly 9 bytes."
    ))
    vectors.append(reject(
        "complete-zero-transfer-id", .complete,
        Hex.string(mutating(completeBytes) {
            for i in 1...8 { $0[i] = 0 }
        }),
        "zeroTransferId",
        "transferId 0 rejects."
    ))
    vectors.append(reject(
        "complete-bad-type", .complete,
        Hex.string(mutating(completeBytes) { $0[0] = 0x21 }),
        "unexpectedType",
        "An abort's type byte at the complete decoder rejects."
    ))
    let abortBytes = try BulkAbort(
        transferId: id, reason: .cancelled
    ).encode()
    vectors.append(reject(
        "abort-truncated", .abort,
        Hex.string(abortBytes.prefix(9)),
        "truncatedMessage",
        "An abort cut before its reason rejects."
    ))
    vectors.append(reject(
        "abort-trailing-byte", .abort,
        Hex.string(abortBytes + [0x00]),
        "trailingBytes",
        "Abort is exactly 10 bytes."
    ))
    vectors.append(reject(
        "abort-zero-reason", .abort,
        Hex.string(mutating(abortBytes) { $0[9] = 0x00 }),
        "unknownAbortReason",
        "Reason 0x00 is the loud zero-fill bug."
    ))
    vectors.append(reject(
        "abort-unknown-reason", .abort,
        Hex.string(mutating(abortBytes) { $0[9] = 0x7F }),
        "unknownAbortReason",
        "Reason 0x7F is outside the pinned space."
    ))
    vectors.append(reject(
        "abort-bad-type", .abort,
        Hex.string(mutating(abortBytes) { $0[0] = 0x20 }),
        "unexpectedType",
        "A complete's type byte at the abort decoder rejects."
    ))

    // MARK: encode rejects — the bounds only the u8 wire widths make
    // inexpressible as decode bytes

    vectors.append(BulkMessageVector(
        name: "offer-name-over-budget",
        description: "A 256-byte name cannot construct — the u8 "
            + "length field is the wire bound, the init is the "
            + "codec-side gate.",
        kind: .encodeReject, codec: .offer,
        transferIdHex: Hex.uint64String(id),
        totalByteCountHex: Hex.uint64String(300_000),
        chunkByteCount: 65_536,
        sha256Hex: Hex.string(sha),
        nameUtf8Hex: Hex.string(
            [UInt8](repeating: 0x61, count: BulkWire.maxNameByteCount + 1)
        ),
        mimeUtf8Hex: "",
        error: "nameOverBudget"
    ))
    vectors.append(BulkMessageVector(
        name: "offer-mime-over-budget",
        description: "A 256-byte MIME hint cannot construct.",
        kind: .encodeReject, codec: .offer,
        transferIdHex: Hex.uint64String(id),
        totalByteCountHex: Hex.uint64String(300_000),
        chunkByteCount: 65_536,
        sha256Hex: Hex.string(sha),
        nameUtf8Hex: Hex.string(Array("a".utf8)),
        mimeUtf8Hex: Hex.string(
            [UInt8](repeating: 0x61,
                    count: BulkWire.maxMimeHintByteCount + 1)
        ),
        error: "mimeHintOverBudget"
    ))
    vectors.append(BulkMessageVector(
        name: "offer-sha-wrong-width",
        description: "A 31-byte digest cannot construct — the wire "
            + "layout fixes 32.",
        kind: .encodeReject, codec: .offer,
        transferIdHex: Hex.uint64String(id),
        totalByteCountHex: Hex.uint64String(300_000),
        chunkByteCount: 65_536,
        sha256Hex: Hex.string(counting(from: 0, count: 31)),
        nameUtf8Hex: Hex.string(Array("a".utf8)),
        mimeUtf8Hex: "",
        error: "invalidSha256ByteCount"
    ))

    return vectors
}

private func creditMapVector(
    name: String, description: String,
    codec: BulkMessageVector.BulkCodec,
    transferId: UInt64, credit: UInt64,
    contiguous: UInt64, bitmap: [UInt8]
) throws -> BulkMessageVector {
    let map = try BulkChunkMap(
        contiguousCount: contiguous, bitmap: bitmap
    )
    let messageHex: String
    switch codec {
    case .accept:
        messageHex = Hex.string(try BulkAccept(
            transferId: transferId, creditTotal: credit, possession: map
        ).encode())
    case .ack:
        messageHex = Hex.string(try BulkAck(
            transferId: transferId, creditTotal: credit, possession: map
        ).encode())
    default:
        fatalError("creditMapVector is for accept/ack only")
    }
    return BulkMessageVector(
        name: name, description: description,
        kind: .roundtrip, codec: codec,
        messageHex: messageHex,
        transferIdHex: Hex.uint64String(transferId),
        creditTotalHex: Hex.uint64String(credit),
        contiguousCountHex: Hex.uint64String(contiguous),
        bitmapHex: Hex.string(bitmap)
    )
}

/// Raw accept/ack bytes for reject shapes the typed codec refuses to
/// build.
private func creditMapRaw(
    type: UInt8, transferId: UInt64, credit: UInt64,
    contiguous: UInt64, bitmapLen: UInt16, bitmap: [UInt8]
) -> [UInt8] {
    var out: [UInt8] = [type]
    appendLE64(transferId, &out)
    appendLE64(credit, &out)
    appendLE64(contiguous, &out)
    out.append(UInt8(truncatingIfNeeded: bitmapLen))
    out.append(UInt8(truncatingIfNeeded: bitmapLen >> 8))
    out.append(contentsOf: bitmap)
    return out
}

private func appendLE64(_ value: UInt64, _ out: inout [UInt8]) {
    for shift in stride(from: 0, to: 64, by: 8) {
        out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
}

private func mutating(
    _ bytes: [UInt8], _ mutate: (inout [UInt8]) -> Void
) -> [UInt8] {
    var copy = bytes
    mutate(&copy)
    return copy
}

private func reject(
    _ name: String, _ codec: BulkMessageVector.BulkCodec,
    _ messageHex: String, _ error: String, _ description: String
) -> BulkMessageVector {
    BulkMessageVector(
        name: name, description: description,
        kind: .decodeReject, codec: codec,
        messageHex: messageHex, error: error
    )
}

// MARK: - Capability vectors (the key-11 spine — the key-9/key-10
// precedent, third verse)

private func makeBulkCapabilityVectors() throws -> [BulkCapabilityVector] {
    [
        BulkCapabilityVector(
            name: "capability-key11-declared",
            description: "wireDefault's frozen encoding plus exactly "
                + "the appended `0B F5` entry (map head 0xA8 → 0xA9): "
                + "the bulkTransfer accessor must read true and the "
                + "set must re-encode byte-exactly — the \"no frozen "
                + "bytes moved\" claim as data.",
            messageHex: Hex.string(
                try Capabilities.wireDefault.declaringBulkTransfer()
                    .encodeCbor()
            ),
            bulkTransfer: true
        ),
        BulkCapabilityVector(
            name: "capability-key11-absent",
            description: "wireDefault's frozen encoding unchanged: "
                + "absence reads false — \"not supported\", never an "
                + "error.",
            messageHex: Hex.string(
                try Capabilities.wireDefault.encodeCbor()
            ),
            bulkTransfer: false
        ),
        BulkCapabilityVector(
            name: "capability-keys-9-10-11",
            description: "All three spine keys together: map head "
                + "0xAB with `09 F5 0A F5 0B F5` trailing in "
                + "canonical order — the features compose without "
                + "moving each other's bytes.",
            messageHex: Hex.string(
                try Capabilities.wireDefault
                    .declaringHostAudioRouting()
                    .declaringClipboardText()
                    .declaringBulkTransfer()
                    .encodeCbor()
            ),
            bulkTransfer: true
        ),
    ]
}

// MARK: - Transfer vectors (worked multi-session traces, pinned
// self-consistent through the shared TestKit harness)

private func makeBulkTransferVectors() throws -> [BulkTransferVector] {
    var vectors: [BulkTransferVector] = []

    // (a) The teardown-resume story: 5 chunks, window 2, session 1
    // dies after the receiver has ingested offer + chunks 0-2, then
    // session 2 resumes from the hole-free prefix and completes.
    do {
        let total = 20_000
        let payload = counting(from: 0, count: total)
        let offer = try BulkOffer(
            transferId: 0xB01D_FACE_0000_0001,
            totalByteCount: UInt64(total),
            chunkByteCount: 4_096,
            sha256: Sha256.digest(payload),
            name: "resume-demo.bin",
            mimeHint: "application/octet-stream"
        )
        var harness = BulkTransferHarness(
            offer: offer, payload: payload, window: 2
        )
        let first = try harness.runSession(receiverIngestLimit: 4)
        let second = try harness.runSession()
        vectors.append(BulkTransferVector(
            name: "two-session-resume",
            description: "20,000 B over 4,096 B chunks (5 chunks, "
                + "final 3,616 B), window 2. Session 1: the receiver "
                + "ingests only offer + chunks 0-2 (the teardown "
                + "prefix — in-order carriage means a blackout IS a "
                + "prefix), leaving a 3-chunk hole-free possession. "
                + "Session 2: the identical re-offer matches the "
                + "resume book, the accept carries "
                + "contiguousCount 3, only chunks 3-4 travel, and "
                + "the digest verdict completes — sha-exact resume, "
                + "J-G3's bar as bytes.",
            provenance: "pinned-self-consistent",
            transferIdHex: Hex.uint64String(offer.transferId),
            totalByteCount: total,
            chunkByteCount: 4_096,
            payloadStart: 0,
            sha256Hex: Hex.string(offer.sha256),
            fileName: offer.name,
            mimeHint: offer.mimeHint,
            receiveWindowChunks: 2,
            sessions: [
                BulkTransferSessionVector(
                    receiverIngestLimit: 4,
                    senderMessagesHex: first.senderMessages.map(Hex.string),
                    receiverMessagesHex: first.receiverMessages.map(Hex.string)
                ),
                BulkTransferSessionVector(
                    senderMessagesHex: second.senderMessages.map(Hex.string),
                    receiverMessagesHex: second.receiverMessages.map(Hex.string)
                ),
            ]
        ))
    }

    // (b) The holed-map story: a persisted possession with gaps
    // (chunks 0-2, 5, 6 of 8) — the shape a live prefix teardown
    // cannot produce but a storage audit can. One session fills
    // exactly the holes and completes.
    do {
        let total = 30_000
        let payload = counting(from: 0x30, count: total)
        let offer = try BulkOffer(
            transferId: 0xB01D_FACE_0000_0002,
            totalByteCount: UInt64(total),
            chunkByteCount: 4_096,
            sha256: Sha256.digest(payload),
            name: "holes-demo.bin",
            mimeHint: ""
        )
        let possession = BulkPossession(
            contiguousCount: 3, extras: [5, 6]
        )
        var harness = BulkTransferHarness(
            offer: offer, payload: payload, window: 4,
            initialPossession: possession
        )
        let only = try harness.runSession()
        vectors.append(BulkTransferVector(
            name: "resume-with-holes",
            description: "30,000 B over 4,096 B chunks (8 chunks, "
                + "final 1,328 B), window 4, resuming from a HOLED "
                + "possession: chunks 0-2 plus 5-6 held. The accept's "
                + "map is contiguousCount 3 + bitmap 0x06 (bits 1,2 = "
                + "chunks 5,6 — hand-checkable); the sender "
                + "dispatches exactly the holes (3, 4, 7); storing "
                + "chunk 4 snaps the prefix across the old extras "
                + "(3→7); the digest verdict completes.",
            provenance: "pinned-self-consistent",
            transferIdHex: Hex.uint64String(offer.transferId),
            totalByteCount: total,
            chunkByteCount: 4_096,
            payloadStart: 0x30,
            sha256Hex: Hex.string(offer.sha256),
            fileName: offer.name,
            mimeHint: offer.mimeHint,
            receiveWindowChunks: 4,
            initialPossession: BulkPossessionSpec(
                contiguousCount: 3, extraChunkIndices: [5, 6]
            ),
            sessions: [
                BulkTransferSessionVector(
                    senderMessagesHex: only.senderMessages.map(Hex.string),
                    receiverMessagesHex: only.receiverMessages.map(Hex.string)
                ),
            ]
        ))
    }

    return vectors
}
