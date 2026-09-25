// Authors Vectors/bulk-v1.json: the transfer messages 0x1C–0x21, the
// key-11 capability spine, and worked multi-session transfer traces.
// Messages are anchored by BulkCodecTests' hand-computed bytes; the
// traces are self-consistent pins replayed through the TestKit harness.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeBulkVectorFile() throws -> BulkVectorFile {
    BulkVectorFile(
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

    /// An offer's fields as vector data; nil `messageHex` for the
    /// encode rejects, whose fields never construct.
    func offerVector(
        _ name: String, _ description: String, kind: BulkMessageVector.Kind,
        messageHex: String?, transferId: UInt64, total: UInt64, chunk: Int,
        sha256: [UInt8], fileName: [UInt8], mime: [UInt8], error: String? = nil
    ) -> BulkMessageVector {
        BulkMessageVector(
            name: name, description: description, kind: kind, codec: .offer,
            messageHex: messageHex,
            transferIdHex: Hex.uint64String(transferId),
            totalByteCountHex: Hex.uint64String(total),
            chunkByteCount: chunk,
            sha256Hex: Hex.string(sha256),
            nameUtf8Hex: Hex.string(fileName),
            mimeUtf8Hex: Hex.string(mime),
            error: error
        )
    }

    // MARK: offer roundtrips

    let unicodeName = "résumé — 🙂.txt"
    let offers: [(String, String, BulkOffer)] = [
        ("offer-nominal",
         "The hand-computed anchor: 300,000 B under the default 64 KiB chunk "
            + "(5 chunks, final 37,856 B), counting-byte sha from 0xA0.",
         try BulkOffer(
            transferId: id, totalByteCount: 300_000, chunkByteCount: 65_536,
            sha256: sha, name: "report.pdf", mimeHint: "application/pdf"
         )),
        ("offer-minimum-shape",
         "The smallest legal offer: 1-byte blob, the 4,096 B chunk floor, "
            + "1-byte name, empty MIME hint.",
         try BulkOffer(
            transferId: 1, totalByteCount: 1,
            chunkByteCount: UInt32(BulkWire.minChunkByteCount),
            sha256: counting(from: 0, count: 32), name: "a", mimeHint: ""
         )),
        ("offer-maxed-fields",
         "Every bound at its edge and legal: u64-max transferId AND "
            + "totalByteCount (the no-size-ceiling claim as bytes — "
            + "chunkCount math must not overflow), the 131,072 B chunk "
            + "ceiling, 255-byte name and MIME hint (printable-ASCII cycle, "
            + "auditable by eye).",
         try BulkOffer(
            transferId: .max, totalByteCount: .max,
            chunkByteCount: UInt32(BulkWire.maxChunkByteCount),
            sha256: counting(from: 0x40, count: 32),
            name: printableASCII(count: BulkWire.maxNameByteCount),
            mimeHint: printableASCII(count: BulkWire.maxMimeHintByteCount)
         )),
        ("offer-unicode-name",
         "2-, 3-, and 4-byte UTF-8 sequences in the name round-trip "
            + "byte-exact (é, —, 🙂).",
         try BulkOffer(
            transferId: id, totalByteCount: 8_192, chunkByteCount: 4_096,
            sha256: sha, name: unicodeName, mimeHint: "text/plain"
         )),
    ]
    for (name, description, offer) in offers {
        vectors.append(offerVector(
            name, description, kind: .roundtrip,
            messageHex: Hex.string(offer.encode()),
            transferId: offer.transferId, total: offer.totalByteCount,
            chunk: Int(offer.chunkByteCount), sha256: offer.sha256,
            fileName: Array(offer.name.utf8), mime: Array(offer.mimeHint.utf8)
        ))
    }

    // MARK: accept roundtrips

    for (name, description, credit, contiguous, bitmap) in [
        ("accept-fresh",
         "A fresh transfer's accept: empty possession, the default 16-chunk "
            + "opening credit.",
         16, 0, []),
        ("accept-resume-prefix",
         "The ordinary teardown resume: in-order ARQ carriage leaves a "
            + "hole-free prefix, so the map is cumulative-only — 950 chunks "
            + "held, no bitmap.",
         16, 950, []),
        ("accept-resume-holes",
         "A holed resume state: chunks 0-2 plus 5 and 6 held — bitmap 0x06 = "
            + "bits 1,2 = chunks contiguous+1+n = 5,6 (hand-checkable).",
         4, 3, [0x06]),
        ("accept-zero-credit",
         "creditTotal 0 is legal: accept-but-hold — backpressure from the "
            + "first byte.",
         0, 0, []),
    ] as [(String, String, UInt64, UInt64, [UInt8])] {
        vectors.append(try creditMapVector(
            name: name, description: description, codec: .accept,
            transferId: id, credit: credit, contiguous: contiguous,
            bitmap: bitmap
        ))
    }

    // MARK: chunk roundtrips

    let chunkNominal = try BulkChunk(
        transferId: id, chunkIndex: 7, data: counting(from: 0x10, count: 48)
    )
    for (name, description, chunk) in [
        ("chunk-nominal",
         "The hand-computed anchor: chunk 7, 48 counting bytes from 0x10.",
         chunkNominal),
        ("chunk-max-budget",
         "Exactly 131,072 data bytes (counting pattern) — the chunk ceiling "
            + "is legal to the byte.",
         try BulkChunk(
            transferId: id, chunkIndex: 0,
            data: counting(from: 0, count: BulkWire.maxChunkByteCount)
         )),
        ("chunk-single-byte",
         "One data byte — the smallest legal final-chunk remainder shape.",
         try BulkChunk(transferId: id, chunkIndex: 4, data: [0x5A])),
    ] {
        vectors.append(BulkMessageVector(
            name: name, description: description,
            kind: .roundtrip, codec: .chunk,
            messageHex: Hex.string(chunk.encode()),
            transferIdHex: Hex.uint64String(chunk.transferId),
            chunkIndexHex: Hex.uint64String(chunk.chunkIndex),
            dataHex: Hex.string(chunk.data)
        ))
    }

    // MARK: ack roundtrips

    for (name, description, credit, contiguous, bitmap) in [
        ("ack-nominal",
         "The steady-state heartbeat: 8 chunks held hole-free, credit raised "
            + "to 24.",
         24, 8, []),
        ("ack-with-bitmap",
         "A holed report: bitmap 0x05 = bits 0,2 = chunks 6 and 8 held past "
            + "the 5-chunk prefix.",
         12, 5, [0x05]),
        ("ack-max-bitmap",
         "Exactly 1,024 bitmap bytes, all 0xFF — the bitmap ceiling is legal "
            + "to the byte (8,192 chunks described past the first hole; "
            + "beyond it the map under-claims, which is always legal).",
         9_000, 0,
         [UInt8](repeating: 0xFF, count: BulkWire.maxBitmapByteCount)),
    ] as [(String, String, UInt64, UInt64, [UInt8])] {
        vectors.append(try creditMapVector(
            name: name, description: description, codec: .ack,
            transferId: id, credit: credit, contiguous: contiguous,
            bitmap: bitmap
        ))
    }

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
    for reason in [
        BulkAbortReason.declined, .cancelled, .resumeMismatch, .shaMismatch,
        .storageFailure, .busy, .protocolViolation,
    ] {
        vectors.append(BulkMessageVector(
            name: "abort-\(bulkAbortReasonName(reason))",
            description: "The abort reason space pinned whole: "
                + "\(bulkAbortReasonName(reason)) "
                + "(0x\(Hex.string([reason.rawValue]))).",
            kind: .roundtrip, codec: .abort,
            messageHex: Hex.string(
                try BulkAbort(transferId: id, reason: reason).encode()
            ),
            transferIdHex: Hex.uint64String(id),
            reason: bulkAbortReasonName(reason)
        ))
    }

    // MARK: decode rejects

    let offerBytes = offers[0].2.encode()
    let offerHead = Array(offerBytes.prefix(53))
    let acceptBytes = try BulkAccept(
        transferId: id, creditTotal: 16,
        possession: BulkChunkMap(contiguousCount: 3, bitmap: [0x06])
    ).encode()
    let ackBytes = try BulkAck(
        transferId: id, creditTotal: 24,
        possession: BulkChunkMap(contiguousCount: 8)
    ).encode()
    let chunkBytes = chunkNominal.encode()
    let completeBytes = try BulkComplete(transferId: id).encode()
    let abortBytes = try BulkAbort(transferId: id, reason: .cancelled).encode()
    /// The message with its transferId (bytes 1…8) zeroed.
    func zeroId(_ bytes: [UInt8]) -> [UInt8] {
        mutating(bytes) { for i in 1...8 { $0[i] = 0 } }
    }

    let rejects: [(String, BulkMessageVector.BulkCodec, [UInt8], String, String)] = [
        ("offer-empty-payload", .offer, [], "truncatedMessage",
         "An empty payload rejects — no type byte to dispatch on."),
        ("offer-bad-type", .offer, [0x7F] + offerBytes.dropFirst(),
         "unexpectedType",
         "A stranger's type byte (0x7F) rejects with what it found."),
        ("offer-truncated-header", .offer, offerHead, "truncatedMessage",
         "The fixed head cut one byte short of nameLen."),
        ("offer-truncated-name", .offer, Array(offerBytes.prefix(58)),
         "truncatedMessage",
         "nameLen promises more name bytes than the payload holds."),
        ("offer-missing-mime-length", .offer, Array(offerBytes.prefix(64)),
         "truncatedMessage", "The payload ends exactly where mimeLen must sit."),
        ("offer-truncated-mime", .offer, Array(offerBytes.dropLast(1)),
         "truncatedMessage",
         "mimeLen promises more MIME bytes than the payload holds."),
        ("offer-trailing-byte", .offer, offerBytes + [0x00], "trailingBytes",
         "The message is exactly its layout — one extra byte rejects."),
        ("offer-zero-transfer-id", .offer, zeroId(offerBytes), "zeroTransferId",
         "transferId 0 is always some layer's zero-fill bug."),
        ("offer-zero-total", .offer,
         mutating(offerBytes) { for i in 9...16 { $0[i] = 0 } },
         "emptyTransfer",
         "totalByteCount 0 rejects — v1 does not transfer empty blobs."),
        ("offer-chunk-below-floor", .offer,
         mutating(offerBytes) { $0.replaceSubrange(17...20, with: [0xFF, 0x0F, 0, 0]) },
         "chunkSizeOutOfBounds", "chunkByteCount 4,095 — one below the floor."),
        ("offer-chunk-above-ceiling", .offer,
         mutating(offerBytes) { $0.replaceSubrange(17...20, with: [0x01, 0x00, 0x02, 0]) },
         "chunkSizeOutOfBounds",
         "chunkByteCount 131,073 — one above the ceiling."),
        ("offer-empty-name", .offer, offerHead + [0x00, 0x00], "emptyName",
         "nameLen 0 rejects — a nameless offer is unreviewable by a consent UI."),
        ("offer-invalid-utf8-name", .offer, offerHead + [0x02, 0x68, 0xFF, 0x00],
         "invalidUtf8",
         "0xFF is never valid UTF-8 — the name rejects, never replaces."),
        ("offer-invalid-utf8-mime", .offer, offerHead + [0x01, 0x61, 0x01, 0xC3],
         "invalidUtf8",
         "A 2-byte UTF-8 lead with no continuation in the MIME hint rejects."),

        // accept / ack: the shared layout, both codecs pinned
        ("accept-truncated-header", .accept, Array(acceptBytes.prefix(26)),
         "truncatedMessage", "The fixed head cut one byte short of bitmapLen."),
        ("accept-truncated-bitmap", .accept, Array(acceptBytes.dropLast(1)),
         "truncatedMessage",
         "bitmapLen promises more bitmap bytes than the payload holds."),
        ("accept-trailing-byte", .accept, acceptBytes + [0x00], "trailingBytes",
         "One byte past the bitmap rejects."),
        ("accept-bitmap-over-budget", .accept,
         creditMapRaw(
            type: CtrlMessageType.bulkAccept, transferId: id, credit: 16,
            contiguous: 0, bitmapLen: 1_025,
            bitmap: [UInt8](repeating: 0xFF, count: 1_025)
         ),
         "bitmapOverBudget",
         "1,025 bitmap bytes — one over the ceiling — reject on the length "
            + "field."),
        ("accept-noncanonical-bitmap", .accept,
         creditMapRaw(
            type: CtrlMessageType.bulkAccept, transferId: id, credit: 16,
            contiguous: 0, bitmapLen: 2, bitmap: [0x01, 0x00]
         ),
         "nonCanonicalBitmap",
         "A zero final bitmap byte means the sender miscounted — the bitmap "
            + "is sized by its highest set bit."),
        ("accept-zero-transfer-id", .accept, zeroId(acceptBytes),
         "zeroTransferId", "transferId 0 rejects on the shared layout too."),
        ("accept-bad-type", .accept,
         mutating(acceptBytes) { $0[0] = CtrlMessageType.bulkAck },
         "unexpectedType",
         "An ack fed to the accept decoder rejects — same bytes, different "
            + "meaning, never cross-decoded."),
        ("ack-truncated-header", .ack, Array(ackBytes.prefix(20)),
         "truncatedMessage", "A truncated ack head rejects."),
        ("ack-trailing-byte", .ack, ackBytes + [0xAA], "trailingBytes",
         "One byte past an empty bitmap rejects."),
        ("ack-noncanonical-bitmap", .ack,
         creditMapRaw(
            type: CtrlMessageType.bulkAck, transferId: id, credit: 24,
            contiguous: 8, bitmapLen: 1, bitmap: [0x00]
         ),
         "nonCanonicalBitmap",
         "The canonicality rule holds for acks identically."),

        // chunk
        ("chunk-truncated-header", .chunk, Array(chunkBytes.prefix(16)),
         "truncatedMessage", "A chunk header cut mid-index rejects."),
        ("chunk-empty-data", .chunk, Array(chunkBytes.prefix(17)),
         "emptyChunkData",
         "A chunk with no data is some layer's fill bug, kept loud."),
        ("chunk-over-budget", .chunk,
         Array(chunkBytes.prefix(17))
            + counting(from: 0, count: BulkWire.maxChunkByteCount + 1),
         "chunkDataOverBudget",
         "131,073 data bytes — one over the chunk ceiling."),
        ("chunk-zero-transfer-id", .chunk, zeroId(chunkBytes), "zeroTransferId",
         "transferId 0 rejects on chunks too."),
        ("chunk-bad-type", .chunk, mutating(chunkBytes) { $0[0] = 0x7F },
         "unexpectedType", "A foreign type byte rejects."),

        // complete / abort
        ("complete-truncated", .complete, Array(completeBytes.prefix(8)),
         "truncatedMessage", "A complete cut mid-id rejects."),
        ("complete-trailing-byte", .complete, completeBytes + [0x00],
         "trailingBytes", "Complete is exactly 9 bytes."),
        ("complete-zero-transfer-id", .complete, zeroId(completeBytes),
         "zeroTransferId", "transferId 0 rejects."),
        ("complete-bad-type", .complete, mutating(completeBytes) { $0[0] = 0x21 },
         "unexpectedType",
         "An abort's type byte at the complete decoder rejects."),
        ("abort-truncated", .abort, Array(abortBytes.prefix(9)),
         "truncatedMessage", "An abort cut before its reason rejects."),
        ("abort-trailing-byte", .abort, abortBytes + [0x00], "trailingBytes",
         "Abort is exactly 10 bytes."),
        ("abort-zero-reason", .abort, mutating(abortBytes) { $0[9] = 0x00 },
         "unknownAbortReason", "Reason 0x00 is the loud zero-fill bug."),
        ("abort-unknown-reason", .abort, mutating(abortBytes) { $0[9] = 0x7F },
         "unknownAbortReason", "Reason 0x7F is outside the pinned space."),
        ("abort-bad-type", .abort, mutating(abortBytes) { $0[0] = 0x20 },
         "unexpectedType",
         "A complete's type byte at the abort decoder rejects."),
    ]
    for (name, codec, bytes, error, description) in rejects {
        vectors.append(BulkMessageVector(
            name: name, description: description,
            kind: .decodeReject, codec: codec,
            messageHex: Hex.string(bytes), error: error
        ))
    }

    // MARK: encode rejects — the bounds only the u8 wire widths make
    // inexpressible as decode bytes

    for (name, description, sha256, fileName, mime, error) in [
        ("offer-name-over-budget",
         "A 256-byte name cannot construct — the u8 length field is the wire "
            + "bound, the init is the codec-side gate.",
         sha, [UInt8](repeating: 0x61, count: BulkWire.maxNameByteCount + 1),
         [], "nameOverBudget"),
        ("offer-mime-over-budget", "A 256-byte MIME hint cannot construct.",
         sha, Array("a".utf8),
         [UInt8](repeating: 0x61, count: BulkWire.maxMimeHintByteCount + 1),
         "mimeHintOverBudget"),
        ("offer-sha-wrong-width",
         "A 31-byte digest cannot construct — the wire layout fixes 32.",
         counting(from: 0, count: 31), Array("a".utf8), [],
         "invalidSha256ByteCount"),
    ] as [(String, String, [UInt8], [UInt8], [UInt8], String)] {
        vectors.append(offerVector(
            name, description, kind: .encodeReject, messageHex: nil,
            transferId: id, total: 300_000, chunk: 65_536, sha256: sha256,
            fileName: fileName, mime: mime, error: error
        ))
    }

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
    let message = codec == .accept
        ? try BulkAccept(
            transferId: transferId, creditTotal: credit, possession: map
        ).encode()
        : try BulkAck(
            transferId: transferId, creditTotal: credit, possession: map
        ).encode()
    return BulkMessageVector(
        name: name, description: description,
        kind: .roundtrip, codec: codec,
        messageHex: Hex.string(message),
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
    for value in [transferId, credit, contiguous] {
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
    out.append(UInt8(truncatingIfNeeded: bitmapLen))
    out.append(UInt8(truncatingIfNeeded: bitmapLen >> 8))
    out.append(contentsOf: bitmap)
    return out
}

private func mutating(
    _ bytes: [UInt8], _ mutate: (inout [UInt8]) -> Void
) -> [UInt8] {
    var copy = bytes
    mutate(&copy)
    return copy
}

// MARK: - Capability vectors (the key-11 spine)

private func makeBulkCapabilityVectors() throws -> [BulkCapabilityVector] {
    try [
        ("capability-key11-declared",
         "wireDefault's frozen encoding plus exactly the appended `0B F5` "
            + "entry (map head 0xA8 → 0xA9): the bulkTransfer accessor must "
            + "read true and the set must re-encode byte-exactly — the \"no "
            + "frozen bytes moved\" claim as data.",
         Capabilities.wireDefault.declaringBulkTransfer()),
        ("capability-key11-absent",
         "wireDefault's frozen encoding unchanged: absence reads false — "
            + "\"not supported\", never an error.",
         Capabilities.wireDefault),
        ("capability-keys-9-10-11",
         "All three spine keys together: map head 0xAB with `09 F5 0A F5 0B "
            + "F5` trailing in canonical order — the features compose without "
            + "moving each other's bytes.",
         Capabilities.wireDefault.declaringHostAudioRouting()
            .declaringClipboardText().declaringBulkTransfer()),
    ].map { name, description, set in
        BulkCapabilityVector(
            name: name, description: description,
            messageHex: Hex.string(try set.encodeCbor()),
            bulkTransfer: set.bulkTransfer
        )
    }
}

// MARK: - Transfer vectors (worked multi-session traces, pinned
// self-consistent through the shared TestKit harness)

private func makeBulkTransferVectors() throws -> [BulkTransferVector] {
    /// One worked transfer: `sessionLimits` gives each session's
    /// receiver ingest limit (nil = the session runs out).
    func transfer(
        _ name: String, _ description: String, transferId: UInt64,
        total: Int, payloadStart: Int, fileName: String, mimeHint: String,
        window: Int, holes: BulkPossessionSpec? = nil, sessionLimits: [Int?]
    ) throws -> BulkTransferVector {
        let payload = counting(from: payloadStart, count: total)
        let offer = try BulkOffer(
            transferId: transferId, totalByteCount: UInt64(total),
            chunkByteCount: 4_096, sha256: Sha256.digest(payload),
            name: fileName, mimeHint: mimeHint
        )
        var harness = BulkTransferHarness(
            offer: offer, payload: payload, window: window,
            initialPossession: holes?.possession
        )
        return BulkTransferVector(
            name: name, description: description,
            provenance: "pinned-self-consistent",
            transferIdHex: Hex.uint64String(transferId),
            totalByteCount: total, chunkByteCount: 4_096,
            payloadStart: payloadStart,
            sha256Hex: Hex.string(offer.sha256),
            fileName: fileName, mimeHint: mimeHint,
            receiveWindowChunks: window, initialPossession: holes,
            sessions: try sessionLimits.map { limit in
                let run = try harness.runSession(receiverIngestLimit: limit)
                return BulkTransferSessionVector(
                    receiverIngestLimit: limit,
                    senderMessagesHex: run.senderMessages.map(Hex.string),
                    receiverMessagesHex: run.receiverMessages.map(Hex.string)
                )
            }
        )
    }

    return [
        // The teardown-resume story: session 1 dies after the receiver
        // has ingested offer + chunks 0-2, then session 2 resumes from
        // the hole-free prefix and completes.
        try transfer(
            "two-session-resume",
            "20,000 B over 4,096 B chunks (5 chunks, final 3,616 B), window "
                + "2. Session 1: the receiver ingests only offer + chunks 0-2 "
                + "(the teardown prefix — in-order carriage means a blackout "
                + "IS a prefix), leaving a 3-chunk hole-free possession. "
                + "Session 2: the identical re-offer matches the resume book, "
                + "the accept carries contiguousCount 3, only chunks 3-4 "
                + "travel, and the digest verdict completes — sha-exact "
                + "resume, J-G3's bar as bytes.",
            transferId: 0xB01D_FACE_0000_0001, total: 20_000, payloadStart: 0,
            fileName: "resume-demo.bin", mimeHint: "application/octet-stream",
            window: 2, sessionLimits: [4, nil]
        ),
        // The holed-map story: a persisted possession with gaps — the
        // shape a live prefix teardown cannot produce but a storage
        // audit can. One session fills exactly the holes and completes.
        try transfer(
            "resume-with-holes",
            "30,000 B over 4,096 B chunks (8 chunks, final 1,328 B), window "
                + "4, resuming from a HOLED possession: chunks 0-2 plus 5-6 "
                + "held. The accept's map is contiguousCount 3 + bitmap 0x06 "
                + "(bits 1,2 = chunks 5,6 — hand-checkable); the sender "
                + "dispatches exactly the holes (3, 4, 7); storing chunk 4 "
                + "snaps the prefix across the old extras (3→7); the digest "
                + "verdict completes.",
            transferId: 0xB01D_FACE_0000_0002, total: 30_000,
            payloadStart: 0x30, fileName: "holes-demo.bin", mimeHint: "",
            window: 4,
            holes: BulkPossessionSpec(
                contiguousCount: 3, extraChunkIndices: [5, 6]
            ),
            sessionLimits: [nil]
        ),
    ]
}
