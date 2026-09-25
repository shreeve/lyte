import XCTest
import LyteClientTestKit
import CoreMedia
import LyteTransport
import LyteWire

// The client's FROZEN detector defaults to 2.5 s (an idle host emits only
// 1 Hz beacons); the moment the session sees audio (a 5 ms path probe that
// flows through ACTIVE, IDLE and FROZEN) it tightens to 350 ms. It is
// evidence-gated: no capability announces audio presence, so a host that
// never sends chan 1 keeps the 2.5 s bound.

final class AudioDetectorGateTests: XCTestCase {

    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var micros: UInt64 = 1_000_000
        var now: ClientTimestamp {
            lock.lock()
            defer { lock.unlock() }
            return ClientTimestamp(microseconds: micros)
        }
        func advance(_ delta: UInt64) {
            lock.lock()
            micros += delta
            lock.unlock()
        }
    }

    private func makeCore(
        clock: VirtualClock,
        events: Locked<[LyteUdpSessionEvent]>,
        config: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig(),
        onVideoRecoveryDemand: @escaping @Sendable (
            VideoRecoveryCause, FrameNumber
        ) -> Void = { _, _ in }
    ) -> LyteUdpSessionCore {
        let crypto = PassthroughTransportCrypto()
        return LyteUdpSessionCore(
            demux: ReceiveDemux(crypto: crypto),
            sender: TransportSender(crypto: crypto, transmit: { _ in true }),
            config: config,
            now: { clock.now },
            onVideoRecoveryDemand: onVideoRecoveryDemand,
            videoSink: HeadlessVideoSink(),
            onEvent: { events.append($0) })
    }

    /// One audio datagram (data shard 0 of a 4+2 group).
    private func audioDatagram(
        group: UInt32, captureMicros: UInt64
    ) throws -> (envelope: Envelope, payload: [UInt8]) {
        let payload = (0..<80).map { UInt8(truncatingIfNeeded: $0) }
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 320)
        let envelope = Envelope(
            channel: .audio,
            seq: ChannelSeq(rawValue: UInt16(group & 0xFFFF)),
            frame: FrameNumber(rawValue: group),
            timestamp: captureMicros,
            fec: try FecField.reedSolomonShard(0, of: geometry).encoded)
        return (envelope, payload)
    }

    func testNoAudioKeepsTheBeaconBoundedDetector() {
        let clock = VirtualClock()
        let events = Locked<[LyteUdpSessionEvent]>()
        let core = makeCore(clock: clock, events: events)
        XCTAssertFalse(core.control.detectorTightened)

        // 400 ms of silence: WELL past 350 ms, far under 2.5 s — a
        // no-audio session must NOT freeze here (the rationale:
        // an IDLE host's 1 Hz beacons would flap a 350 ms detector).
        clock.advance(400_000)
        core.tick(now: clock.now)
        XCTAssertNotEqual(core.state, .frozen,
            "no audio seen — 400 ms of silence must not freeze")

        // The 2.5 s default still catches a real blackout.
        clock.advance(2_200_000)
        core.tick(now: clock.now)
        XCTAssertEqual(core.state, .frozen)
    }

    func testAudioEvidenceTightensTo350Milliseconds() throws {
        let clock = VirtualClock()
        let events = Locked<[LyteUdpSessionEvent]>()
        let core = makeCore(clock: clock, events: events)

        // The first authenticated chan-1 arrival is the evidence gate.
        let (envelope, payload) = try audioDatagram(
            group: 0, captureMicros: 42_000)
        core.handleDatagram(
            .accepted(envelope: envelope, payload: payload),
            arrivalMicroseconds: clock.now.microseconds)
        XCTAssertTrue(core.control.detectorTightened)
        XCTAssertEqual(core.snapshotCounters().audioDatagramsReceived, 1)
        XCTAssertTrue(events.all.contains {
            if case .protocolNote(let note) = $0 {
                return note.contains("tightened to 350 ms")
            }
            return false
        })

        // Audio keeps the detector fed…
        for group in 1..<10 {
            clock.advance(20_000)
            let (envelope, payload) = try audioDatagram(
                group: UInt32(group * 4), captureMicros: 42_000)
            core.handleDatagram(
                .accepted(envelope: envelope, payload: payload),
                arrivalMicroseconds: clock.now.microseconds)
            core.tick(now: clock.now)
            XCTAssertNotEqual(core.state, .frozen)
        }

        // …and 400 ms of total silence now freezes (was 2.5 s).
        clock.advance(400_000)
        core.tick(now: clock.now)
        XCTAssertEqual(core.state, .frozen,
            "with the 5 ms probe flowing, 350 ms of silence is a dark path")

        // Returning audio clears the pill (evidence exits FROZEN).
        clock.advance(5_000)
        let (back, backPayload) = try audioDatagram(
            group: 40, captureMicros: 99_000)
        core.handleDatagram(
            .accepted(envelope: back, payload: backPayload),
            arrivalMicroseconds: clock.now.microseconds)
        XCTAssertNotEqual(core.state, .frozen)
    }

    func testRendererRecoverySeamJoinsOneCoalescedIdrEpisode() {
        let demands = Locked<[(VideoRecoveryCause, FrameNumber)]>()
        let core = makeCore(
            clock: VirtualClock(),
            events: Locked<[LyteUdpSessionEvent]>(),
            onVideoRecoveryDemand: { cause, frame in
                demands.append((cause, frame))
            })
        core.requestVideoRecovery(
            after: FrameNumber(rawValue: 40), cause: .rendererFailure)
        core.requestVideoRecovery(
            after: FrameNumber(rawValue: 41), cause: .rendererBackpressure)
        let stats = core.idrRequester.snapshotStats()
        XCTAssertEqual(stats.verdicts, 2)
        XCTAssertEqual(stats.episodesStarted, 1)
        XCTAssertEqual(stats.requestsSent, 1)
        XCTAssertTrue(stats.recoveryOutstanding)
        XCTAssertTrue(demands.all.isEmpty,
                      "the handoff raised these demands; none echo back to it")

        // Assembly cannot close recovery. Only the handoff's post-enqueue
        // callback does.
        core.noteVideoIrapEnqueued()
        XCTAssertFalse(core.idrRequester.snapshotStats().recoveryOutstanding)
    }

    func testTighteningPreservesTheWireMode() throws {
        let clock = VirtualClock()
        let events = Locked<[LyteUdpSessionEvent]>()
        let core = makeCore(clock: clock, events: events)

        // Drive the receiver machine to IDLE the wire way: a real ARQ
        // segment carrying ModeTransition(idle), built with a LyteWire
        // host-clock endpoint and delivered through the core's CTRL
        // peek — then let audio arrive. Audio flows in
        // IDLE and must not wake or corrupt the mode.
        var hostArq = ArqEndpoint<HostClock>(channel: .ctrl)
        try hostArq.send(
            message: ModeTransition(mode: .idle).encode(),
            now: HostTimestamp(microseconds: 1))
        let (segments, _) = hostArq.poll(
            now: HostTimestamp(microseconds: 2))
        for (index, segment) in segments.enumerated() {
            let ctrl = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: UInt16(index)),
                frame: FrameNumber(rawValue: 0),
                timestamp: 1,
                fec: 0)
            core.handleDatagram(
                .accepted(envelope: ctrl, payload: segment),
                arrivalMicroseconds: clock.now.microseconds)
        }
        XCTAssertEqual(core.control.wireMode, .idle)

        let (envelope, payload) = try audioDatagram(
            group: 0, captureMicros: 7_000)
        core.handleDatagram(
            .accepted(envelope: envelope, payload: payload),
            arrivalMicroseconds: clock.now.microseconds)
        XCTAssertTrue(core.control.detectorTightened)
        XCTAssertEqual(core.control.wireMode, .idle,
            "the rebuilt machine must carry the wire mode across")
        XCTAssertEqual(core.state, .idle)
    }

    func testNilTightenedConfigDisablesTheTightening() throws {
        let clock = VirtualClock()
        let events = Locked<[LyteUdpSessionEvent]>()
        var config = LyteUdpSessionCoreConfig()
        config.tightenedBlackoutSilenceMicroseconds = nil
        let core = makeCore(clock: clock, events: events, config: config)

        let (envelope, payload) = try audioDatagram(
            group: 0, captureMicros: 42_000)
        core.handleDatagram(
            .accepted(envelope: envelope, payload: payload),
            arrivalMicroseconds: clock.now.microseconds)
        XCTAssertFalse(core.control.detectorTightened)
        clock.advance(400_000)
        core.tick(now: clock.now)
        XCTAssertNotEqual(core.state, .frozen)
    }
}
