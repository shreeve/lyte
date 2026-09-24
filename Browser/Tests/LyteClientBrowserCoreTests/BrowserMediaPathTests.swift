import HostSession
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

    /// A tagged datagram from a new tuple draws the host's PathChallenge;
    /// the browser's echo is what promotes the tuple.
    func testPathChallengeIsAnsweredAndTheHostPromotesTheNewTuple() throws {
        let host = BrowserHostPeer(lifecycle: SessionMachineConfig())
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        let roamed = FourTuple(
            localAddress: "127.0.0.1", localPort: 41_234,
            remoteAddress: "192.168.7.40", remotePort: 52_310)

        host.clientTuple = roamed
        host.deliver(
            client.sendInput(
                body: .keyKeycode(keycode: 30, pressed: true),
                nowMicros: host.nowMicros),
            notes: &notes)
        XCTAssertTrue(host.events.contains {
            if case .path(.sendChallenge(on: roamed, _)) = $0 { return true }
            return false
        }, "an authenticated tagged datagram from a new tuple is probed")
        host.run(client, notes: &notes, beats: 20) { _ in false }

        XCTAssertEqual(host.session.validator.primary.tuple, roamed)
        XCTAssertTrue(host.events.contains {
            if case .path(.freshKeyframeNeeded) = $0 { return true }
            return false
        }, "video restarts from an IDR on the new path")
        XCTAssertEqual(client.counters.pathChallengesAnswered, 1)
    }

    /// Capture times map through the beacon-fit host clock, so a client
    /// clock running 500 ppm fast (30 ms a minute) does not read as path
    /// delay: a first-frame anchor would.
    func testCaptureMappingTracksClockSkew() throws {
        let host = BrowserHostPeer(clientSkewPartsPerMillion: 500)
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        let corpus = try VideoCorpus.frames()

        let first = try host.sendFrame(corpus[0], keyframe: true, to: client)
        XCTAssertEqual(first.count, 1)
        host.run(client, notes: &notes, beats: 3_000, beat: 20_000) { _ in false }
        let later = try host.sendFrame(corpus[1], keyframe: false, to: client)

        let frame = try XCTUnwrap(later.first)
        XCTAssertLessThan(
            frame.pathDelayMicroseconds, 5_000,
            "a minute of skew leaked into the path delay")
    }
}
