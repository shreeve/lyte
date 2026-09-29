import HostWire
import LyteClientBrowserCore
import LyteWire
import XCTest

/// Host-speaker routing (key 9) and announced audio quiet (key 15) against
/// the shipping HostWire session, as the native app negotiates them.
final class BrowserAudioPostureTests: XCTestCase {
    private static let hostCapabilities: Capabilities = .wireDefault
        .declaringClipboardText()
        .declaringHostAudioRouting()
        .declaringAudioQuietPosture()

    /// The stream plays in the browser, so the host's own speakers go
    /// quiet: the host's first routing status draws one mute request.
    func testAsksTheHostToMuteItsSpeakers() throws {
        let host = BrowserHostPeer(capabilities: Self.hostCapabilities)
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        XCTAssertTrue(notes.contains { $0.contains("hostAudioRouting=true") },
                      notes.joined(separator: " | "))

        _ = host.session.noteAudioRoutingApplied(
            .hostAudible, now: host.hostMicros * 1_000,
            hostMicroseconds: host.hostMicros)
        host.run(client, notes: &notes, beats: 40) { _ in Self.askedToMute(host) }

        XCTAssertTrue(Self.askedToMute(host), notes.joined(separator: " | "))
        XCTAssertTrue(notes.contains { $0.contains("asked host for hostMuted") })
    }

    /// An announced quiet is silence by contract: a dry page is not
    /// concealed through it, the blackout detector relaxes, and the wake
    /// plays on from the last packet played.
    func testAnnouncedQuietIsSilenceNotLossAndItsWakePlaysOn() throws {
        let host = BrowserHostPeer(capabilities: Self.hostCapabilities)
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        try host.sendAudio(count: 8, to: client)
        var pipeline = 0
        let primed = Self.played(host.pullAudio(client, pipeline: &pipeline))
        let last = try XCTUnwrap(primed.last)

        _ = host.session.noteAudioTrackState(
            .quiet, now: host.hostMicros * 1_000, hostMicroseconds: host.hostMicros)
        host.run(client, notes: &notes, beats: 40) { $0.audioAnnouncedQuiet }
        XCTAssertTrue(client.audioAnnouncedQuiet, notes.joined(separator: " | "))
        XCTAssertTrue(notes.contains { $0.contains("blackout detector relaxed") })

        for _ in 0..<30 {
            XCTAssertNil(
                client.pullAudio(nowMicros: host.nowMicros, pipelineFrames: 0),
                "a dry page during an announced quiet is not concealed")
            host.advance(microseconds: 5_000)
        }
        XCTAssertEqual(client.audioStats.plcInvocations, 0)

        _ = host.session.noteAudioTrackState(
            .active, now: host.hostMicros * 1_000, hostMicroseconds: host.hostMicros)
        try host.sendAudio(count: 8, to: client)
        pipeline = 0
        let woke = Self.played(host.pullAudio(client, pipeline: &pipeline))
        XCTAssertFalse(client.audioAnnouncedQuiet)
        XCTAssertEqual(woke.first, last &+ 1)
        XCTAssertEqual(woke, woke.sorted())
        XCTAssertEqual(client.audioStats.plcInvocations, 0)
    }

    private static func askedToMute(_ host: BrowserHostPeer) -> Bool {
        host.events.contains {
            if case .audioRoutingRequested(.hostMuted) = $0 { return true }
            return false
        }
    }

    private static func played(_ pulls: [BrowserAudioPlayout.Pull]) -> [UInt32] {
        pulls.compactMap {
            if case .packet(let packet) = $0 { return packet.number }
            return nil
        }
    }
}
