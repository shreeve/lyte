import XCTest
import Foundation
@testable import HostCore

// The beat book's laws: a clean 60 Hz flip train books zero skips;
// a gap past 1.5 beats is a skip; the doorbell's own cadence names
// the author (watching → source, blind → loop); stillness is a
// quiet desktop, never a skip.

final class CaptureBeatBookTests: XCTestCase {

    private let beat: UInt64 = 16_667

    func testBeatBookCountAloneOwnsSkipDiagnosticLimit() throws {
        let hostRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: hostRoot
                .appendingPathComponent("Sources/lyte-host/DirectEyeLeg.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("if beatBook.skips <= 40"))
        XCTAssertFalse(source.contains("beatSkipLinesPrinted"))
    }

    /// Drives polls every millisecond from `from` up to `to`, then
    /// the flip-detecting poll at `to`.
    private func pollThrough(
        _ book: inout CaptureBeatBook, from: UInt64, to: UInt64
    ) {
        var t = from
        while t < to {
            t += 1_000
            book.notePoll(nowMicroseconds: min(t, to))
        }
    }

    func testCleanFlipTrainBooksNoSkips() {
        var book = CaptureBeatBook()
        var now: UInt64 = 1_000_000
        book.notePoll(nowMicroseconds: now)
        XCTAssertNil(book.noteFlip(nowMicroseconds: now))
        for _ in 0..<120 {
            let next = now + beat
            pollThrough(&book, from: now, to: next)
            XCTAssertNil(book.noteFlip(nowMicroseconds: next))
            now = next
        }
        XCTAssertEqual(book.flips, 121)
        XCTAssertEqual(book.skips, 0)
        XCTAssertEqual(book.stillGaps, 0)
        XCTAssertEqual(book.gapMaxMicroseconds, beat)
    }

    func testWatchedGapConvictsTheSource() {
        var book = CaptureBeatBook()
        let start: UInt64 = 1_000_000
        book.notePoll(nowMicroseconds: start)
        _ = book.noteFlip(nowMicroseconds: start)
        // Two beats of silence with the doorbell polling every 1 ms
        // — the compositor simply never flipped.
        let next = start + 2 * beat
        pollThrough(&book, from: start, to: next)
        let event = book.noteFlip(nowMicroseconds: next)
        XCTAssertEqual(event?.verdict, .source)
        XCTAssertEqual(event?.gapMicroseconds, 2 * beat)
        XCTAssertLessThan(event?.blindMicroseconds ?? .max, 8_000)
        XCTAssertEqual(book.sourceSkips, 1)
        XCTAssertEqual(book.loopSkips, 0)
    }

    func testBlindGapConvictsTheLoop() {
        var book = CaptureBeatBook()
        let start: UInt64 = 1_000_000
        book.notePoll(nowMicroseconds: start)
        _ = book.noteFlip(nowMicroseconds: start)
        // The loop stalled 30 ms (a long encode, a service tail):
        // no polls at all until the late detection.
        let next = start + 2 * beat
        book.notePoll(nowMicroseconds: next)
        let event = book.noteFlip(nowMicroseconds: next)
        XCTAssertEqual(event?.verdict, .loop)
        XCTAssertEqual(event?.blindMicroseconds, 2 * beat)
        XCTAssertEqual(book.loopSkips, 1)
        XCTAssertEqual(book.sourceSkips, 0)
        XCTAssertEqual(book.blindMaxMicroseconds, 2 * beat)
    }

    func testBlindWindowResetsAtEachFlip() {
        var book = CaptureBeatBook()
        let start: UInt64 = 1_000_000
        book.notePoll(nowMicroseconds: start)
        _ = book.noteFlip(nowMicroseconds: start)
        // A long blind stall inside an ON-TIME beat...
        let onTime = start + beat
        book.notePoll(nowMicroseconds: onTime)
        XCTAssertNil(book.noteFlip(nowMicroseconds: onTime))
        // ...must not convict the NEXT gap, which was fully watched.
        let next = onTime + 2 * beat
        pollThrough(&book, from: onTime, to: next)
        let event = book.noteFlip(nowMicroseconds: next)
        XCTAssertEqual(event?.verdict, .source,
                       "the earlier blind interval belongs to the "
                       + "beat it delayed, not this one")
    }

    func testStillnessIsNotASkip() {
        var book = CaptureBeatBook()
        let start: UInt64 = 1_000_000
        book.notePoll(nowMicroseconds: start)
        _ = book.noteFlip(nowMicroseconds: start)
        let next = start + 2_000_000
        pollThrough(&book, from: start, to: next)
        XCTAssertNil(book.noteFlip(nowMicroseconds: next),
                     "a quiet desktop books stillness, never a skip")
        XCTAssertEqual(book.stillGaps, 1)
        XCTAssertEqual(book.skips, 0)
        XCTAssertEqual(book.gapMaxMicroseconds, 0,
                       "stillness stays out of the motion gap books")
    }

    func testOnTimeBeatWithJitterStaysClean() {
        var book = CaptureBeatBook()
        var now: UInt64 = 1_000_000
        book.notePoll(nowMicroseconds: now)
        _ = book.noteFlip(nowMicroseconds: now)
        // ±4 ms of detection wobble around the beat never books.
        for wobble in [UInt64(12_667), 20_667, 16_667, 13_000, 20_000] {
            let next = now + wobble
            pollThrough(&book, from: now, to: next)
            XCTAssertNil(book.noteFlip(nowMicroseconds: next))
            now = next
        }
        XCTAssertEqual(book.skips, 0)
    }

    func testFirstFlipHasNoGapToJudge() {
        var book = CaptureBeatBook()
        book.notePoll(nowMicroseconds: 5_000_000)
        XCTAssertNil(book.noteFlip(nowMicroseconds: 5_000_000))
        XCTAssertEqual(book.flips, 1)
        XCTAssertEqual(book.skips, 0)
    }
}
