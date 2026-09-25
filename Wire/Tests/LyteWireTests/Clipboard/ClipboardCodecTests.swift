import XCTest
import LyteWire

// The clipboard vocabulary's anchors (design doc
// docs/decisions/20260722-231500-lyte-clipboard.md): hand-computed bytes for the
// 0x1A/0x1B pair (the vector file never grades its own homework), the
// registry numbers, and the loop-prevention book's laws — including the
// proof obligation that a set must not boomerang.

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
    }

    func testEncodeRefusesWhatDecodeRejects() {
        assertThrows(ClipboardMessageError.emptyText) {
            try ClipboardSet(text: "").encode()
        }
        let oneOver = String(
            repeating: "a", count: ClipboardWire.maxTextByteCount + 1
        )
        assertThrows(
            ClipboardMessageError.textOverBudget(ClipboardWire.maxTextByteCount + 1)
        ) {
            try ClipboardSet(text: oneOver).encode()
        }
    }

    /// Malformed UTF-8 rejects, never replaces: the overlong and
    /// lone-continuation forms clipboard-v1.json does not carry.
    func testMalformedUtf8Rejects() {
        for hostile: [UInt8] in [[0x1A, 0xC0, 0xAF], [0x1A, 0x80]] {
            assertThrows(ClipboardMessageError.invalidUtf8) {
                try ClipboardSet.decode(hostile)
            }
        }
    }

    // MARK: The registry itself

    func testClipboardRegistryNumbersAreThePinnedOnes() {
        // A registry typo here would be a silent wire break on both
        // ends at once (the control-codec pin's rule).
        XCTAssertEqual(CtrlMessageType.clipboardSet, 0x1A)
        XCTAssertEqual(CtrlMessageType.clipboardAnnounce, 0x1B)
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
