import XCTest
import Foundation
@testable import HostWire
import LyteWire

final class SessionIdleHandoffBookTests: XCTestCase {
    private let frame = IdleFrame(
        frame: FrameNumber(rawValue: 7),
        captureTimestampMicroseconds: 42_000,
        annexB: [0, 0, 0, 1, 0x26, 0x01, 0xA5]
    )

    func testSessionKeepsOneNamedIdleHandoffOwner() throws {
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
            "private var idleHandoff = SessionIdleHandoffBook()"
        ))
        for retired in [
            "convergedFrame", "lastDamageNoteAt", "pendingIdleFlipAt",
            "finalFrameGroup", "nextOneShotGroup",
        ] {
            XCTAssertFalse(session.contains(retired), retired)
        }
        XCTAssertTrue(session.contains("idleHandoff.noteDamage"))
        XCTAssertTrue(session.contains("idleHandoff.noteConverged"))
        XCTAssertTrue(session.contains("idleHandoff.takeDueHandoff"))
        XCTAssertTrue(session.contains("idleHandoff.acknowledge"))
    }

    func testPreparedSendRetriesExactlyAndCommitsOnlyAfterAdmission() throws {
        var book = SessionIdleHandoffBook()
        XCTAssertTrue(book.noteConverged(
            frame, now: 100, quietWindowNanoseconds: 1_000
        ))

        let first = try XCTUnwrap(book.pendingFinalFrameSend())
        let retry = try XCTUnwrap(book.pendingFinalFrameSend())
        XCTAssertEqual(first.frame, retry.frame)
        XCTAssertEqual(first.group, retry.group,
                       "refused admission consumes nothing")
        XCTAssertEqual(first.group, ArqGroupId(rawValue: 1))
        XCTAssertEqual(try IdleFrame.decode(first.frame.encode()), frame)
        XCTAssertNil(book.finalFrameGroup)

        XCTAssertEqual(book.commitFinalFrameSent(), first.group)
        XCTAssertEqual(book.finalFrameGroup, first.group)
        XCTAssertFalse(book.acknowledge(ArqGroupId(rawValue: 99)))
        XCTAssertEqual(book.finalFrameGroup, first.group)
        XCTAssertTrue(book.acknowledge(first.group))
        XCTAssertNil(book.finalFrameGroup)
        XCTAssertNil(book.pendingFinalFrameSend())
    }

    func testDamageQuietWindowReleasesOnceAtItsBoundary() {
        var book = SessionIdleHandoffBook()
        book.noteDamage(now: 100)
        XCTAssertFalse(book.noteConverged(
            frame, now: 150, quietWindowNanoseconds: 100
        ))
        XCTAssertEqual(book.lastDamageAtNanoseconds, 100)
        XCTAssertEqual(book.nextDeadlineNanoseconds, 200)
        XCTAssertFalse(book.takeDueHandoff(now: 199))
        XCTAssertTrue(book.takeDueHandoff(now: 200))
        XCTAssertNil(book.nextDeadlineNanoseconds)
        XCTAssertFalse(book.takeDueHandoff(now: 201))
        XCTAssertNotNil(book.pendingFinalFrameSend())
    }

    func testFreshDamageAbortsPendingAndInFlightHandoffs() throws {
        var book = SessionIdleHandoffBook()
        book.noteDamage(now: 100)
        XCTAssertFalse(book.noteConverged(
            frame, now: 150, quietWindowNanoseconds: 100
        ))
        book.noteDamage(now: 175)
        XCTAssertNil(book.nextDeadlineNanoseconds)
        XCTAssertNil(book.pendingFinalFrameSend())

        XCTAssertTrue(book.noteConverged(
            frame, now: 300, quietWindowNanoseconds: 100
        ))
        let send = try XCTUnwrap(book.pendingFinalFrameSend())
        XCTAssertEqual(book.commitFinalFrameSent(), send.group)
        book.noteDamage(now: 301)
        XCTAssertNil(book.finalFrameGroup)
        XCTAssertNil(book.pendingFinalFrameSend())
        XCTAssertFalse(book.acknowledge(send.group), "the late ack is inert")
    }

    func testOneShotGroupWrapSkipsZero() throws {
        var book = SessionIdleHandoffBook(nextOneShotGroup: .max)
        XCTAssertTrue(book.noteConverged(
            frame, now: 0, quietWindowNanoseconds: 0
        ))
        let last = try XCTUnwrap(book.pendingFinalFrameSend())
        XCTAssertEqual(last.group, ArqGroupId(rawValue: .max))
        XCTAssertEqual(book.commitFinalFrameSent(), last.group)
        XCTAssertTrue(book.acknowledge(last.group))

        XCTAssertTrue(book.noteConverged(
            frame, now: 1, quietWindowNanoseconds: 0
        ))
        XCTAssertEqual(
            book.pendingFinalFrameSend()?.group,
            ArqGroupId(rawValue: 1)
        )
    }
}
