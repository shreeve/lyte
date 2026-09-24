import HostWire
import LyteWire
import XCTest

/// The host leaf outlives sessions, so every selection-owner change is
/// judged against whether a session is live now: a copy made while no
/// client is connected is never read, and never reaches the next one.
final class HostSelectionChangeTests: XCTestCase {
    private let text = [ClipboardTextMime.utf8, "image/png"]

    func testACopyOutsideASessionIsNeverRead() {
        for isOwner in [false, true] {
            for images in [false, true] {
                XCTAssertEqual(HostSelectionChange.judge(
                    sessionLive: false, sessionIsOwner: isOwner,
                    offered: text, imagesEnabled: images),
                    .ignoreOutsideSession)
            }
        }
    }

    func testALiveSessionReadsTextFirstAndImagesOnlyOnTheImagesTier() {
        XCTAssertEqual(HostSelectionChange.judge(
            sessionLive: true, sessionIsOwner: false,
            offered: text, imagesEnabled: true),
            .read(mime: ClipboardTextMime.utf8, image: false))
        XCTAssertEqual(HostSelectionChange.judge(
            sessionLive: true, sessionIsOwner: false,
            offered: ["image/png"], imagesEnabled: true),
            .read(mime: "image/png", image: true))
        XCTAssertEqual(HostSelectionChange.judge(
            sessionLive: true, sessionIsOwner: false,
            offered: ["image/png"], imagesEnabled: false),
            .ignoreFlavor)
        XCTAssertEqual(HostSelectionChange.judge(
            sessionLive: true, sessionIsOwner: false,
            offered: [], imagesEnabled: true),
            .ignoreFlavor)
    }

    func testOurOwnSelectionIsReportedAsTheApplysEcho() {
        XCTAssertEqual(HostSelectionChange.judge(
            sessionLive: true, sessionIsOwner: true,
            offered: text, imagesEnabled: false),
            .reportOwnEcho)
    }
}
