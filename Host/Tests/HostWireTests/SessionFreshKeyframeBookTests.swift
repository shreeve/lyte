import XCTest
import Foundation
import HostWire

final class SessionFreshKeyframeBookTests: XCTestCase {
    func testSessionKeepsOneNamedFreshKeyframeOwner() throws {
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
            "private var freshKeyframes = SessionFreshKeyframeBook()"
        ))
        for retiredLatch in [
            "clientKeyframePending",
            "machineIdrPacing",
            "unprotectableKeyframePending",
            "staleNackKeyframePending",
            "fallPurgeKeyframePending",
            "lastUnknownFrame",
        ] {
            XCTAssertFalse(
                session.contains(retiredLatch),
                "parallel keyframe latch returned: \(retiredLatch)"
            )
        }
    }

    func testAllCausesCoalesceInStableNameOrder() {
        var book = SessionFreshKeyframeBook()
        book.arm(.fallPurge)
        book.arm([.machineRecovery, .pathPromotion, .clientRequest])
        book.arm([.staleNackArm, .unprotectableDrop, .machineWake])

        XCTAssertEqual(book.pending, [
            .pathPromotion,
            .clientRequest,
            .machineWake,
            .machineRecovery,
            .staleNackArm,
            .unprotectableDrop,
            .fallPurge,
        ])
        XCTAssertEqual(book.pending.names, [
            "path-promotion",
            "client-request",
            "wake",
            "recovery",
            "stale-nack",
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

    func testUnknownFramePressureUsesTheExactIntervalBoundary() {
        var book = SessionFreshKeyframeBook()

        XCTAssertTrue(book.armStaleNack(
            unknownFrame: true, now: 10, minimumUnknownFrameInterval: 100
        ))
        XCTAssertFalse(book.armStaleNack(
            unknownFrame: true, now: 109, minimumUnknownFrameInterval: 100
        ))
        XCTAssertTrue(book.armStaleNack(
            unknownFrame: true, now: 110, minimumUnknownFrameInterval: 100
        ))
        XCTAssertEqual(book.pending, [.staleNackArm])
    }

    func testTakingDemandDoesNotResetUnknownFramePressureWindow() {
        var book = SessionFreshKeyframeBook()
        XCTAssertTrue(book.armStaleNack(
            unknownFrame: true, now: 1_000,
            minimumUnknownFrameInterval: 500
        ))
        XCTAssertEqual(book.take(), [.staleNackArm])
        XCTAssertFalse(book.armStaleNack(
            unknownFrame: true, now: 1_499,
            minimumUnknownFrameInterval: 500
        ))
        XCTAssertTrue(book.pending.isEmpty)
    }

    func testUnknownFramePressureMeasuresAcrossClockWrap() {
        var book = SessionFreshKeyframeBook()
        XCTAssertTrue(book.armStaleNack(
            unknownFrame: true, now: .max - 50,
            minimumUnknownFrameInterval: 100
        ))
        XCTAssertFalse(book.armStaleNack(
            unknownFrame: true, now: 48,
            minimumUnknownFrameInterval: 100
        ))
        XCTAssertTrue(book.armStaleNack(
            unknownFrame: true, now: 49,
            minimumUnknownFrameInterval: 100
        ))
    }

    func testKnownStaleNacksRemainUnthrottledAndDoNotMoveUnknownWindow() {
        var book = SessionFreshKeyframeBook()
        XCTAssertTrue(book.armStaleNack(
            unknownFrame: true, now: 100, minimumUnknownFrameInterval: 1_000
        ))

        for now in 101...110 {
            XCTAssertTrue(book.armStaleNack(
                unknownFrame: false,
                now: UInt64(now),
                minimumUnknownFrameInterval: 1_000
            ))
        }
        XCTAssertFalse(book.armStaleNack(
            unknownFrame: true, now: 1_099,
            minimumUnknownFrameInterval: 1_000
        ))
        XCTAssertTrue(book.armStaleNack(
            unknownFrame: true, now: 1_100,
            minimumUnknownFrameInterval: 1_000
        ))
    }
}
