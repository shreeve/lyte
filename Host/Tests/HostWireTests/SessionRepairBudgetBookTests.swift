import XCTest
import Foundation
import HostWire
import LyteWire

final class SessionRepairBudgetBookTests: XCTestCase {
    private func report(
        received: UInt32 = 0,
        missing: UInt32 = 0,
        channel: ChannelId = .videoActive
    ) -> FeedbackReport {
        FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 0),
            channels: [FeedbackReport.ChannelStats(
                channel: channel,
                highestSeq: ChannelSeq(rawValue: 0),
                received: received,
                missing: missing,
                duplicates: 0
            )],
            nacks: []
        )
    }

    func testSessionKeepsOneNamedRepairBudgetOwner() throws {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        let packageRoot = components.joined(separator: "/")
        let session = try String(contentsOfFile:
            packageRoot + "/Sources/HostWire/Session.swift",
            encoding: .utf8
        )

        XCTAssertTrue(session.contains(
            "private var repairBudget = SessionRepairBudgetBook()"
        ))
        for retiredField in [
            "feedbackCadenceEwmaNS",
            "lastFeedbackParsedAtNS",
            "clientGlassEvidence",
            "openingIdrShardTotal",
            "openingExemptAttempts",
            "openingExemptBytes",
        ] {
            XCTAssertFalse(
                session.contains(retiredField),
                "parallel repair-budget state returned: \(retiredField)"
            )
        }
    }

    func testCadenceSamplesClampThenEwmaAndDeriveTheBudget() {
        var book = SessionRepairBudgetBook()
        XCTAssertEqual(book.freezeBudgetNanoseconds(
            override: nil,
            cadenceMultiplier: 1.5,
            jitterAllowanceNanoseconds: 15_000_000
        ), 90_000_000)

        book.noteFeedback(report(), now: 0)
        XCTAssertNil(book.observedFeedbackCadenceNanoseconds)
        book.noteFeedback(report(), now: 10_000_000)
        XCTAssertEqual(book.observedFeedbackCadenceNanoseconds, 25_000_000)
        book.noteFeedback(report(), now: 100_000_000)
        XCTAssertEqual(book.observedFeedbackCadenceNanoseconds, 28_125_000)
        XCTAssertEqual(book.freezeBudgetNanoseconds(
            override: nil,
            cadenceMultiplier: 2,
            jitterAllowanceNanoseconds: 5_000_000
        ), 61_250_000)
        XCTAssertEqual(book.freezeBudgetNanoseconds(
            override: 123,
            cadenceMultiplier: 2,
            jitterAllowanceNanoseconds: 5_000_000
        ), 123)
    }

    func testOpeningGeometryIsFirstOnlyAndGlassEvidenceIsSticky() {
        var book = SessionRepairBudgetBook()
        book.noteOpeningIdr(shardCount: 12)
        book.noteOpeningIdr(shardCount: 99)
        XCTAssertEqual(book.openingIdrShardCount, 12)

        book.noteFeedback(report(received: 12, missing: 1), now: 0)
        XCTAssertFalse(book.hasClientGlassEvidence)
        book.noteFeedback(
            report(received: 12, channel: .audio), now: 40_000_000
        )
        XCTAssertFalse(book.hasClientGlassEvidence)
        book.noteFeedback(report(received: 11), now: 80_000_000)
        XCTAssertFalse(book.hasClientGlassEvidence)
        book.noteFeedback(report(received: 12), now: 120_000_000)
        XCTAssertTrue(book.hasClientGlassEvidence)
        book.noteFeedback(report(received: 0, missing: 12), now: 160_000_000)
        XCTAssertTrue(book.hasClientGlassEvidence)
    }

    func testOpeningExemptionRequiresTheIdrAndHonorsBothBounds() {
        var book = SessionRepairBudgetBook()
        XCTAssertFalse(book.openingExemptionAvailable(
            lastIdrMatches: false, repairBytes: 40,
            maxAttempts: 2, maxBytes: 100
        ))
        XCTAssertTrue(book.openingExemptionAvailable(
            lastIdrMatches: true, repairBytes: 40,
            maxAttempts: 2, maxBytes: 100
        ))
        book.commitOpeningExemptRepair(bytes: 40)
        XCTAssertTrue(book.openingExemptionAvailable(
            lastIdrMatches: true, repairBytes: 60,
            maxAttempts: 2, maxBytes: 100
        ))
        book.commitOpeningExemptRepair(bytes: 60)
        XCTAssertFalse(book.openingExemptionAvailable(
            lastIdrMatches: true, repairBytes: 0,
            maxAttempts: 2, maxBytes: 100
        ))

        var byteBound = SessionRepairBudgetBook()
        byteBound.commitOpeningExemptRepair(bytes: 40)
        XCTAssertFalse(byteBound.openingExemptionAvailable(
            lastIdrMatches: true, repairBytes: 61,
            maxAttempts: 3, maxBytes: 100
        ))
    }
}
