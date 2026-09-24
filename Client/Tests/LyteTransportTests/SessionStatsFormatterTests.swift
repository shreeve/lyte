import LyteClientCore
import LyteTransport
import LyteWire
import XCTest

/// The stats rows' loss wording over real demux books.
final class SessionStatsFormatterTests: XCTestCase {
    func testLossCountsReorderedArrivalsOnce() {
        // seq 0, 2, 1 (late), 4: one datagram (3) is really lost.
        var tracker = SeqGapTracker()
        for seq in [0, 2, 1, 4] as [UInt16] {
            _ = tracker.record(ChannelSeq(rawValue: seq))
        }
        XCTAssertEqual(tracker.lateFilled, 1)
        XCTAssertEqual(
            SessionStatsFormatter.lossSummary(
                lost: tracker.datagramsMissing, received: tracker.received),
            "lost 1 of 5 host packets (20.000%)")
    }

    func testCleanLinkSaysZeroWithTheDenominator() {
        XCTAssertEqual(
            SessionStatsFormatter.lossSummary(lost: 0, received: 41_200),
            "lost 0 of 41.2k host packets")
    }

    func testLossBeyondThirtyTwoBitsPrintsExactly() {
        XCTAssertEqual(
            SessionStatsFormatter.lossSummary(lost: 5_000_000_000, received: 5_000_000_000),
            "lost 5000000000 of 10000.00M host packets (50.000%)")
    }
}
