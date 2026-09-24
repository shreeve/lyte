@testable import LyteTransport
import LyteWire
import XCTest

final class VideoQualityWindowTests: XCTestCase {
    /// A long 60 fps run keeps exactly the last five seconds live, and
    /// the dead prefix is compacted rather than retained forever.
    func testLongRunKeepsFiveSecondsAndCompacts() throws {
        var window = VideoQualityWindow()
        var now = ClientTimestamp(microseconds: 0)
        for index in 0..<3_600 {
            now = ClientTimestamp(microseconds: UInt64(index) * 16_667)
            window.record(bytes: 1_000 + index % 7, now: now)
        }
        XCTAssertEqual(window.liveCount, 300)
        XCTAssertLessThanOrEqual(window.storedCount, 2 * 300 + 2)
        let quality = try XCTUnwrap(window.snapshot(now: now))
        XCTAssertEqual(quality.framesPerSecond, 60, accuracy: 0.5)
        XCTAssertEqual(quality.frameBytesMax, 1_006)
        XCTAssertNil(window.snapshot(
            now: now.advanced(byMicroseconds: 5_000_001)))
        XCTAssertEqual(window.liveCount, 0)
    }
}
