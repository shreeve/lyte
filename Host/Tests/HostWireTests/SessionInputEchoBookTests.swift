import XCTest
import Foundation
import HostWire
import LyteWire

final class SessionInputEchoBookTests: XCTestCase {
    func testSessionDelegatesInputEvidenceToTheNamedOwner() throws {
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
            "private var inputEchoBook = SessionInputEchoBook()"
        ))
        for retiredOwnerSpelling in [
            "private(set) var lastInputSeq",
            "private var pendingEchoTuples",
            "pendingEchoTuples.append",
            "pendingEchoTuples.removeFirst",
        ] {
            XCTAssertFalse(
                session.contains(retiredOwnerSpelling),
                "input-echo policy returned to Session: \(retiredOwnerSpelling)"
            )
        }
    }

    func testLatestInjectedSequenceAndTupleOrderShareOneBook() {
        var book = SessionInputEchoBook()
        XCTAssertNil(book.lastInjectedSequence)
        XCTAssertNil(book.nextMessage())

        book.noteInjected(
            seq: 41,
            receivedAtMicroseconds: 1_000,
            injectedAtMicroseconds: 1_300
        )
        book.noteInjected(
            seq: 42,
            receivedAtMicroseconds: 2_000,
            injectedAtMicroseconds: 2_400
        )

        XCTAssertEqual(book.lastInjectedSequence, 42)
        XCTAssertEqual(book.pendingTupleCount, 2)
        XCTAssertEqual(book.nextMessage()?.tuples, [
            InputEchoTuple(
                seq: 41,
                receivedMicroseconds: 1_000,
                injectedMicroseconds: 1_300
            ),
            InputEchoTuple(
                seq: 42,
                receivedMicroseconds: 2_000,
                injectedMicroseconds: 2_400
            ),
        ])
    }

    func testMessagesBatchAtTheWireCeilingAndCommitInOrder() throws {
        var book = SessionInputEchoBook()
        for seq in 0..<40 {
            book.noteInjected(
                seq: UInt32(seq),
                receivedAtMicroseconds: UInt64(seq),
                injectedAtMicroseconds: UInt64(seq + 100)
            )
        }

        let first = try XCTUnwrap(book.nextMessage())
        XCTAssertEqual(first.tuples.count, InputEcho.maxTupleCount)
        XCTAssertEqual(first.tuples.map(\.seq), Array(0..<32).map(UInt32.init))
        XCTAssertEqual(book.commitSent(first), 32)

        let second = try XCTUnwrap(book.nextMessage())
        XCTAssertEqual(second.tuples.map(\.seq), Array(32..<40).map(UInt32.init))
        XCTAssertEqual(book.commitSent(second), 8)
        XCTAssertEqual(book.pendingTupleCount, 0)
        XCTAssertNil(book.nextMessage())
        XCTAssertEqual(book.lastInjectedSequence, 39)
    }

    func testRefusedSendLeavesTheExactMessagePending() throws {
        var book = SessionInputEchoBook()
        book.noteInjected(
            seq: 7,
            receivedAtMicroseconds: 11,
            injectedAtMicroseconds: 12
        )

        let refused = try XCTUnwrap(book.nextMessage())
        XCTAssertEqual(book.pendingTupleCount, 1)
        XCTAssertEqual(book.nextMessage(), refused)

        XCTAssertEqual(book.commitSent(refused), 1)
        XCTAssertNil(book.nextMessage())
    }
}
