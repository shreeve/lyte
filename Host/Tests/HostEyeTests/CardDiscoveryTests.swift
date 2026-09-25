@testable import HostEye
import XCTest

/// Without --drm-device the host captures the first card, in numeric
/// order, whose primary plane scans out; a firmware framebuffer card with
/// nothing on it is passed over.
final class CardDiscoveryTests: XCTestCase {
    private let entries = [
        "by-path", "card10", "renderD128", "card9", "card1", "card0",
    ]

    func testTheFirstCardScanningOutWinsInNumericOrder() {
        var probed: [String] = []
        let card = DirectScreenSource.discoverCard(
            entries: entries, in: "/dev/dri"
        ) { path in
            probed.append(path)
            return path == "/dev/dri/card9" || path == "/dev/dri/card10"
        }
        XCTAssertEqual(card, "/dev/dri/card9")
        XCTAssertEqual(
            probed, ["/dev/dri/card0", "/dev/dri/card1", "/dev/dri/card9"],
            "render nodes and non-card entries are never opened")
    }

    func testNoCardScanningOutFindsNone() {
        XCTAssertNil(DirectScreenSource.discoverCard(
            entries: entries, in: "/dev/dri") { _ in false })
        XCTAssertNil(DirectScreenSource.discoverCard(
            entries: [], in: "/dev/dri") { _ in true })
    }
}
