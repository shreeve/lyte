import HostCore
import XCTest

final class HeldInputBookTests: XCTestCase {
    /// A long silence takes only the keys a compositor autorepeats; the
    /// modifiers and pointer buttons stay held until everything goes.
    func testSilenceReleasesRepeatingKeysAndCloseReleasesTheRest() {
        var book = HeldInputBook()
        let keyW: UInt32 = 17, keyA: UInt32 = 30
        let leftShift: UInt32 = 42, rightMeta: UInt32 = 126
        let leftButton: UInt32 = 0x110
        for key in [keyW, keyA, leftShift, rightMeta] {
            book.noteKey(key, pressed: true)
        }
        book.noteButton(leftButton, pressed: true)

        XCTAssertEqual(book.takeReleases(.autorepeatingKeys), [keyW, keyA])
        XCTAssertEqual(book.takeReleases(.autorepeatingKeys), [],
                       "released once")
        XCTAssertEqual(book.keys, [leftShift, rightMeta])
        XCTAssertEqual(book.buttons, [leftButton])

        XCTAssertEqual(book.takeReleases(.everything),
                       [leftShift, rightMeta, leftButton])
        XCTAssertTrue(book.isEmpty)
    }

    /// A key the client released is not released again.
    func testAReleasedKeyIsForgotten() {
        var book = HeldInputBook()
        book.noteKey(30, pressed: true)
        book.noteKey(30, pressed: false)
        book.noteButton(0x111, pressed: true)
        book.noteButton(0x111, pressed: false)
        XCTAssertTrue(book.isEmpty)
        XCTAssertEqual(book.takeReleases(.everything), [])
    }
}
