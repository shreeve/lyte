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

    /// Idle feedback: a beat with nothing new waits for the heartbeat;
    /// an arrival, a ledger change or a queued NACK makes it due at once.
    /// Without the agreement every beat is due.
    func testIdleFeedbackSendsOnlyNewsAndTheHeartbeat() throws {
        var reporter = ClientFeedbackReporter()
        let ledger = ClientFeedbackReporter.Ledger(
            channel: .videoActive, highestSeq: ChannelSeq(rawValue: 3),
            datagrams: 4, duplicates: 0, missing: 0)
        func at(_ ms: UInt64) -> ClientTimestamp {
            ClientTimestamp(microseconds: ms * 1_000)
        }
        func due(_ ledgers: [ClientFeedbackReporter.Ledger], arrivals: Int = 0,
                 idle: Bool = true, _ ms: UInt64) -> Bool {
            reporter.isDue(ledgers: ledgers, arrivalCount: arrivals,
                           idleFeedback: idle, now: at(ms))
        }

        XCTAssertTrue(due([ledger], 0), "the first beat always reports")
        _ = reporter.report(ledgers: [ledger], arrivals: [], now: at(0))
        XCTAssertFalse(due([ledger], 300), "nothing new past the linger: silent")
        XCTAssertFalse(due([ledger], 1_999))
        XCTAssertTrue(due([ledger], 2_000), "the heartbeat")
        XCTAssertTrue(due([ledger], idle: false, 40),
                      "without key 17 every beat reports")
        XCTAssertTrue(due([ledger], arrivals: 1, 40), "an arrival is news")
        var grown = ledger
        grown.datagrams += 1
        XCTAssertTrue(due([grown], 40), "a ledger change is news")
        reporter.enqueueNacks([try entry(9)])
        XCTAssertTrue(due([ledger], 40), "a NACK never waits")
    }

    /// After news the full cadence runs for the linger window, so one
    /// lost report cannot leave the host's send unanswered; then quiet.
    func testIdleFeedbackLingersAfterNews() {
        var reporter = ClientFeedbackReporter()
        let before = ClientFeedbackReporter.Ledger(
            channel: .videoActive, highestSeq: ChannelSeq(rawValue: 3),
            datagrams: 4, duplicates: 0, missing: 0)
        var after = before
        after.datagrams += 3
        func at(_ ms: UInt64) -> ClientTimestamp {
            ClientTimestamp(microseconds: ms * 1_000)
        }
        _ = reporter.report(ledgers: [before], arrivals: [], now: at(0))
        _ = reporter.report(ledgers: [after], arrivals: [], now: at(1_000))
        for ms in stride(from: UInt64(1_040), through: 1_240, by: 40) {
            XCTAssertTrue(reporter.isDue(
                ledgers: [after], arrivalCount: 0, idleFeedback: true,
                now: at(ms)), "lingering at +\(ms - 1_000) ms")
            _ = reporter.report(ledgers: [after], arrivals: [], now: at(ms))
        }
        XCTAssertFalse(reporter.isDue(
            ledgers: [after], arrivalCount: 0, idleFeedback: true,
            now: at(1_280)), "past the linger window the stream is quiet")
    }
}
