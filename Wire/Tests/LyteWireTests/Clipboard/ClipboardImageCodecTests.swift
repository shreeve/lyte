import XCTest
import LyteWire

// The P-1 clipboard-image vocabulary's anchors: hand-computed bytes
// for the 0x22 cargo marker (the vector file never grades its own
// homework), the key-12 capability spine and the triple gate, the
// registry numbers, mime policy, and the sync book's byte-key laws —
// one book serving text AND images without collision.

final class ClipboardImageCodecTests: XCTestCase {

    // MARK: The cargo marker, pinned against hand-computed bytes

    func testCargoMarkerPinsBytes() throws {
        // type 0x22 ‖ id u64 LE ‖ mimeLen u8 ‖ mime UTF-8.
        // id 0x0102030405060708 LE = 08 07 06 05 04 03 02 01;
        // "image/png" = 69 6D 61 67 65 2F 70 6E 67 (9 bytes) — all
        // computed by hand from ASCII.
        let cargo = try ClipboardImageCargo(
            transferId: 0x0102_0304_0506_0708, mime: "image/png"
        )
        let expected: [UInt8] = [
            0x22,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0x09,
            0x69, 0x6D, 0x61, 0x67, 0x65, 0x2F, 0x70, 0x6E, 0x67,
        ]
        XCTAssertEqual(cargo.encode(), expected)
        let decoded = try ClipboardImageCargo.decode(expected)
        XCTAssertEqual(decoded, cargo)
        XCTAssertEqual(decoded.transferId, 0x0102_0304_0506_0708)
        XCTAssertEqual(decoded.mime, "image/png")
    }

    func testHostileCargoBytesRejectAndNeverTrap() throws {
        let good = try ClipboardImageCargo(
            transferId: 7, mime: "image/png"
        ).encode()

        // Empty, bare type, truncated header, truncated mime.
        XCTAssertThrowsError(try ClipboardImageCargo.decode([])) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .truncatedMessage)
        }
        XCTAssertThrowsError(try ClipboardImageCargo.decode([0x22])) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .truncatedMessage)
        }
        XCTAssertThrowsError(
            try ClipboardImageCargo.decode(Array(good.prefix(9)))
        ) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .truncatedMessage)
        }
        XCTAssertThrowsError(
            try ClipboardImageCargo.decode(Array(good.dropLast()))
        ) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .truncatedMessage)
        }

        // A foreign type byte rejects with what it found.
        var foreign = good
        foreign[0] = 0x1A
        XCTAssertThrowsError(try ClipboardImageCargo.decode(foreign)) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .unexpectedType(0x1A))
        }

        // Trailing bytes reject — exactly its layout.
        XCTAssertThrowsError(
            try ClipboardImageCargo.decode(good + [0x00])
        ) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .trailingBytes)
        }

        // A zero id is always some layer's zero-fill bug.
        var zeroId = good
        for i in 1...8 { zeroId[i] = 0 }
        XCTAssertThrowsError(try ClipboardImageCargo.decode(zeroId)) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .zeroTransferId)
        }

        // A mime-less marker is unroutable.
        XCTAssertThrowsError(
            try ClipboardImageCargo.decode(
                [0x22, 7, 0, 0, 0, 0, 0, 0, 0, 0]
            )
        ) {
            XCTAssertEqual($0 as? ClipboardImageCargoError, .emptyMime)
        }

        // Invalid UTF-8 in the mime rejects, never replaces.
        XCTAssertThrowsError(
            try ClipboardImageCargo.decode(
                [0x22, 7, 0, 0, 0, 0, 0, 0, 0, 1, 0xFF]
            )
        ) {
            XCTAssertEqual($0 as? ClipboardImageCargoError, .invalidUtf8)
        }
    }

    func testCargoConstructionRefusesWhatEncodeCannotCarry() {
        XCTAssertThrowsError(
            try ClipboardImageCargo(transferId: 0, mime: "image/png")
        ) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .zeroTransferId)
        }
        XCTAssertThrowsError(
            try ClipboardImageCargo(transferId: 7, mime: "")
        ) {
            XCTAssertEqual($0 as? ClipboardImageCargoError, .emptyMime)
        }
        let long = String(repeating: "a", count: 256)
        XCTAssertThrowsError(
            try ClipboardImageCargo(transferId: 7, mime: long)
        ) {
            XCTAssertEqual($0 as? ClipboardImageCargoError,
                           .mimeOverBudget(256))
        }
        // 255 is the u8-length ceiling — legal to the byte.
        XCTAssertNoThrow(try ClipboardImageCargo(
            transferId: 7, mime: String(repeating: "a", count: 255)
        ))
    }

    // MARK: Key 12 on the forward-compat spine, zero frozen bytes

    func testCapabilityKeyRidesTheSpineWithoutMovingFrozenBytes() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        // wireDefault is an 8-entry map — the frozen v1 shape.
        XCTAssertEqual(base.first, 0xA8)

        // The declaration is EXACTLY the frozen bytes plus one
        // appended entry: map(9) head + trailing `0C F5` (key 12
        // sorts last among keys 1–12 in RFC 8949 bytewise order).
        var expected = base
        expected[0] = 0xA9
        expected += [0x0C, 0xF5]
        let declared = Capabilities.wireDefault.declaringClipboardImages()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        // Reads back as itself through the v1 decoder: key 12 lands
        // in unknownEntries and the typed accessor sees it.
        let decoded = try Capabilities.decodeCbor(declared.encodeCbor())
        XCTAssertTrue(decoded.clipboardImages)
        XCTAssertEqual(decoded, declared)
        XCTAssertFalse(Capabilities.wireDefault.clipboardImages)

        // Idempotent declaration.
        XCTAssertEqual(declared.declaringClipboardImages(), declared)

        // Keys 10, 11, and 12 compose into ONE canonical byte image:
        // map head 0xAB, `0A F5 0B F5 0C F5` trailing — regardless
        // of construction order.
        var trio = base
        trio[0] = 0xAB
        trio += [0x0A, 0xF5, 0x0B, 0xF5, 0x0C, 0xF5]
        XCTAssertEqual(
            try Capabilities.wireDefault
                .declaringClipboardText()
                .declaringBulkTransfer()
                .declaringClipboardImages()
                .encodeCbor(),
            trio
        )
        XCTAssertEqual(
            try Capabilities.wireDefault
                .declaringClipboardImages()
                .declaringBulkTransfer()
                .declaringClipboardText()
                .encodeCbor(),
            trio
        )
    }

    func testImageGateRequiresFeatureAndDialectButNeverFileConsent() {
        let images = Capabilities.wireDefault
            .declaringClipboardText()
            .declaringClipboardImages()

        // Both keys survive mutual declaration → images move — and
        // WITHOUT key 11: the file-drop consent (F-2 §6) must never
        // couple to the clipboard tier.
        let agreed = images.intersecting(images)
        XCTAssertTrue(agreed.clipboardImagesAgreed)
        XCTAssertFalse(agreed.bulkTransfer)

        // Key 12 alone is a dialect with no feature.
        let dialectOnly = Capabilities.wireDefault
            .declaringClipboardImages()
        XCTAssertTrue(dialectOnly.clipboardImages)
        XCTAssertFalse(dialectOnly.clipboardImagesAgreed)

        // A text-only peer fails the gate; text still moves — v2
        // degrades to v1, never breaks it.
        let textOnly = Capabilities.wireDefault.declaringClipboardText()
        XCTAssertFalse(
            images.intersecting(textOnly).clipboardImagesAgreed
        )
        XCTAssertTrue(images.intersecting(textOnly).clipboardText)

        // Key 11 composes independently: a files+images end against
        // an images-only end keeps images and drops file consent.
        let everything = images.declaringBulkTransfer()
        let mixed = everything.intersecting(images)
        XCTAssertTrue(mixed.clipboardImagesAgreed)
        XCTAssertFalse(mixed.bulkTransfer)

        // One-sided declaration drops at intersection, both orders.
        XCTAssertFalse(
            images.intersecting(.wireDefault).clipboardImagesAgreed
        )
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(images)
                .clipboardImagesAgreed
        )
    }

    // MARK: The registry itself

    func testClipboardImageRegistryNumbersAreThePinnedOnes() {
        // A registry typo here would be a silent wire break on both
        // ends at once (the control-codec pin's rule).
        XCTAssertEqual(CtrlMessageType.clipboardImageCargo, 0x22)
        XCTAssertEqual(CapabilityKey.clipboardImages, 12)
        XCTAssertEqual(ClipboardImageWire.maxImageByteCount, 33_554_432)
        XCTAssertEqual(ClipboardImageWire.chunkByteCount, 65_536)
        XCTAssertEqual(ClipboardImageWire.pngMime, "image/png")
        XCTAssertEqual(ClipboardImageWire.acceptedMimes, ["image/png"])
        XCTAssertEqual(ClipboardImageWire.wireName, "clipboard.png")
    }

    func testMimeAcceptanceIsCaseInsensitiveExactMatch() {
        XCTAssertTrue(ClipboardImageWire.accepts(mime: "image/png"))
        XCTAssertTrue(ClipboardImageWire.accepts(mime: "IMAGE/PNG"))
        XCTAssertTrue(ClipboardImageWire.accepts(mime: "Image/Png"))
        XCTAssertFalse(ClipboardImageWire.accepts(mime: "image/jpeg"))
        XCTAssertFalse(ClipboardImageWire.accepts(mime: "image/png "))
        XCTAssertFalse(ClipboardImageWire.accepts(mime: ""))
    }

    // MARK: The sync book's byte-key laws (one book, two kinds)

    func testImageBookKeysCannotCollideWithText() {
        // 0xFF is never valid UTF-8, so an image key can never equal
        // any text's UTF-8 bytes — the two key spaces are disjoint by
        // construction.
        let digest = [UInt8](repeating: 0xAB, count: 32)
        let key = ClipboardImageWire.bookKey(sha256: digest)
        XCTAssertEqual(key.count, 33)
        XCTAssertEqual(key.first, 0xFF)
        XCTAssertEqual(Array(key.dropFirst()), digest)
        // Round-tripping through String mangles it (replacement
        // characters) — no text's UTF-8 bytes can ever equal it.
        XCTAssertNotEqual(
            Array(String(decoding: key, as: UTF8.self).utf8), key
        )
    }

    func testByteKeyedBookMatchesTextBehaviorExactly() {
        // The byte-keyed API under UTF-8 keys IS the v1 text book —
        // same verdicts, same consume-once law.
        var textBook = ClipboardSyncBook()
        var byteBook = ClipboardSyncBook()
        let key = Array("hello".utf8)

        XCTAssertEqual(textBook.admitLocalChange("hello"), .share)
        XCTAssertEqual(byteBook.admitLocalChange(bytes: key), .share)
        textBook.noteShared("hello")
        byteBook.noteShared(bytes: key)
        XCTAssertEqual(textBook.admitLocalChange("hello"),
                       .suppressDuplicate)
        XCTAssertEqual(byteBook.admitLocalChange(bytes: key),
                       .suppressDuplicate)
        textBook.noteRemoteApplied("hello")
        byteBook.noteRemoteApplied(bytes: key)
        XCTAssertEqual(textBook.admitLocalChange("hello"), .suppressEcho)
        XCTAssertEqual(byteBook.admitLocalChange(bytes: key),
                       .suppressEcho)
        XCTAssertEqual(textBook.admitLocalChange("hello"), .share)
        XCTAssertEqual(byteBook.admitLocalChange(bytes: key), .share)
    }

    func testOneBookServesTextAndImagesCrossModally() {
        var book = ClipboardSyncBook()
        let imageKey = ClipboardImageWire.bookKey(
            sha256: [UInt8](repeating: 0x11, count: 32)
        )

        // A remote IMAGE apply arms the echo stop for the image key
        // and clears the text dedupe slot — the peer's clipboard
        // moved past whatever we last sent, whatever kind it was.
        XCTAssertEqual(book.admitLocalChange("text"), .share)
        book.noteShared("text")
        XCTAssertEqual(book.admitLocalChange("text"),
                       .suppressDuplicate)
        book.noteRemoteApplied(bytes: imageKey)
        XCTAssertEqual(book.admitLocalChange(bytes: imageKey),
                       .suppressEcho)
        XCTAssertEqual(book.admitLocalChange("text"), .share)

        // And the mirror: sharing an image clears a pending TEXT echo
        // (the noteShared law, byte-keyed).
        book.noteRemoteApplied("theirs")
        book.noteShared(bytes: imageKey)
        XCTAssertEqual(book.admitLocalChange("theirs"), .share)
        XCTAssertEqual(book.admitLocalChange(bytes: imageKey),
                       .suppressDuplicate)
    }
}
