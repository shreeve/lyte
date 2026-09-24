import HostSession
import HostWire
import LyteClientBrowserCore
import LyteCore
import LyteWire
import XCTest

/// The browser's half of the media-path loops the host depends on —
/// feedback, repair, path validation and the host clock — against the
/// shipping HostWire.Session.
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

    /// A beacon's echo carries its arrival as t2: time the page spends
    /// before draining the datagram is turnaround the host subtracts, not
    /// round-trip time.
    func testBeaconEchoStampsTheBeaconsArrivalNotTheDrain() throws {
        let host = BrowserHostPeer()
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        let pageDelay: UInt64 = 10_000
        for _ in 0..<300 {
            let arrived = host.nowMicros
            let datagrams = host.drain()
            host.advance(microseconds: pageDelay)
            for datagram in datagrams {
                host.deliver(
                    client.ingest(
                        datagram: datagram[...], arrivalMicros: arrived,
                        nowMicros: host.nowMicros),
                    notes: &notes)
            }
            host.deliver(client.tick(nowMicros: host.nowMicros), notes: &notes)
        }
        let rtts: [Int64] = host.events.compactMap {
            if case .beaconEchoAccepted(_, _, let rtt) = $0 { return rtt }
            return nil
        }
        XCTAssertGreaterThanOrEqual(rtts.count, 2)
        XCTAssertLessThan(rtts.max() ?? .max, 1_000, "the page's drain delay read as RTT")
    }

    /// A P-frame that loses more data shards than it has parity cannot be
    /// healed by FEC: the browser NACKs the missing shards in an immediate
    /// feedback report, the host's repair judgement honors it, and the
    /// repaired frame reaches the Conductor with no IDR.
    func testPastParityLossDrawsARepairInsteadOfAnIdr() throws {
        let host = BrowserHostPeer()
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        var scheduled = try lossyChain(host, client, notes: &notes) { step, notes in
            host.deliver(step, notes: &notes)
        }
        for _ in 0..<50 where scheduled.count < 3 {
            host.advance(microseconds: 1_000)
            scheduled += deliver(host.drain(), host, client, notes: &notes)
        }

        XCTAssertTrue(host.events.contains {
            if case .repairEnqueued(let frame, _) = $0 { return frame.rawValue == 1 }
            return false
        }, "the host never honored a NACK: \(notes.joined(separator: " | "))")
        XCTAssertEqual(scheduled.sorted(), [1, 2, 3], "the repaired frame never assembled")
        XCTAssertEqual(client.nackStats.framesCompletedByRepair, 1)
        XCTAssertEqual(client.counters.idrRequestsSent, 0, "repair healed it — no IDR")
        XCTAssertEqual(host.session.counters.idrRequests, 0)
    }

    /// A NACK the host can no longer honor inside its freeze budget draws a
    /// 0x23 refusal; the browser escalates that frame to an IDR at once
    /// instead of waiting out its 250 ms repair deadline.
    func testRefusedRepairEscalatesToAnIdrAtOnce() throws {
        let host = BrowserHostPeer()
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        // The report carrying the NACK is held past the host's budget.
        var held: [[UInt8]] = []
        _ = try lossyChain(host, client, notes: &notes) { step, notes in
            notes += step.events
            held += step.outbound
        }
        XCTAssertTrue(notes.contains { $0.hasPrefix("nack: frame 1 asks") })
        host.advance(microseconds: 150_000)
        for datagram in held { host.receive(datagram) }
        _ = deliver(host.drain(), host, client, notes: &notes)
        host.deliver(client.tick(nowMicros: host.nowMicros), notes: &notes)

        XCTAssertGreaterThanOrEqual(host.session.counters.repairRefusalsSent, 1)
        XCTAssertGreaterThanOrEqual(client.counters.repairRefusals, 1)
        XCTAssertEqual(
            client.counters.idrRequestsSent, 1,
            "the refusal must escalate before the repair deadline")
        XCTAssertTrue(host.events.contains {
            if case .idrRequested = $0 { return true }
            return false
        })
    }

    /// The browser's blackout detector matches the native shell's: an idle
    /// host's 1 Hz beacons are not a blackout, and the first audio datagram
    /// tightens the bound to 350 ms.
    func testAudioEvidenceTightensTheBlackoutDetector() throws {
        let host = BrowserHostPeer()
        let (client, readyNotes) = try host.readyClient()
        var notes = readyNotes
        _ = host.drain()

        _ = client.tick(nowMicros: host.nowMicros + 1_000_000)
        XCTAssertEqual(client.sessionState, .active, "a quiet second is an idle host")

        host.advance(microseconds: 1_000_000)
        try host.session.ingestAudioPacket(
            [0xF8, 0xFF, 0xFE], captureTimestampMicroseconds: host.hostMicros,
            now: host.hostMicros * 1_000)
        host.run(client, notes: &notes, beats: 4) { _ in false }
        XCTAssertTrue(
            notes.contains { $0.contains("blackout detector tightened to 350 ms") },
            notes.joined(separator: " | "))
        _ = host.drain()
        _ = client.tick(nowMicros: host.nowMicros + 400_000)
        XCTAssertEqual(client.sessionState, .frozen)
    }

    // MARK: Helpers

    /// Frame 0 (IDR) arrives whole; frame 1 loses parity + 2 data shards;
    /// frames 2 and 3 push the channel's highest seq past the loss. Every
    /// client step goes to `route`. Returns the frames scheduled so far.
    private func lossyChain(
        _ host: BrowserHostPeer, _ client: BrowserControlSession,
        notes: inout [String],
        route: (BrowserControlSession.Step, inout [String]) -> Void
    ) throws -> [UInt32] {
        let corpus = try VideoCorpus.frames()
        // Beacon echoes give the host the SRTT its repair budget needs.
        host.run(client, notes: &notes, beats: 500) { _ in false }
        XCTAssertEqual(
            try host.sendFrame(corpus[0], keyframe: true, to: client).count, 1)
        host.run(client, notes: &notes, beats: 20) { _ in false }

        var scheduled: [UInt32] = []
        for index in 1...3 {
            try host.session.ingestVideoFrame(
                corpus[index], captureTimestampMicroseconds: host.hostMicros,
                isKeyframe: false, now: host.hostMicros * 1_000)
            var flight: [VideoChannelDatagram] = []
            for _ in 0..<30 {
                host.advance(microseconds: 1_000)
                flight += host.drainReleased()
            }
            let dropped = index == 1 ? try pastParity(flight) : []
            for datagram in flight {
                if datagram.pacerClass == .freshVideo,
                   dropped.contains(try shardIndex(datagram.bytes)) {
                    continue
                }
                let step = client.ingest(datagram: datagram.bytes, nowMicros: host.nowMicros)
                scheduled += step.scheduled.map(\.frameNumber)
                route(step, &notes)
            }
        }
        return scheduled
    }

    /// Data-shard indices past what parity can heal: parity + 2 of them.
    private func pastParity(_ flight: [VideoChannelDatagram]) throws -> Set<Int> {
        let first = try XCTUnwrap(flight.first { $0.pacerClass == .freshVideo })
        let (envelope, _) = try Envelope.decode(first.bytes)
        guard case .reedSolomon(_, let geometry) = try FecField.decode(envelope.fec)
        else {
            XCTFail("the corpus frame must be RS-coded")
            return []
        }
        XCTAssertLessThan(geometry.parityShards + 2, geometry.dataShards)
        return Set(0..<(geometry.parityShards + 2))
    }

    private func shardIndex(_ datagram: [UInt8]) throws -> Int {
        let (envelope, _) = try Envelope.decode(datagram)
        guard case .reedSolomon(let index, _) = try FecField.decode(envelope.fec)
        else { return -1 }
        return Int(index)
    }

    private func deliver(
        _ datagrams: [[UInt8]], _ host: BrowserHostPeer,
        _ client: BrowserControlSession, notes: inout [String]
    ) -> [UInt32] {
        var scheduled: [UInt32] = []
        for datagram in datagrams {
            let step = host.deliver(
                client.ingest(datagram: datagram, nowMicros: host.nowMicros),
                notes: &notes)
            scheduled += step.scheduled.map(\.frameNumber)
        }
        return scheduled
    }
}
