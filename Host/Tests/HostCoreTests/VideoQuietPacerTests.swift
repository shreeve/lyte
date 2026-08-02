import XCTest
@testable import HostCore

// The video quiet ladder's laws: 1 s while active, 2→4→8→16→30 one
// rung per 30 s of stillness, every step announced exactly once, and
// the wake collapse announces active once.

final class VideoQuietPacerTests: XCTestCase {

    func testLadderIsThePinnedDocTable() {
        let pacer = VideoQuietPacer()
        XCTAssertEqual(pacer.interval(idleSeconds: 0), 1)
        XCTAssertEqual(pacer.interval(idleSeconds: 29.9), 1)
        XCTAssertEqual(pacer.interval(idleSeconds: 30), 2)
        XCTAssertEqual(pacer.interval(idleSeconds: 59.9), 2)
        XCTAssertEqual(pacer.interval(idleSeconds: 60), 4)
        XCTAssertEqual(pacer.interval(idleSeconds: 90), 8)
        XCTAssertEqual(pacer.interval(idleSeconds: 120), 16)
        XCTAssertEqual(pacer.interval(idleSeconds: 150), 30)
        XCTAssertEqual(pacer.interval(idleSeconds: 100_000), 30,
                       "the ceiling holds forever")
    }

    func testEveryStepAnnouncesExactlyOnce() {
        var pacer = VideoQuietPacer()
        // Active beats: no announcement (active is the starting
        // contract).
        for idle in [0.0, 5, 15, 29] {
            XCTAssertNil(pacer.assess(idleSeconds: idle).announce)
        }
        // Each rung announces once, then holds silent.
        let steps: [(idle: Double, interval: UInt8)] =
            [(31, 2), (61, 4), (91, 8), (121, 16), (151, 30)]
        for (idle, interval) in steps {
            let verdict = pacer.assess(idleSeconds: idle)
            XCTAssertEqual(
                verdict.announce,
                VideoQuietPacer.Announcement(
                    quiet: true, keepaliveSeconds: interval),
                "idle \(idle) must announce \(interval) s")
            XCTAssertNil(pacer.assess(idleSeconds: idle + 1).announce,
                         "the same rung must not re-announce")
        }
        // Deep stillness: silent at the ceiling.
        XCTAssertNil(pacer.assess(idleSeconds: 500).announce)
    }

    func testWakeAnnouncesActiveOnceAndTheLadderRestarts() {
        var pacer = VideoQuietPacer()
        _ = pacer.assess(idleSeconds: 200)  // deep quiet (30 s rung)
        // The wake: idle collapses (fresh damage or input).
        let woke = pacer.assess(idleSeconds: 0.1)
        XCTAssertEqual(
            woke.announce,
            VideoQuietPacer.Announcement(quiet: false, keepaliveSeconds: 1))
        XCTAssertEqual(woke.keepaliveSeconds, 1)
        XCTAssertNil(pacer.assess(idleSeconds: 1).announce,
                     "active does not re-announce")
        // The ladder restarts from the first rung.
        XCTAssertEqual(
            pacer.assess(idleSeconds: 31).announce,
            VideoQuietPacer.Announcement(quiet: true, keepaliveSeconds: 2))
    }
}
