import XCTest
import Foundation
import HostWire

final class SessionFreshKeyframeBookTests: XCTestCase {
    func testAllCausesCoalesceInStableNameOrder() {
        var book = SessionFreshKeyframeBook()
        book.arm(.fallPurge)
        book.arm([.machineRecovery, .pathPromotion, .clientRequest])
        book.arm([.unprotectableDrop, .machineWake])

        XCTAssertEqual(book.pending, [
            .pathPromotion,
            .clientRequest,
            .machineWake,
            .machineRecovery,
            .unprotectableDrop,
            .fallPurge,
        ])
        XCTAssertEqual(book.pending.names, [
            "path-promotion",
            "client-request",
            "wake",
            "recovery",
            "unprotectable",
            "fall-purge",
        ])
    }

    func testDuplicateArmsCoalesceAndTakeClearsExactlyOnce() {
        var book = SessionFreshKeyframeBook()
        XCTAssertTrue(book.take().isEmpty)

        book.arm(.clientRequest)
        book.arm(.clientRequest)
        book.arm(.fallPurge)

        XCTAssertEqual(book.take(), [.clientRequest, .fallPurge])
        XCTAssertTrue(book.pending.isEmpty)
        XCTAssertTrue(book.take().isEmpty)
    }

    func testDemandTelemetryCountsFramesAndEveryCoalescedCause() {
        var counts = FreshKeyframeDemandCounts()
        counts.record([])
        counts.record([.clientRequest, .unprotectableDrop])
        counts.record([.machineRecovery, .fallPurge])

        XCTAssertEqual(counts.demands, 2)
        XCTAssertEqual(counts.clientRequests, 1)
        XCTAssertEqual(counts.machineRecoveries, 1)
        XCTAssertEqual(counts.fallPurges, 1)
        XCTAssertEqual(counts.pathPromotions, 0)
        XCTAssertEqual(counts.machineWakes, 0)
        XCTAssertEqual(counts.unprotectableDrops, 1)
    }

}
