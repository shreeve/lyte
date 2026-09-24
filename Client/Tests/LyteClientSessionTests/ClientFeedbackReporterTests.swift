import LyteClientSession
import LyteWire
import XCTest

final class ClientFeedbackReporterTests: XCTestCase {
    private func entry(_ frame: UInt32) throws -> FeedbackReport.NackEntry {
        try FeedbackReport.NackEntry(
            frame: FrameNumber(rawValue: frame), missingShards: [1])
    }

    /// Past the queue cap the oldest entries go (closest to stale); the
    /// rest ride successive reports, at most the wire bound each.
    func testNackQueueDropsOldestAndSpillsAcrossReports() throws {
        var reporter = ClientFeedbackReporter()
        let cap = ClientFeedbackReporter.pendingNackCap
        reporter.enqueueNacks(try (0..<UInt32(cap + 3)).map(entry))
        var carried: [UInt32] = []
        for beat in 0..<10 {
            let report = reporter.report(
                ledgers: [], arrivals: [],
                now: ClientTimestamp(microseconds: UInt64(beat)))
            XCTAssertLessThanOrEqual(
                report.nacks.count, FeedbackBounds.maxNackEntries)
            carried += report.nacks.map(\.frame.rawValue)
        }
        XCTAssertEqual(carried, Array(3..<UInt32(cap + 3)))
        XCTAssertEqual(reporter.stats.nackEntriesSent, UInt64(cap))
    }

    /// Ledgers become wire blocks; an arrival past the u24 delta field is
    /// dropped and counted rather than encoded wrong.
    func testLedgersAndDispersionShapeTheReport() throws {
        var reporter = ClientFeedbackReporter()
        let ledger = ClientFeedbackReporter.Ledger(
            channel: .videoActive, highestSeq: ChannelSeq(rawValue: 40),
            datagrams: 41, duplicates: 1, missing: 2)
        let far = UInt64(FeedbackBounds.maxArrivalDeltaMicroseconds) + 1
        let arrivals = [UInt64(0), 250, far].enumerated().map {
            ClientFeedbackReporter.Arrival(
                channel: .videoActive,
                seq: ChannelSeq(rawValue: UInt16($0.offset)),
                arrivalMicroseconds: 1_000 + $0.element)
        }
        let report = reporter.report(
            ledgers: [ledger], arrivals: arrivals,
            now: ClientTimestamp(microseconds: 9_000))
        XCTAssertEqual(report.channels.map(\.received), [40])
        XCTAssertEqual(report.channels.map(\.missing), [2])
        XCTAssertEqual(report.dispersion?.samples.map(\.arrivalDeltaMicroseconds),
                       [0, 250])
        XCTAssertEqual(reporter.stats.dispersionSamplesDecimated, 1)
        XCTAssertNoThrow(try report.encode())
    }
}
