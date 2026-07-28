import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/bulk-v1.json byte-exact — the W10
// bulk-channel sextet (0x1C–0x21), the key-11 capability spine, and
// the worked multi-session transfer traces — on both platforms.

final class BulkVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/bulk-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> BulkVectorFile {
        try BulkVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, BulkVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.messageVectors.isEmpty)
        XCTAssertFalse(file.capabilityVectors.isEmpty)
        XCTAssertFalse(file.transferVectors.isEmpty)
        let names = file.messageVectors.map(\.name)
            + file.capabilityVectors.map(\.name)
            + file.transferVectors.map(\.name)
        XCTAssertEqual(Set(names).count, names.count,
                       "vector names must be unique")
    }

    /// The file's coverage discipline: every codec carries
    /// roundtrips, every BulkMessageError case name appears at least
    /// once, the abort reason space is pinned WHOLE (the lifecycle
    /// rule), the structural ceilings are pinned legal to the byte,
    /// the key-11 spine is pinned declared AND absent, and the
    /// transfer section carries both a multi-session resume and a
    /// holed-possession resume.
    func testCoverageDiscipline() throws {
        let file = try loadFile()
        for codec: BulkMessageVector.BulkCodec
            in [.offer, .accept, .chunk, .ack, .complete, .abort] {
            XCTAssertTrue(
                file.messageVectors.contains {
                    $0.codec == codec && $0.kind == .roundtrip
                },
                "\(codec) needs roundtrips"
            )
        }
        let allErrorNames: Set<String> = [
            "truncatedMessage", "unexpectedType", "trailingBytes",
            "zeroTransferId", "emptyTransfer", "chunkSizeOutOfBounds",
            "invalidSha256ByteCount", "emptyName", "nameOverBudget",
            "mimeHintOverBudget", "invalidUtf8", "emptyChunkData",
            "chunkDataOverBudget", "bitmapOverBudget",
            "nonCanonicalBitmap", "unknownAbortReason",
        ]
        XCTAssertEqual(
            Set(file.messageVectors.compactMap(\.error)),
            allErrorNames,
            "every BulkMessageError case pinned at least once"
        )
        XCTAssertEqual(
            Set(file.messageVectors.lazy
                .filter { $0.codec == .abort && $0.kind == .roundtrip }
                .compactMap(\.reason)),
            Set(BulkAbortReason.allCases.map(bulkAbortReasonName)),
            "the abort reason space pinned whole"
        )
        XCTAssertTrue(
            file.messageVectors.contains {
                $0.codec == .chunk && $0.kind == .roundtrip
                    && $0.dataHex.flatMap(Hex.bytes)?.count
                        == BulkWire.maxChunkByteCount
            },
            "the exact chunk-data ceiling pinned legal"
        )
        XCTAssertTrue(
            file.messageVectors.contains {
                $0.kind == .roundtrip
                    && $0.bitmapHex.flatMap(Hex.bytes)?.count
                        == BulkWire.maxBitmapByteCount
            },
            "the exact bitmap ceiling pinned legal"
        )
        XCTAssertTrue(
            file.messageVectors.contains {
                $0.codec == .offer && $0.kind == .roundtrip
                    && $0.totalByteCountHex.flatMap(Hex.uint64)
                        == UInt64.max
            },
            "the no-size-ceiling claim pinned (u64-max total legal)"
        )
        XCTAssertEqual(
            Set(file.capabilityVectors.map(\.bulkTransfer)),
            [true, false],
            "the key-11 spine pinned declared AND absent"
        )
        XCTAssertTrue(
            file.transferVectors.contains { $0.sessions.count > 1 },
            "a teardown-resume transfer trace is pinned"
        )
        XCTAssertTrue(
            file.transferVectors.contains {
                ($0.initialPossession?.extraChunkIndices.isEmpty
                    == false)
            },
            "a holed-possession resume trace is pinned"
        )
        for transfer in file.transferVectors {
            XCTAssertEqual(
                transfer.provenance, "pinned-self-consistent",
                "\(transfer.name): transfer traces are pinned, not "
                    + "external — the provenance must say so"
            )
        }
    }

    // MARK: - Message vectors

    func testAllMessageVectors() throws {
        for vector in try loadFile().messageVectors {
            switch vector.kind {
            case .roundtrip:
                try checkRoundtrip(vector)
            case .decodeReject:
                try checkDecodeReject(vector)
            case .encodeReject:
                try checkEncodeReject(vector)
            }
        }
    }

    private func requireU64(
        _ hex: String?, _ vector: BulkMessageVector, _ field: String
    ) throws -> UInt64 {
        guard let value = hex.flatMap(Hex.uint64) else {
            XCTFail("\(vector.name): missing/malformed \(field)")
            throw BulkMessageError.truncatedMessage
        }
        return value
    }

    private func requireBytes(
        _ hex: String?, _ vector: BulkMessageVector, _ field: String
    ) throws -> [UInt8] {
        guard let bytes = hex.flatMap(Hex.bytes) else {
            XCTFail("\(vector.name): missing/malformed \(field)")
            throw BulkMessageError.truncatedMessage
        }
        return bytes
    }

    /// Builds the typed value from the vector's fields (throwing —
    /// which is exactly what encodeReject vectors assert).
    private func buildTyped(
        _ vector: BulkMessageVector
    ) throws -> BulkMessage {
        let id = try requireU64(
            vector.transferIdHex, vector, "transferIdHex"
        )
        switch vector.codec {
        case .offer:
            let nameBytes = try requireBytes(
                vector.nameUtf8Hex, vector, "nameUtf8Hex"
            )
            let mimeBytes = try requireBytes(
                vector.mimeUtf8Hex, vector, "mimeUtf8Hex"
            )
            return .offer(try BulkOffer(
                transferId: id,
                totalByteCount: try requireU64(
                    vector.totalByteCountHex, vector,
                    "totalByteCountHex"
                ),
                chunkByteCount: UInt32(vector.chunkByteCount ?? 0),
                sha256: try requireBytes(
                    vector.sha256Hex, vector, "sha256Hex"
                ),
                name: String(decoding: nameBytes, as: UTF8.self),
                mimeHint: String(decoding: mimeBytes, as: UTF8.self)
            ))
        case .accept:
            return .accept(try BulkAccept(
                transferId: id,
                creditTotal: try requireU64(
                    vector.creditTotalHex, vector, "creditTotalHex"
                ),
                possession: try BulkChunkMap(
                    contiguousCount: try requireU64(
                        vector.contiguousCountHex, vector,
                        "contiguousCountHex"
                    ),
                    bitmap: try requireBytes(
                        vector.bitmapHex, vector, "bitmapHex"
                    )
                )
            ))
        case .ack:
            return .ack(try BulkAck(
                transferId: id,
                creditTotal: try requireU64(
                    vector.creditTotalHex, vector, "creditTotalHex"
                ),
                possession: try BulkChunkMap(
                    contiguousCount: try requireU64(
                        vector.contiguousCountHex, vector,
                        "contiguousCountHex"
                    ),
                    bitmap: try requireBytes(
                        vector.bitmapHex, vector, "bitmapHex"
                    )
                )
            ))
        case .chunk:
            return .chunk(try BulkChunk(
                transferId: id,
                chunkIndex: try requireU64(
                    vector.chunkIndexHex, vector, "chunkIndexHex"
                ),
                data: try requireBytes(
                    vector.dataHex, vector, "dataHex"
                )
            ))
        case .complete:
            return .complete(try BulkComplete(transferId: id))
        case .abort:
            guard let reason = vector.reason
                .flatMap(bulkAbortReason(named:)) else {
                XCTFail("\(vector.name): missing/unknown reason")
                throw BulkMessageError.truncatedMessage
            }
            return .abort(try BulkAbort(
                transferId: id, reason: reason
            ))
        }
    }

    private func checkRoundtrip(_ vector: BulkMessageVector) throws {
        guard let message = vector.messageHex.flatMap(Hex.bytes) else {
            return XCTFail("\(vector.name): malformed messageHex")
        }
        let typed = try buildTyped(vector)
        XCTAssertEqual(
            typed.encode(), message,
            "\(vector.name): encode must match the frozen bytes"
        )
        XCTAssertEqual(
            try BulkMessage.decode(message), typed,
            "\(vector.name): decode must recover the typed value"
        )
    }

    private func decodeWithCodec(
        _ codec: BulkMessageVector.BulkCodec, _ bytes: [UInt8]
    ) throws {
        switch codec {
        case .offer: _ = try BulkOffer.decode(bytes)
        case .accept: _ = try BulkAccept.decode(bytes)
        case .chunk: _ = try BulkChunk.decode(bytes)
        case .ack: _ = try BulkAck.decode(bytes)
        case .complete: _ = try BulkComplete.decode(bytes)
        case .abort: _ = try BulkAbort.decode(bytes)
        }
    }

    private func checkDecodeReject(
        _ vector: BulkMessageVector
    ) throws {
        guard let message = vector.messageHex.flatMap(Hex.bytes) else {
            return XCTFail("\(vector.name): malformed messageHex")
        }
        XCTAssertThrowsError(
            try decodeWithCodec(vector.codec, message), vector.name
        ) {
            guard let error = $0 as? BulkMessageError else {
                return XCTFail("\(vector.name): foreign error \($0)")
            }
            XCTAssertEqual(
                bulkMessageErrorName(error), vector.error, vector.name
            )
        }
    }

    private func checkEncodeReject(
        _ vector: BulkMessageVector
    ) throws {
        XCTAssertThrowsError(
            try buildTyped(vector), vector.name
        ) {
            guard let error = $0 as? BulkMessageError else {
                return XCTFail("\(vector.name): foreign error \($0)")
            }
            XCTAssertEqual(
                bulkMessageErrorName(error), vector.error, vector.name
            )
        }
    }

    // MARK: - Capability vectors (the key-11 spine as data)

    func testAllCapabilityVectors() throws {
        for vector in try loadFile().capabilityVectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                return XCTFail("\(vector.name): malformed messageHex")
            }
            let set = try Capabilities.decodeCbor(message)
            XCTAssertEqual(
                set.bulkTransfer, vector.bulkTransfer, vector.name
            )
            XCTAssertEqual(
                try set.encodeCbor(), message,
                "\(vector.name): byte-exact re-encode"
            )
        }
    }

    // MARK: - Transfer vectors (the worked traces, replayed through
    // the same harness that authored them)

    func testAllTransferVectors() throws {
        for vector in try loadFile().transferVectors {
            try replayTransfer(vector)
        }
    }

    private func replayTransfer(_ vector: BulkTransferVector) throws {
        guard let transferId = Hex.uint64(vector.transferIdHex),
              let sha = Hex.bytes(vector.sha256Hex) else {
            return XCTFail("\(vector.name): malformed identity fields")
        }
        let payload = (0..<vector.totalByteCount).map {
            UInt8((vector.payloadStart + $0) & 0xFF)
        }
        XCTAssertEqual(
            Sha256.digest(payload), sha,
            "\(vector.name): the frozen digest must be the payload's"
        )
        let offer = try BulkOffer(
            transferId: transferId,
            totalByteCount: UInt64(vector.totalByteCount),
            chunkByteCount: UInt32(vector.chunkByteCount),
            sha256: sha,
            name: vector.fileName,
            mimeHint: vector.mimeHint
        )
        var harness = BulkTransferHarness(
            offer: offer,
            payload: payload,
            window: vector.receiveWindowChunks,
            initialPossession: vector.initialPossession?.possession
        )
        for (index, session) in vector.sessions.enumerated() {
            let result = try harness.runSession(
                receiverIngestLimit: session.receiverIngestLimit
            )
            XCTAssertEqual(
                result.senderMessages.map(Hex.string),
                session.senderMessagesHex,
                "\(vector.name) session \(index): sender trace must "
                    + "match the frozen bytes"
            )
            XCTAssertEqual(
                result.receiverMessages.map(Hex.string),
                session.receiverMessagesHex,
                "\(vector.name) session \(index): receiver trace "
                    + "must match the frozen bytes"
            )
            let isLast = index == vector.sessions.count - 1
            if isLast {
                XCTAssertEqual(
                    result.senderFinalState, .completed,
                    "\(vector.name): the final session completes"
                )
                XCTAssertEqual(
                    result.receiverFinalState, .completed, vector.name
                )
            }
        }
        // The sha-exact bar: what landed is byte-identical.
        XCTAssertEqual(
            harness.assembledDigest(), sha,
            "\(vector.name): the assembled blob must digest to the "
                + "offer's sha"
        )
    }
}
