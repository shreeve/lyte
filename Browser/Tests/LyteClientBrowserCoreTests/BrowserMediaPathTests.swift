import HostWire
import LyteClientBrowserCore
import LyteCore
import LyteWire
import XCTest

/// The browser's half of the media-path loops the host depends on —
/// feedback, repair, path validation and the host clock — against the
/// shipping HostWire.Session with its default lifecycle.
final class BrowserMediaPathTests: XCTestCase {
    /// The host freezes a session 350 ms after its last feedback report;
    /// a browser that reports on cadence keeps it ACTIVE.
    func testFeedbackKeepsTheHostOutOfFrozen() throws {
        let host = BrowserHostPeer(lifecycle: SessionMachineConfig())
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        host.run(client, notes: &notes, beats: 400) { _ in false }

        XCTAssertFalse(
            host.events.contains {
                if case .lifecycleChanged(.frozen) = $0 { return true }
                return false
            },
            "the host froze: \(notes.joined(separator: " | "))")
        XCTAssertGreaterThanOrEqual(
            host.session.counters.feedbackReportsParsed, 40,
            "2 s of 40 ms cadence")
        XCTAssertEqual(client.currentStatus, .ready)
    }
}
