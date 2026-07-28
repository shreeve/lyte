import XCTest
import LyteWire
import LyteWireTestKit

// The W10 bulk-message codecs (0x1C–0x21) against HAND-COMPUTED bytes —
// the anchor that keeps bulk-v1.json honest (the ControlCodecTests
// precedent: the codec never grades its own homework), plus the whole
// reject surface and the chunk-map/possession arithmetic.

final class BulkCodecTests: XCTestCase {

    private let id: UInt64 = 0x1122_3344_5566_7788
    private let idLE: [UInt8] = [
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
    ]
    private var sha: [UInt8] { (0..<32).map { UInt8(0xA0 + $0) } }

    // MARK: - Offer

    func testOfferHandComputedAnchor() throws {
        let offer = try BulkOffer(
            transferId: id,
            totalByteCount: 300_000,
            chunkByteCount: 65_536,
            sha256: sha,
            name: "report.pdf",
            mimeHint: "application/pdf"
        )
        var expected: [UInt8] = [0x1C]
        expected += idLE
        // 300,000 = 0x0004_93E0 LE.
        expected += [0xE0, 0x93, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]
        // 65,536 = 0x0001_0000 LE.
        expected += [0x00, 0x00, 0x01, 0x00]
        expected += sha
        expected += [10] + Array("report.pdf".utf8)
        expected += [15] + Array("application/pdf".utf8)
        XCTAssertEqual(offer.encode(), expected)
        XCTAssertEqual(try BulkOffer.decode(expected), offer)
        // Chunk geometry falls out: 5 chunks, final 37,856 B.
        XCTAssertEqual(offer.chunkCount, 5)
        XCTAssertEqual(offer.byteCount(ofChunk: 0), 65_536)
        XCTAssertEqual(offer.byteCount(ofChunk: 4), 37_856)
        XCTAssertNil(offer.byteCount(ofChunk: 5))
    }

    func testOfferGeometryEdges() throws {
        // An exact multiple: the final chunk is full-size.
        let exact = try BulkOffer(
            transferId: 1, totalByteCount: 8_192,
            chunkByteCount: 4_096, sha256: sha, name: "x"
        )
        XCTAssertEqual(exact.chunkCount, 2)
        XCTAssertEqual(exact.byteCount(ofChunk: 1), 4_096)
        // A 1-byte blob: one 1-byte chunk.
        let tiny = try BulkOffer(
            transferId: 1, totalByteCount: 1,
            chunkByteCount: 4_096, sha256: sha, name: "x"
        )
        XCTAssertEqual(tiny.chunkCount, 1)
        XCTAssertEqual(tiny.byteCount(ofChunk: 0), 1)
        // The no-ceiling claim: u64-max totals must not overflow the
        // chunk arithmetic.
        let huge = try BulkOffer(
            transferId: 1, totalByteCount: UInt64.max,
            chunkByteCount: 131_072, sha256: sha, name: "x"
        )
        XCTAssertEqual(huge.chunkCount, (UInt64.max - 1) / 131_072 + 1)
    }

    func testOfferConstructionRejects() {
        func offer(
            id: UInt64 = 1, total: UInt64 = 10, chunk: UInt32 = 4_096,
            sha: [UInt8]? = nil, name: String = "a", mime: String = ""
        ) throws -> BulkOffer {
            try BulkOffer(
                transferId: id, totalByteCount: total,
                chunkByteCount: chunk, sha256: sha ?? self.sha,
                name: name, mimeHint: mime
            )
        }
        XCTAssertThrowsError(try offer(id: 0)) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .zeroTransferId
            )
        }
        XCTAssertThrowsError(try offer(total: 0)) {
            XCTAssertEqual($0 as? BulkMessageError, .emptyTransfer)
        }
        XCTAssertThrowsError(try offer(chunk: 4_095)) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .chunkSizeOutOfBounds(4_095)
            )
        }
        XCTAssertThrowsError(try offer(chunk: 131_073)) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .chunkSizeOutOfBounds(131_073)
            )
        }
        XCTAssertThrowsError(try offer(sha: [0xAB])) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .invalidSha256ByteCount(1)
            )
        }
        XCTAssertThrowsError(try offer(name: "")) {
            XCTAssertEqual($0 as? BulkMessageError, .emptyName)
        }
        XCTAssertThrowsError(
            try offer(name: String(repeating: "a", count: 256))
        ) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .nameOverBudget(256)
            )
        }
        XCTAssertThrowsError(
            try offer(mime: String(repeating: "a", count: 256))
        ) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .mimeHintOverBudget(256)
            )
        }
    }

    func testOfferDecodeRejects() throws {
        let bytes = try BulkOffer(
            transferId: id, totalByteCount: 300_000,
            chunkByteCount: 65_536, sha256: sha,
            name: "report.pdf", mimeHint: "application/pdf"
        ).encode()
        XCTAssertThrowsError(try BulkOffer.decode([UInt8]())) {
            XCTAssertEqual($0 as? BulkMessageError, .truncatedMessage)
        }
        XCTAssertThrowsError(
            try BulkOffer.decode([0x7F] + bytes.dropFirst())
        ) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .unexpectedType(0x7F)
            )
        }
        for cut in [8, 30, 53, 58, 64, bytes.count - 1] {
            XCTAssertThrowsError(
                try BulkOffer.decode(Array(bytes.prefix(cut))),
                "cut at \(cut)"
            ) {
                XCTAssertEqual(
                    $0 as? BulkMessageError, .truncatedMessage,
                    "cut at \(cut)"
                )
            }
        }
        XCTAssertThrowsError(try BulkOffer.decode(bytes + [0x00])) {
            XCTAssertEqual($0 as? BulkMessageError, .trailingBytes)
        }
        var zeroId = bytes
        for i in 1...8 { zeroId[i] = 0 }
        XCTAssertThrowsError(try BulkOffer.decode(zeroId)) {
            XCTAssertEqual($0 as? BulkMessageError, .zeroTransferId)
        }
        // Invalid UTF-8 in the name.
        let badName = Array(bytes.prefix(53)) + [0x02, 0x68, 0xFF, 0x00]
        XCTAssertThrowsError(try BulkOffer.decode(badName)) {
            XCTAssertEqual($0 as? BulkMessageError, .invalidUtf8)
        }
        // nameLen 0.
        let noName = Array(bytes.prefix(53)) + [0x00, 0x00]
        XCTAssertThrowsError(try BulkOffer.decode(noName)) {
            XCTAssertEqual($0 as? BulkMessageError, .emptyName)
        }
    }

    // MARK: - Accept / ack (the shared credit+map layout)

    func testAcceptHandComputedAnchor() throws {
        let accept = try BulkAccept(
            transferId: id,
            creditTotal: 4,
            possession: BulkChunkMap(
                contiguousCount: 3, bitmap: [0x06]
            )
        )
        var expected: [UInt8] = [0x1D]
        expected += idLE
        expected += [4, 0, 0, 0, 0, 0, 0, 0]
        expected += [3, 0, 0, 0, 0, 0, 0, 0]
        expected += [1, 0] // bitmapLen u16 LE
        expected += [0x06] // bits 1,2 → chunks 5,6
        XCTAssertEqual(accept.encode(), expected)
        let decoded = try BulkAccept.decode(expected)
        XCTAssertEqual(decoded, accept)
        XCTAssertEqual(
            decoded.possession.bitmapChunkIndices, [5, 6]
        )
    }

    func testAckHandComputedAnchor() throws {
        let ack = try BulkAck(
            transferId: id,
            creditTotal: 24,
            possession: BulkChunkMap(contiguousCount: 8)
        )
        var expected: [UInt8] = [0x1F]
        expected += idLE
        expected += [24, 0, 0, 0, 0, 0, 0, 0]
        expected += [8, 0, 0, 0, 0, 0, 0, 0]
        expected += [0, 0]
        XCTAssertEqual(ack.encode(), expected)
        XCTAssertEqual(try BulkAck.decode(expected), ack)
    }

    func testCreditMapDecodeRejects() throws {
        let bytes = try BulkAck(
            transferId: id, creditTotal: 24,
            possession: BulkChunkMap(contiguousCount: 8)
        ).encode()
        XCTAssertThrowsError(
            try BulkAck.decode(Array(bytes.prefix(26)))
        ) {
            XCTAssertEqual($0 as? BulkMessageError, .truncatedMessage)
        }
        XCTAssertThrowsError(try BulkAck.decode(bytes + [0x01])) {
            XCTAssertEqual($0 as? BulkMessageError, .trailingBytes)
        }
        // The two codecs never cross-decode.
        XCTAssertThrowsError(try BulkAccept.decode(bytes)) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .unexpectedType(0x1F)
            )
        }
        // Non-canonical bitmap (zero final byte).
        var nonCanonical = Array(bytes.prefix(25))
        nonCanonical += [2, 0, 0x01, 0x00]
        XCTAssertThrowsError(try BulkAck.decode(nonCanonical)) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .nonCanonicalBitmap
            )
        }
        // Over-budget bitmap length field.
        var overBudget = Array(bytes.prefix(25))
        // 1,025 = 0x0401 LE.
        overBudget += [0x01, 0x04]
        overBudget += [UInt8](repeating: 0xFF, count: 1_025)
        XCTAssertThrowsError(try BulkAck.decode(overBudget)) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .bitmapOverBudget(1_025)
            )
        }
    }

    // MARK: - Chunk

    func testChunkHandComputedAnchor() throws {
        let data = (0..<48).map { UInt8(0x10 + $0) }
        let chunk = try BulkChunk(
            transferId: id, chunkIndex: 7, data: data
        )
        var expected: [UInt8] = [0x1E]
        expected += idLE
        expected += [7, 0, 0, 0, 0, 0, 0, 0]
        expected += data
        XCTAssertEqual(chunk.encode(), expected)
        XCTAssertEqual(try BulkChunk.decode(expected), chunk)
    }

    func testChunkBounds() throws {
        XCTAssertNoThrow(try BulkChunk(
            transferId: 1, chunkIndex: 0,
            data: [UInt8](repeating: 0, count: BulkWire.maxChunkByteCount)
        ))
        XCTAssertThrowsError(try BulkChunk(
            transferId: 1, chunkIndex: 0,
            data: [UInt8](
                repeating: 0, count: BulkWire.maxChunkByteCount + 1
            )
        )) {
            XCTAssertEqual(
                $0 as? BulkMessageError,
                .chunkDataOverBudget(BulkWire.maxChunkByteCount + 1)
            )
        }
        XCTAssertThrowsError(try BulkChunk(
            transferId: 1, chunkIndex: 0, data: []
        )) {
            XCTAssertEqual($0 as? BulkMessageError, .emptyChunkData)
        }
        // Decode-side: a bare 17-byte header has no data.
        let bytes = try BulkChunk(
            transferId: 1, chunkIndex: 0, data: [0xAA]
        ).encode()
        XCTAssertThrowsError(
            try BulkChunk.decode(Array(bytes.prefix(17)))
        ) {
            XCTAssertEqual($0 as? BulkMessageError, .emptyChunkData)
        }
        XCTAssertThrowsError(
            try BulkChunk.decode(Array(bytes.prefix(12)))
        ) {
            XCTAssertEqual($0 as? BulkMessageError, .truncatedMessage)
        }
    }

    // MARK: - Complete / abort

    func testCompleteHandComputedAnchor() throws {
        let complete = try BulkComplete(transferId: id)
        XCTAssertEqual(complete.encode(), [0x20] + idLE)
        XCTAssertEqual(
            try BulkComplete.decode([0x20] + idLE), complete
        )
        XCTAssertThrowsError(
            try BulkComplete.decode([0x20] + idLE + [0])
        ) {
            XCTAssertEqual($0 as? BulkMessageError, .trailingBytes)
        }
    }

    func testAbortWholeReasonSpace() throws {
        // Every reason round-trips; the raw values are wire contract.
        let expectedRaw: [BulkAbortReason: UInt8] = [
            .declined: 0x01, .cancelled: 0x02, .resumeMismatch: 0x03,
            .shaMismatch: 0x04, .storageFailure: 0x05, .busy: 0x06,
            .protocolViolation: 0x07,
        ]
        XCTAssertEqual(
            Set(BulkAbortReason.allCases), Set(expectedRaw.keys)
        )
        for (reason, raw) in expectedRaw {
            let abort = try BulkAbort(transferId: id, reason: reason)
            XCTAssertEqual(abort.encode(), [0x21] + idLE + [raw])
            XCTAssertEqual(
                try BulkAbort.decode([0x21] + idLE + [raw]), abort
            )
        }
        XCTAssertThrowsError(
            try BulkAbort.decode([0x21] + idLE + [0x00])
        ) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .unknownAbortReason(0x00)
            )
        }
        XCTAssertThrowsError(
            try BulkAbort.decode([0x21] + idLE + [0x7F])
        ) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .unknownAbortReason(0x7F)
            )
        }
    }

    // MARK: - The dispatch enum

    func testBulkMessageDispatch() throws {
        let messages: [BulkMessage] = [
            .offer(try BulkOffer(
                transferId: id, totalByteCount: 10,
                chunkByteCount: 4_096, sha256: sha, name: "a"
            )),
            .accept(try BulkAccept(transferId: id, creditTotal: 2)),
            .chunk(try BulkChunk(
                transferId: id, chunkIndex: 0, data: [1, 2, 3]
            )),
            .ack(try BulkAck(
                transferId: id, creditTotal: 3,
                possession: BulkChunkMap(contiguousCount: 1)
            )),
            .complete(try BulkComplete(transferId: id)),
            .abort(try BulkAbort(transferId: id, reason: .cancelled)),
        ]
        for message in messages {
            XCTAssertEqual(
                try BulkMessage.decode(message.encode()), message
            )
            XCTAssertEqual(message.transferId, id)
        }
        XCTAssertThrowsError(try BulkMessage.decode([0x42])) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .unexpectedType(0x42)
            )
        }
        XCTAssertThrowsError(try BulkMessage.decode([UInt8]())) {
            XCTAssertEqual($0 as? BulkMessageError, .truncatedMessage)
        }
    }

    // MARK: - The registry and the capability spine

    func testRegistryPins() {
        XCTAssertEqual(CtrlMessageType.bulkOffer, 0x1C)
        XCTAssertEqual(CtrlMessageType.bulkAccept, 0x1D)
        XCTAssertEqual(CtrlMessageType.bulkChunk, 0x1E)
        XCTAssertEqual(CtrlMessageType.bulkAck, 0x1F)
        XCTAssertEqual(CtrlMessageType.bulkComplete, 0x20)
        XCTAssertEqual(CtrlMessageType.bulkAbort, 0x21)
        XCTAssertEqual(CapabilityKey.bulkTransfer, 11)
        XCTAssertEqual(ChannelId.bulkTransfer.rawValue, 8)
        XCTAssertEqual(
            ChannelId.bulkTransfer.deliveryClass, .reliableOrdered
        )
        XCTAssertEqual(ChannelId.bulkTransfer.priority, .bulk)
    }

    func testCapabilityKey11Spine() throws {
        // The frozen wireDefault bytes plus exactly `0B F5` — the
        // key-9/key-10 proof repeated for key 11.
        let base = try Capabilities.wireDefault.encodeCbor()
        let declared = try Capabilities.wireDefault
            .declaringBulkTransfer().encodeCbor()
        XCTAssertEqual(declared.first, 0xA9, "map head 0xA8 → 0xA9")
        XCTAssertEqual(
            Array(declared.dropFirst()),
            Array(base.dropFirst()) + [0x0B, 0xF5]
        )
        let set = try Capabilities.decodeCbor(declared)
        XCTAssertTrue(set.bulkTransfer)
        XCTAssertFalse(Capabilities.wireDefault.bulkTransfer)
        // Idempotent, and intersection follows the byte-equal rule.
        XCTAssertEqual(
            set.declaringBulkTransfer(), set
        )
        XCTAssertTrue(set.intersecting(set).bulkTransfer)
        XCTAssertFalse(
            set.intersecting(Capabilities.wireDefault).bulkTransfer
        )
    }

    // MARK: - Chunk map + possession arithmetic

    func testChunkMapSemantics() throws {
        let map = try BulkChunkMap(
            contiguousCount: 3, bitmap: [0x06]
        )
        XCTAssertTrue(map.holds(0))
        XCTAssertTrue(map.holds(2))
        XCTAssertFalse(map.holds(3), "the boundary chunk is not held")
        XCTAssertFalse(map.holds(4), "bit 0 is clear")
        XCTAssertTrue(map.holds(5))
        XCTAssertTrue(map.holds(6))
        XCTAssertFalse(map.holds(7))
        XCTAssertEqual(map.heldChunkCount, 5)
        XCTAssertThrowsError(
            try BulkChunkMap(contiguousCount: 0, bitmap: [0x01, 0x00])
        ) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .nonCanonicalBitmap
            )
        }
        XCTAssertThrowsError(try BulkChunkMap(
            contiguousCount: 0,
            bitmap: [UInt8](repeating: 1, count: 1_025)
        )) {
            XCTAssertEqual(
                $0 as? BulkMessageError, .bitmapOverBudget(1_025)
            )
        }
    }

    func testChunkMapDescribingNormalizesAndUnderClaims() {
        // Extras adjoining the prefix fold in.
        let folded = BulkChunkMap.describing(
            contiguousCount: 3, extras: [3, 4, 6]
        )
        XCTAssertEqual(folded.contiguousCount, 5)
        XCTAssertEqual(folded.bitmapChunkIndices, [6])
        // An extra past the describable window under-claims, never
        // overflows.
        let far = UInt64(3 + 1 + BulkWire.maxBitmapByteCount * 8)
        let clipped = BulkChunkMap.describing(
            contiguousCount: 3, extras: [far]
        )
        XCTAssertEqual(clipped.contiguousCount, 3)
        XCTAssertTrue(clipped.bitmap.isEmpty)
        // The last describable offset is included.
        let edge = far - 1
        let atEdge = BulkChunkMap.describing(
            contiguousCount: 3, extras: [edge]
        )
        XCTAssertEqual(atEdge.bitmapChunkIndices, [edge])
        XCTAssertEqual(
            atEdge.bitmap.count, BulkWire.maxBitmapByteCount
        )
    }

    func testPossessionArithmetic() {
        var possession = BulkPossession()
        XCTAssertEqual(possession, .empty)
        possession.add(0)
        possession.add(2)
        possession.add(5)
        XCTAssertEqual(possession.contiguousCount, 1)
        XCTAssertEqual(possession.extras, [2, 5])
        // Filling the gap snaps the prefix across the old extras.
        possession.add(1)
        XCTAssertEqual(possession.contiguousCount, 3)
        XCTAssertEqual(possession.extras, [5])
        // Adds are idempotent.
        possession.add(1)
        XCTAssertEqual(possession.heldChunkCount, 4)
        // nextMissing walks holes only.
        XCTAssertEqual(
            possession.nextMissing(from: 0, below: 8), 3
        )
        XCTAssertEqual(
            possession.nextMissing(from: 4, below: 8), 4
        )
        XCTAssertEqual(
            possession.nextMissing(from: 5, below: 8), 6
        )
        XCTAssertNil(
            BulkPossession(contiguousCount: 8)
                .nextMissing(from: 0, below: 8)
        )
        // Merge is a monotonic union.
        var merged = BulkPossession(contiguousCount: 2)
        merged.merge(BulkChunkMap.describing(
            contiguousCount: 1, extras: [2, 4]
        ))
        XCTAssertEqual(merged.contiguousCount, 3)
        XCTAssertEqual(merged.extras, [4])
        XCTAssertTrue(
            BulkPossession(contiguousCount: 5)
                .isComplete(chunkCount: 5)
        )
    }

    func testTransferIdMintSkipsZero() {
        struct ZeroFirst: RandomNumberGenerator {
            var values: [UInt64] = [0, 0, 7]
            mutating func next() -> UInt64 {
                values.isEmpty ? 42 : values.removeFirst()
            }
        }
        var generator = ZeroFirst()
        XCTAssertEqual(BulkTransferId.mint(using: &generator), 7)
    }
}
