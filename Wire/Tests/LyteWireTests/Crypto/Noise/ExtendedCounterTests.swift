import XCTest
import LyteWire
import LyteWireTestKit

// The ROC layer in isolation (W-G6's "nonce/epoch unit tests prove no
// (key, nonce) pair ever repeats across rekey and seq wrap"): the
// receiver reconstructs a 64-bit extended counter from the u16 envelope
// seq via serial distance from the last-seen position, SRTP-ROC-style,
// and the replay window admits each counter exactly once. Uniqueness
// within an epoch key follows from the tracker (counters accepted at
// most once); uniqueness across epochs from the key change + epoch bytes
// in the nonce (NoiseTransportTests.testRekeyProducesDifferentCiphertext…).

final class ExtendedCounterTests: XCTestCase {

    func testFirstDatagramAnchorsAtRawSeq() {
        let tracker = ExtendedCounterTracker()
        XCTAssertEqual(tracker.extendedCounter(for: ChannelSeq(rawValue: 0)), 0)
        XCTAssertEqual(tracker.extendedCounter(for: ChannelSeq(rawValue: 7)), 7)
        XCTAssertEqual(
            tracker.extendedCounter(for: ChannelSeq(rawValue: 65534)), 65534
        )
    }

    func testForwardReconstructionAcrossWrap() {
        var tracker = ExtendedCounterTracker()
        tracker.accept(65535)
        // seq 0 after 65535: one step forward through the wrap.
        XCTAssertEqual(tracker.extendedCounter(for: ChannelSeq(rawValue: 0)), 65536)
        tracker.accept(65536)
        XCTAssertEqual(tracker.extendedCounter(for: ChannelSeq(rawValue: 1)), 65537)
        // A straggler from before the wrap still resolves backwards.
        XCTAssertEqual(
            tracker.extendedCounter(for: ChannelSeq(rawValue: 65533)), 65533
        )
    }

    func testMultipleWrapsKeepExtending() {
        var tracker = ExtendedCounterTracker()
        var extended: UInt64 = 65000
        tracker.accept(extended)
        // March forward 200k steps in jumps below the half-window; the
        // extended counter must never fold back.
        for _ in 0..<20 {
            extended &+= 10_000
            let seq = ChannelSeq(rawValue: UInt16(truncatingIfNeeded: extended))
            XCTAssertEqual(tracker.extendedCounter(for: seq), extended)
            tracker.accept(extended)
        }
        XCTAssertEqual(tracker.highest, 265_000)
    }

    func testBackwardBeforeSessionStartIsNil() {
        var tracker = ExtendedCounterTracker()
        tracker.accept(2)
        // seq 65530 reads as 8 steps behind extended 2 → below zero.
        XCTAssertNil(tracker.extendedCounter(for: ChannelSeq(rawValue: 65530)))
    }

    func testWindowVerdicts() {
        var tracker = ExtendedCounterTracker()
        XCTAssertEqual(tracker.verdict(for: 100), .fresh)
        tracker.accept(100)
        XCTAssertEqual(tracker.verdict(for: 100), .replayed)
        XCTAssertEqual(tracker.verdict(for: 101), .fresh)
        XCTAssertEqual(tracker.verdict(for: 99), .insideWindow)
        tracker.accept(99)
        XCTAssertEqual(tracker.verdict(for: 99), .replayed)
        // The window is 64 deep off the high-water mark.
        XCTAssertEqual(tracker.verdict(for: 100 - 63), .insideWindow)
        XCTAssertEqual(tracker.verdict(for: 100 - 64), .stale)
        // A big jump slides everything old out.
        tracker.accept(1000)
        XCTAssertEqual(tracker.verdict(for: 100), .stale)
        XCTAssertEqual(tracker.verdict(for: 999), .insideWindow)
    }

    func testEveryCounterAdmittedExactlyOnceUnderSeededChurn() {
        // Property: over a seeded random delivery pattern with loss,
        // duplication, and reorder, each extended counter that the
        // tracker admits is admitted exactly once — the no-nonce-reuse
        // invariant seen from the receive side.
        var rng = SplitMix64(seed: 0xC0FFEE)
        var tracker = ExtendedCounterTracker()
        var admitted = Set<UInt64>()

        var sent: [UInt64] = Array(0..<2000)
        // Duplicate ~20% and shuffle within a bounded horizon so most
        // datagrams stay inside the 64-deep window.
        sent += (0..<400).map { _ in UInt64(rng.next() % 2000) }
        for i in sent.indices {
            let jump = Int(rng.next() % 32)
            let j = min(sent.count - 1, i + jump)
            sent.swapAt(i, j)
        }

        for extended in sent {
            let seq = ChannelSeq(rawValue: UInt16(truncatingIfNeeded: extended))
            guard let candidate = tracker.extendedCounter(for: seq) else { continue }
            switch tracker.verdict(for: candidate) {
            case .fresh, .insideWindow:
                XCTAssertFalse(
                    admitted.contains(candidate),
                    "counter \(candidate) admitted twice — nonce reuse"
                )
                admitted.insert(candidate)
                tracker.accept(candidate)
            case .replayed, .stale:
                continue
            }
        }
        XCTAssertGreaterThan(admitted.count, 1500, "sanity: most datagrams landed")
    }
}
