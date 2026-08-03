import XCTest
import LyteWire

// The CL-15 clipboard vocabulary's anchors (design doc
// docs/20260722-231500-lyte-clipboard.md): hand-computed bytes for the
// 0x1A/0x1B pair (the vector file never grades its own homework), the
// key-10 capability spine, the registry numbers, and the
// loop-prevention book's laws — including the proof obligation that a
// set must not boomerang.

final class ClipboardCodecTests: XCTestCase {

    // MARK: The codecs, pinned against hand-computed bytes

    func testClipboardCodecsPinBytes() throws {
        // "hello" = 68 65 6C 6C 6F — computed by hand from ASCII.
        XCTAssertEqual(
            try ClipboardSet(text: "hello").encode(),
            [0x1A, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
        )
        XCTAssertEqual(
            try ClipboardAnnounce(text: "hello").encode(),
            [0x1B, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
        )
        XCTAssertEqual(
            try ClipboardSet.decode([0x1A, 0x68, 0x65, 0x6C, 0x6C, 0x6F]).text,
            "hello"
        )
        XCTAssertEqual(
            try ClipboardAnnounce.decode(
                [0x1B, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
            ).text,
            "hello"
        )
        // Multi-byte UTF-8 by hand: "é" = C3 A9, "🙂" = F0 9F 99 82.
        XCTAssertEqual(
            try ClipboardSet(text: "é🙂").encode(),
            [0x1A, 0xC3, 0xA9, 0xF0, 0x9F, 0x99, 0x82]
        )
        XCTAssertEqual(
            try ClipboardSet.decode(
                [0x1A, 0xC3, 0xA9, 0xF0, 0x9F, 0x99, 0x82]
            ).text,
            "é🙂"
        )
    }

    func testCeilingIsLegalToTheByteAndOneOverRejects() throws {
        let atCeiling = String(
            repeating: "a", count: ClipboardWire.maxTextByteCount
        )
        let encoded = try ClipboardSet(text: atCeiling).encode()
        XCTAssertEqual(encoded.count, 1 + ClipboardWire.maxTextByteCount)
        XCTAssertEqual(try ClipboardSet.decode(encoded).text, atCeiling)

        let oneOver = atCeiling + "a"
        XCTAssertThrowsError(try ClipboardSet(text: oneOver).encode()) {
            XCTAssertEqual(
                $0 as? ClipboardMessageError,
                .textOverBudget(ClipboardWire.maxTextByteCount + 1)
            )
        }
        XCTAssertThrowsError(try ClipboardSet.decode(
            [0x1A] + [UInt8](repeating: 0x61,
                             count: ClipboardWire.maxTextByteCount + 1)
        )) {
            XCTAssertEqual(
                $0 as? ClipboardMessageError,
                .textOverBudget(ClipboardWire.maxTextByteCount + 1)
            )
        }
    }

    func testHostileClipboardBytesRejectAndNeverTrap() {
        // Empty payload, empty text.
        XCTAssertThrowsError(try ClipboardSet.decode([])) {
            XCTAssertEqual($0 as? ClipboardMessageError, .truncatedMessage)
        }
        XCTAssertThrowsError(try ClipboardSet.decode([0x1A])) {
            XCTAssertEqual($0 as? ClipboardMessageError, .emptyText)
        }
        XCTAssertThrowsError(try ClipboardAnnounce.decode([0x1B])) {
            XCTAssertEqual($0 as? ClipboardMessageError, .emptyText)
        }
        XCTAssertThrowsError(try ClipboardSet(text: "").encode()) {
            XCTAssertEqual($0 as? ClipboardMessageError, .emptyText)
        }
        // Cross-type and foreign-type.
        XCTAssertThrowsError(try ClipboardSet.decode([0x1B, 0x61])) {
            XCTAssertEqual(
                $0 as? ClipboardMessageError, .unexpectedType(0x1B)
            )
        }
        XCTAssertThrowsError(try ClipboardAnnounce.decode([0x1A, 0x61])) {
            XCTAssertEqual(
                $0 as? ClipboardMessageError, .unexpectedType(0x1A)
            )
        }
        XCTAssertThrowsError(try ClipboardSet.decode([0x7F, 0x61])) {
            XCTAssertEqual(
                $0 as? ClipboardMessageError, .unexpectedType(0x7F)
            )
        }
        // Invalid UTF-8: a lone invalid byte, a truncated 2-byte
        // sequence, an overlong encoding (C0 AF), and a lone
        // continuation byte — reject, never replace.
        for hostile: [UInt8] in [
            [0x1A, 0xFF],
            [0x1A, 0x61, 0xC3],
            [0x1A, 0xC0, 0xAF],
            [0x1A, 0x80],
        ] {
            XCTAssertThrowsError(try ClipboardSet.decode(hostile)) {
                XCTAssertEqual($0 as? ClipboardMessageError, .invalidUtf8)
            }
        }
    }

    // MARK: Key 10 on the forward-compat spine, zero frozen bytes

    func testCapabilityKeyRidesTheSpineWithoutMovingFrozenBytes() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        // wireDefault is an 8-entry map — the frozen v1 shape.
        XCTAssertEqual(base.first, 0xA8)

        // The declaration is EXACTLY the frozen bytes plus one appended
        // entry: map(9) head + trailing `0A F5` (key 10 sorts last in
        // RFC 8949 bytewise order among keys 1–10). Nothing between
        // moves — the "no frozen bytes" claim as data.
        var expected = base
        expected[0] = 0xA9
        expected += [0x0A, 0xF5]
        let declared = Capabilities.wireDefault.declaringClipboardText()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        // Reads back as itself through the v1 decoder: key 10 lands in
        // unknownEntries and the typed accessor sees it.
        let decoded = try Capabilities.decodeCbor(declared.encodeCbor())
        XCTAssertTrue(decoded.clipboardText)
        XCTAssertEqual(decoded, declared)
        XCTAssertEqual(decoded.unknownEntries.count, 1)
        XCTAssertFalse(Capabilities.wireDefault.clipboardText)

        // Idempotent declaration; canonical through the 0x0F codec.
        XCTAssertEqual(declared.declaringClipboardText(), declared)
        let message = try CapabilityDeclaration(capabilities: declared).encode()
        XCTAssertEqual(
            try CapabilityDeclaration.decode(message).capabilities, declared
        )

        // Keys 9 and 10 compose in either construction order — the
        // CBOR encoder owns canonical key order, so both spellings
        // yield ONE byte image: map head 0xAA, `09 F5 0A F5` trailing.
        var both = base
        both[0] = 0xAA
        both += [0x09, 0xF5, 0x0A, 0xF5]
        XCTAssertEqual(
            try Capabilities.wireDefault
                .declaringHostAudioRouting().declaringClipboardText()
                .encodeCbor(),
            both
        )
        XCTAssertEqual(
            try Capabilities.wireDefault
                .declaringClipboardText().declaringHostAudioRouting()
                .encodeCbor(),
            both
        )
    }

    func testIntersectionEnablesOnlyOnMutualDeclaration() throws {
        let declared = Capabilities.wireDefault.declaringClipboardText()

        // Both declare → survives, both argument orders.
        XCTAssertTrue(declared.intersecting(declared).clipboardText)

        // One-sided → dropped, both orders.
        XCTAssertFalse(declared.intersecting(.wireDefault).clipboardText)
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).clipboardText
        )

        // A peer declaring key 10 FALSE is not byte-equal to true:
        // absence and refusal are the same posture.
        var refusing = Capabilities.wireDefault
        refusing.unknownEntries.append(CborMapEntry(
            key: .unsigned(CapabilityKey.clipboardText),
            value: .bool(false)
        ))
        XCTAssertFalse(refusing.clipboardText)
        XCTAssertFalse(declared.intersecting(refusing).clipboardText)

        // Keys 9 and 10 intersect independently: one end declares
        // both, the other only key 10 — audio routing drops, the
        // clipboard survives.
        let bothKeys = Capabilities.wireDefault
            .declaringHostAudioRouting().declaringClipboardText()
        let agreed = bothKeys.intersecting(declared)
        XCTAssertTrue(agreed.clipboardText)
        XCTAssertFalse(agreed.hostAudioRouting)
    }

    // MARK: The registry itself

    func testClipboardRegistryNumbersAreThePinnedOnes() {
        // A registry typo here would be a silent wire break on both
        // ends at once (the control-codec pin's rule).
        XCTAssertEqual(CtrlMessageType.clipboardSet, 0x1A)
        XCTAssertEqual(CtrlMessageType.clipboardAnnounce, 0x1B)
        XCTAssertEqual(CapabilityKey.clipboardText, 10)
        XCTAssertEqual(ClipboardWire.maxTextByteCount, 65_536)
    }

    // MARK: The sync book's laws (design doc §5)

    func testBookSuppressesTheEchoAndOnlyTheEcho() {
        var book = ClipboardSyncBook()

        // A genuine local change shares.
        XCTAssertEqual(book.admitLocalChange("mine"), .share)
        book.noteShared("mine")

        // The boomerang law: a remote apply's OS echo is suppressed.
        book.noteRemoteApplied("theirs")
        XCTAssertEqual(book.admitLocalChange("theirs"), .suppressEcho)

        // Consume-once: a deliberate later re-copy of the same text
        // still syncs (the peer's clipboard may have moved on).
        XCTAssertEqual(book.admitLocalChange("theirs"), .share)
    }

    func testBookDedupesRepeatedSharesUntilTheRemoteMovesOn() {
        var book = ClipboardSyncBook()
        XCTAssertEqual(book.admitLocalChange("same"), .share)
        book.noteShared("same")

        // Copying the identical text again says nothing new.
        XCTAssertEqual(book.admitLocalChange("same"), .suppressDuplicate)

        // Once the remote applied something else, the peer's clipboard
        // moved past our last share — re-sharing it is legitimate.
        book.noteRemoteApplied("theirs")
        XCTAssertEqual(book.admitLocalChange("same"), .share)
    }

    func testBookRapidRemoteAppliesEachOweOneSuppression() {
        var book = ClipboardSyncBook()
        // Two applies land before either OS change event fires; the
        // events then arrive in order — both suppressed, exactly once.
        book.noteRemoteApplied("first")
        book.noteRemoteApplied("second")
        XCTAssertEqual(book.admitLocalChange("first"), .suppressEcho)
        XCTAssertEqual(book.admitLocalChange("second"), .suppressEcho)
        XCTAssertEqual(book.admitLocalChange("second"), .share)
    }

    func testBookSharingClearsStaleEchoEntries() {
        var book = ClipboardSyncBook()
        // An apply whose OS event never fired (coalesced away by a
        // fast local copy) must not suppress a deliberate re-copy
        // after the clipboard genuinely moved on.
        book.noteRemoteApplied("theirs")
        XCTAssertEqual(book.admitLocalChange("fresh"), .share)
        book.noteShared("fresh")
        XCTAssertEqual(book.admitLocalChange("theirs"), .share)
    }

    func testBookRingEvictsOldestAtCapacity() {
        var book = ClipboardSyncBook(capacity: 2)
        book.noteRemoteApplied("a")
        book.noteRemoteApplied("b")
        book.noteRemoteApplied("c")
        // "a" was evicted; "b" and "c" still owe their suppressions.
        XCTAssertEqual(book.admitLocalChange("a"), .share)
        XCTAssertEqual(book.admitLocalChange("b"), .suppressEcho)
        XCTAssertEqual(book.admitLocalChange("c"), .suppressEcho)
    }
}
