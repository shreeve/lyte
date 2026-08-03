import LyteCore
import XCTest
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE CL-3 GATE (client-side legs): the return path exists and tells the
// truth. FeedbackReports built from a known demux state carry the exact
// ledgers and dispersion samples that went in; the cadence is pinned to
// 25–50 ms; the send path seals through the TransportCrypto seam with the
// envelope header as AAD (byte-identical to what the receiver slices
// off); IDR requests coalesce instead of spamming; and a ClockBeacon in
// produces a BeaconEcho out with the four timestamps in the right slots —
// offset/RTT computable, cross-checked against the frozen W4a worked
// example.

final class FeedbackPathTests: XCTestCase {

    private static var beaconVectorsPath: String {
        var components = #filePath.split(separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/") + "/Wire/Vectors/beacon-v1.json"
    }

    // MARK: - Helpers

    /// A demux fed a known pattern: video seqs 0,1,2,4 (gap at 3, then a
    /// duplicate of 2), audio seqs 100,101 — with fixed arrival stamps.
    private func makeKnownDemux() throws -> ReceiveDemux {
        let demux = ReceiveDemux(crypto: InsecureTransportCrypto())
        var arrival: UInt64 = 1_000_000
        for seq in [0, 1, 2, 4] {
            let envelope = Envelope(
                channel: .videoActive,
                seq: ChannelSeq(rawValue: UInt16(seq)),
                frame: FrameNumber(rawValue: UInt32(seq)),
                timestamp: 0, fec: 0)
            demux.ingest(
                datagram: try envelope.encode(payload: [0xAA])[...],
                arrivalMicroseconds: arrival)
            arrival += 250
        }
        // The duplicate of seq 2.
        let dup = Envelope(
            channel: .videoActive, seq: ChannelSeq(rawValue: 2),
            frame: FrameNumber(rawValue: 2), timestamp: 0, fec: 0)
        demux.ingest(
            datagram: try dup.encode(payload: [0xAA])[...],
            arrivalMicroseconds: arrival)
        arrival += 250
        for seq in [100, 101] {
            let envelope = Envelope(
                channel: .audio,
                seq: ChannelSeq(rawValue: UInt16(seq)),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0, fec: 0)
            demux.ingest(
                datagram: try envelope.encode(payload: [0x0B])[...],
                arrivalMicroseconds: arrival)
            arrival += 250
        }
        return demux
    }

    /// A sender whose transmissions are captured, not sent.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[UInt8]] = []
        var accept = true
        func append(_ datagram: [UInt8]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard accept else { return false }
            stored.append(datagram)
            return true
        }
        var datagrams: [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    // MARK: - Report building from live demux state

    func testReportFromKnownDemuxStateHasCorrectLedgersAndDispersion() throws {
        let demux = try makeKnownDemux()
        let capture = Capture()
        let sender = TransportSender(crypto: InsecureTransportCrypto(),
                                     transmit: { capture.append($0) })
        let feedback = FeedbackSender(demux: demux, sender: sender)

        let report = feedback.buildReport(
            now: ClientTimestamp(microseconds: 2_000_000))

        XCTAssertEqual(report.pathId, 0, "v1 is single-path")
        XCTAssertEqual(report.clientTimestamp.microseconds, 2_000_000)
        XCTAssertTrue(report.nacks.isEmpty,
                      "NACK section stays empty until HS-17 (ruling §4.7)")

        // Ledgers: audio then video (snapshot sorts by channel number).
        XCTAssertEqual(report.channels.count, 2)
        let audio = report.channels[0]
        XCTAssertEqual(audio.channel, .audio)
        XCTAssertEqual(audio.highestSeq.rawValue, 101)
        XCTAssertEqual(audio.received, 2)
        XCTAssertEqual(audio.missing, 0)
        XCTAssertEqual(audio.duplicates, 0)
        let video = report.channels[1]
        XCTAssertEqual(video.channel, .videoActive)
        XCTAssertEqual(video.highestSeq.rawValue, 4)
        XCTAssertEqual(video.received, 4, "duplicates are not counted as received")
        XCTAssertEqual(video.missing, 1, "the skipped seq 3")
        XCTAssertEqual(video.duplicates, 1)

        // Dispersion: all 7 accepted arrivals, base = earliest, 250 µs
        // spacing preserved.
        let dispersion = try XCTUnwrap(report.dispersion)
        XCTAssertEqual(dispersion.base.microseconds, 1_000_000)
        XCTAssertEqual(dispersion.samples.count, 7)
        XCTAssertEqual(
            dispersion.samples.map(\.arrivalDeltaMicroseconds),
            [0, 250, 500, 750, 1000, 1250, 1500])
        XCTAssertEqual(dispersion.samples[0].channel, .videoActive)
        XCTAssertEqual(dispersion.samples[0].seq.rawValue, 0)
        XCTAssertEqual(dispersion.samples[4].channel, .videoActive)
        XCTAssertEqual(dispersion.samples[4].seq.rawValue, 2,
                       "the duplicate arrival is still a real packet on the wire")
        XCTAssertEqual(dispersion.samples[5].channel, .audio)
        XCTAssertEqual(dispersion.samples[5].seq.rawValue, 100)

        // The report survives its own codec (the wire is the contract).
        let decoded = try FeedbackReport.decode(report.encode())
        XCTAssertEqual(decoded, report)

        // A second build sees a drained sample buffer: no dispersion.
        let second = feedback.buildReport(
            now: ClientTimestamp(microseconds: 2_040_000))
        XCTAssertNil(second.dispersion, "arrival samples drain per report")
        XCTAssertEqual(second.channels.count, 2, "ledgers are cumulative, not drained")
    }

    func testDispersionDecimatesToSectionBound() throws {
        let demux = ReceiveDemux(crypto: InsecureTransportCrypto())
        for i in 0..<200 {
            let envelope = Envelope(
                channel: .videoActive, seq: ChannelSeq(rawValue: UInt16(i)),
                frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0)
            demux.ingest(
                datagram: try envelope.encode(payload: [1])[...],
                arrivalMicroseconds: 5_000_000 + UInt64(i) * 100)
        }
        let sender = TransportSender(crypto: InsecureTransportCrypto(),
                                     transmit: { _ in true })
        let feedback = FeedbackSender(demux: demux, sender: sender)
        let report = feedback.buildReport(now: ClientTimestamp(microseconds: 6_000_000))
        let dispersion = try XCTUnwrap(report.dispersion)
        XCTAssertEqual(dispersion.samples.count, FeedbackBounds.maxDispersionSamples,
                       "over-full windows decimate to the section bound")
        XCTAssertNoThrow(try report.encode(), "a decimated report always encodes")
    }

    // MARK: - Cadence

    func testCadenceClampsToBuildPlanRange() {
        let demux = ReceiveDemux(crypto: InsecureTransportCrypto())
        let sender = TransportSender(crypto: InsecureTransportCrypto(),
                                     transmit: { _ in true })
        XCTAssertEqual(FeedbackSender(demux: demux, sender: sender,
                                      intervalMilliseconds: 10).cadenceMilliseconds, 25)
        XCTAssertEqual(FeedbackSender(demux: demux, sender: sender,
                                      intervalMilliseconds: 40).cadenceMilliseconds, 40)
        XCTAssertEqual(FeedbackSender(demux: demux, sender: sender,
                                      intervalMilliseconds: 500).cadenceMilliseconds, 50)
    }

    func testCadenceTimerFiresWithinTheWindow() throws {
        let demux = ReceiveDemux(crypto: InsecureTransportCrypto())
        let capture = Capture()
        let sender = TransportSender(crypto: InsecureTransportCrypto(),
                                     transmit: { capture.append($0) })
        let feedback = FeedbackSender(demux: demux, sender: sender,
                                      intervalMilliseconds: 25)
        feedback.start()
        defer { feedback.stop() }

        // 500 ms at a 25 ms cadence is nominally 20 reports; assert a
        // loose band that catches "never fires" and "fires per-ms" while
        // tolerating CI scheduling judder.
        Thread.sleep(forTimeInterval: 0.5)
        feedback.stop()
        let sent = feedback.snapshotStats().reportsSent
        XCTAssertGreaterThanOrEqual(sent, 5, "cadence timer must actually fire")
        XCTAssertLessThanOrEqual(sent, 25, "cadence must respect the 25 ms floor")

        // Every datagram left on chan=3 with monotonically increasing seq.
        let datagrams = capture.datagrams
        XCTAssertEqual(UInt64(datagrams.count), sent)
        for (i, datagram) in datagrams.enumerated() {
            let (envelope, payload) = try Envelope.decode(datagram)
            XCTAssertEqual(envelope.channel, .feedback)
            XCTAssertEqual(envelope.seq.rawValue, UInt16(i))
            XCTAssertNoThrow(try FeedbackReport.decode(Array(payload)))
        }
    }

    // MARK: - The send path seals through the crypto seam

    /// A crypto stub that visibly transforms payloads and records the AAD
    /// it was handed, so the test can prove the seam is in the path.
    private final class RecordingCrypto: TransportCrypto, @unchecked Sendable {
        let lock = NSLock()
        var sealedAads: [[UInt8]] = []
        var modeDescription: String { "recording stub (tests only)" }
        func open() throws {}
        func unseal(
            wirePayload: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
            envelope: Envelope
        ) throws -> [UInt8] {
            wirePayload.map { $0 ^ 0x5A }
        }
        func seal(
            plaintext: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
            envelope: Envelope
        ) throws -> [UInt8] {
            lock.lock()
            sealedAads.append(Array(aad))
            lock.unlock()
            return plaintext.map { $0 ^ 0x5A }
        }
    }

    func testSendPathSealsWithHeaderAsAad() throws {
        let crypto = RecordingCrypto()
        let capture = Capture()
        let sender = TransportSender(crypto: crypto,
                                     transmit: { capture.append($0) })
        let plaintext: [UInt8] = [1, 2, 3, 4]
        let sent = try sender.send(
            channel: .feedback,
            timestamp: ClientTimestamp(microseconds: 42),
            plaintext: plaintext)
        XCTAssertTrue(sent)

        let datagram = try XCTUnwrap(capture.datagrams.first)
        let (envelope, payload) = try Envelope.decode(datagram)
        XCTAssertEqual(envelope.channel, .feedback)
        XCTAssertEqual(envelope.seq.rawValue, 0)
        XCTAssertEqual(envelope.timestamp, 42)

        // The wire payload is the sealed bytes, not the plaintext…
        XCTAssertEqual(Array(payload), plaintext.map { $0 ^ 0x5A })
        // …and the AAD the seal saw is byte-identical to the header the
        // receiver will slice off (the master-plan §4.1 discipline).
        let headerOnWire = Array(datagram[..<(datagram.count - payload.count)])
        XCTAssertEqual(crypto.sealedAads, [headerOnWire])

        // Round trip through the receive seam: unseal restores plaintext.
        let demux = ReceiveDemux(crypto: crypto)
        let outcome = demux.ingest(datagram: datagram[...], arrivalMicroseconds: 0)
        guard case .accepted(_, let restored) = outcome else {
            return XCTFail("sealed datagram must ingest, got \(outcome)")
        }
        XCTAssertEqual(restored, plaintext)
    }

    func testSendPathAllocatesIndependentSeqsPerChannel() throws {
        let capture = Capture()
        let sender = TransportSender(crypto: InsecureTransportCrypto(),
                                     transmit: { capture.append($0) })
        try sender.send(channel: .feedback, timestamp: ClientTimestamp(microseconds: 0), plaintext: [1])
        try sender.send(channel: .ctrl, timestamp: ClientTimestamp(microseconds: 0), plaintext: [2])
        try sender.send(channel: .feedback, timestamp: ClientTimestamp(microseconds: 0), plaintext: [3])

        let seqs = try capture.datagrams.map { try Envelope.decode($0) }
            .map { ($0.envelope.channel, $0.envelope.seq.rawValue) }
        XCTAssertEqual(seqs[0].0, .feedback); XCTAssertEqual(seqs[0].1, 0)
        XCTAssertEqual(seqs[1].0, .ctrl); XCTAssertEqual(seqs[1].1, 0)
        XCTAssertEqual(seqs[2].0, .feedback); XCTAssertEqual(seqs[2].1, 1)
    }

    func testNoiseSealRefusesBeforeHandshake() throws {
        let crypto = try NoiseTransportCrypto(
            hostAddress: "127.0.0.1", hostPort: 9,
            hostStaticPublicKey: NoiseKeyPair.generate().publicKey)
        let sender = TransportSender(crypto: crypto, transmit: { _ in true })
        XCTAssertThrowsError(try sender.send(
            channel: .feedback,
            timestamp: ClientTimestamp(microseconds: 0),
            plaintext: [1])
        ) { error in
            guard case TransportCryptoError.handshakeFailed = error else {
                return XCTFail("expected handshakeFailed, got \(error)")
            }
        }
        XCTAssertEqual(sender.snapshotStats().sealFailures, 1)
    }

    // MARK: - IDR recovery episodes
    // (The codec round-trip/reject test moved to Wire's SessionCodecTests
    // with the codec promotion; the policy tests stay here.)

    func testIdrRecoveryEpisodeCoversBurstUntilAcceptedIrap() {
        let emitted = LockedRequests()
        let requester = IdrRequester(retryIntervalMilliseconds: 500,
                                     emit: { emitted.append($0) })
        let base: UInt64 = 10_000_000

        // A burst spanning repair refusal, fec-impossible, and whole-loss
        // timing shapes: the first demand fires immediately; every later
        // broken frame belongs to the same outstanding recovery episode.
        for i in 0..<10 {
            requester.recordRecoveryDemand(
                frame: FrameNumber(rawValue: UInt32(100 + i)),
                now: ClientTimestamp(
                    microseconds: base + UInt64(i) * 45_000))
        }
        XCTAssertEqual(emitted.all.count, 1)
        XCTAssertEqual(emitted.all[0].requestSeq, 0)
        XCTAssertEqual(emitted.all[0].frame.rawValue, 100)
        XCTAssertEqual(emitted.all[0].coalescedCount, 1)

        // Even cadence flushes and fresh damage just before 500 ms cannot
        // multiply the request.
        requester.flushIfDue(
            now: ClientTimestamp(microseconds: base + 499_999))
        XCTAssertEqual(emitted.all.count, 1)

        // A usable IRAP accepted by the render path closes the episode.
        requester.noteUsableIrapAccepted()
        requester.flushIfDue(
            now: ClientTimestamp(microseconds: base + 1_000_000))
        XCTAssertEqual(emitted.all.count, 1)

        // Damage after the heal starts a new episode immediately — the
        // first legitimate request is never suppressed by old history.
        requester.recordRecoveryDemand(
            frame: FrameNumber(rawValue: 500),
            now: ClientTimestamp(microseconds: base + 1_000_001))
        XCTAssertEqual(emitted.all.count, 2)
        XCTAssertEqual(emitted.all[1].requestSeq, 1)
        XCTAssertEqual(emitted.all[1].frame.rawValue, 500)

        let stats = requester.snapshotStats()
        XCTAssertEqual(stats.verdicts, 11)
        XCTAssertEqual(stats.requestsSent, 2)
        XCTAssertEqual(stats.episodesStarted, 2)
        XCTAssertEqual(stats.episodesCompleted, 1)
        XCTAssertEqual(stats.retryRequests, 0)
        XCTAssertTrue(stats.recoveryOutstanding)
    }

    func testIdrRecoveryEpisodeRetriesLostFirstIdrAt500ms() {
        let emitted = LockedRequests()
        let requester = IdrRequester(retryIntervalMilliseconds: 500,
                                     emit: { emitted.append($0) })
        let base = ClientTimestamp(microseconds: 20_000_000)

        requester.recordRecoveryDemand(
            frame: FrameNumber(rawValue: 40), now: base)
        requester.recordRecoveryDemand(
            frame: FrameNumber(rawValue: 44),
            now: base.advanced(byMicroseconds: 200_000))
        requester.flushIfDue(
            now: base.advanced(byMicroseconds: 499_999))
        XCTAssertEqual(emitted.all.count, 1)

        // The first request/answer was lost. Exactly at 500 ms the
        // feedback wake emits one retry naming the newest covered damage.
        requester.flushIfDue(
            now: base.advanced(byMicroseconds: 500_000))
        XCTAssertEqual(emitted.all.count, 2)
        XCTAssertEqual(emitted.all[1].requestSeq, 1)
        XCTAssertEqual(emitted.all[1].frame.rawValue, 44)
        XCTAssertEqual(emitted.all[1].coalescedCount, 2)

        requester.flushIfDue(
            now: base.advanced(byMicroseconds: 999_999))
        XCTAssertEqual(emitted.all.count, 2)
        requester.noteUsableIrapAccepted()
        requester.flushIfDue(
            now: base.advanced(byMicroseconds: 1_500_000))
        XCTAssertEqual(emitted.all.count, 2,
            "the accepted retry closes the episode; no timer tail")

        let stats = requester.snapshotStats()
        XCTAssertEqual(stats.requestsSent, 2)
        XCTAssertEqual(stats.retryRequests, 1)
        XCTAssertEqual(stats.episodesStarted, 1)
        XCTAssertEqual(stats.episodesCompleted, 1)
        XCTAssertFalse(stats.recoveryOutstanding)
    }

    private final class LockedRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [IdrRequest] = []
        func append(_ r: IdrRequest) { lock.lock(); stored.append(r); lock.unlock() }
        var all: [IdrRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: - Beacon echo

    private final class LockedEchoes: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [BeaconEcho] = []
        func append(_ e: BeaconEcho) { lock.lock(); stored.append(e); lock.unlock() }
        var all: [BeaconEcho] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    func testBeaconDecodesEchoRoundTripsFourTimestamps() throws {
        let echoes = LockedEchoes()
        // Injected client clock: t3 is pinned.
        let responder = BeaconEchoResponder(
            now: { ClientTimestamp(microseconds: 1_253_500) },
            emit: { echoes.append($0) })

        // The worked example's numbers (timing doc / beacon README):
        // t1 = 1,000,000 (host), t2 = 1,253,000, t3 = 1,253,500.
        let beacon = ClockBeacon(
            beaconSeq: 12,
            hostSend: HostTimestamp(microseconds: 1_000_000))
        let consumed = responder.handleCtrlPayload(
            beacon.encode(), arrivalMicroseconds: 1_253_000)
        XCTAssertTrue(consumed)

        let echo = try XCTUnwrap(echoes.all.first)
        XCTAssertEqual(echo.beaconSeq, 12)
        XCTAssertEqual(echo.hostSend.microseconds, 1_000_000, "t1 copied verbatim")
        XCTAssertEqual(echo.clientReceive.microseconds, 1_253_000, "t2 = arrival stamp")
        XCTAssertEqual(echo.clientSend.microseconds, 1_253_500, "t3 = emit instant")

        // The echo's bytes match the frozen W4a worked example, and the
        // host-side computation with its t4 gives the pinned offset/RTT.
        let file = try BeaconVectorFile.load(from: Self.beaconVectorsPath)
        let example = file.clockWorkedExample
        XCTAssertEqual(Hex.string(echo.encode()), example.echoHex,
                       "our echo is byte-identical to the frozen vector")
        let t4 = try XCTUnwrap(Hex.uint64(example.hostReceiveHex))
        let sample = echo.clockSample(hostReceive: HostTimestamp(microseconds: t4))
        XCTAssertEqual(sample.offsetMicroseconds, example.offsetMicroseconds)
        XCTAssertEqual(sample.rttMicroseconds, example.rttMicroseconds)
    }

    func testBeaconMirrorYieldsRetainedClockSamples() {
        // Deterministic client clock, advancing per call.
        let clock = TickingClock(start: 1_253_500)
        let echoes = LockedEchoes()
        let responder = BeaconEchoResponder(
            now: { clock.next() },
            emit: { echoes.append($0) })

        // Beacon 0: no mirror yet. t1=1,000,000, t2=1,253,000, t3=1,253,500.
        let first = ClockBeacon(
            beaconSeq: 0, hostSend: HostTimestamp(microseconds: 1_000_000))
        responder.handleCtrlPayload(first.encode(), arrivalMicroseconds: 1_253_000)
        XCTAssertTrue(responder.snapshotClockSamples().isEmpty,
                      "no mirror, no sample")

        // Beacon 1 mirrors echo 0 with the host-measured t4 = 1,008,500
        // (the worked example's numbers → offset 249,000, rtt 8,000).
        let second = ClockBeacon(
            beaconSeq: 1,
            hostSend: HostTimestamp(microseconds: 2_000_000),
            lastEcho: ClockBeacon.LastEcho(
                beaconSeq: 0,
                clientSend: ClientTimestamp(microseconds: 1_253_500),
                hostReceive: HostTimestamp(microseconds: 1_008_500)))
        responder.handleCtrlPayload(second.encode(), arrivalMicroseconds: 2_253_000)

        let samples = responder.snapshotClockSamples()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].beaconSeq, 0)
        XCTAssertEqual(samples[0].offsetMicroseconds, 249_000)
        XCTAssertEqual(samples[0].rttMicroseconds, 8_000)
        XCTAssertEqual(samples[0].measuredAt.microseconds, 1_253_000,
                       "the sample's coordinate is its own exchange's t2 (CL-10's x-axis)")
        XCTAssertEqual(echoes.all.count, 2, "every beacon is echoed")

        let stats = responder.snapshotStats()
        XCTAssertEqual(stats.beaconsReceived, 2)
        XCTAssertEqual(stats.echoesSent, 2)
        XCTAssertEqual(stats.clockSamples, 1)
    }

    func testNonBeaconAndMalformedCtrlPayloadsAreHandledQuietly() {
        let echoes = LockedEchoes()
        let responder = BeaconEchoResponder(
            now: { ClientTimestamp(microseconds: 0) },
            emit: { echoes.append($0) })

        // Foreign CTRL type: passed through (false), never echoed.
        let idr = IdrRequest(requestSeq: 0, frame: FrameNumber(rawValue: 1),
                             coalescedCount: 1)
        XCTAssertFalse(responder.handleCtrlPayload(idr.encode(),
                                                   arrivalMicroseconds: 0))
        // A truncated beacon: consumed, counted, no echo, no trap.
        let truncated = Array(ClockBeacon(
            beaconSeq: 9, hostSend: HostTimestamp(microseconds: 1)
        ).encode().dropLast())
        XCTAssertTrue(responder.handleCtrlPayload(truncated,
                                                  arrivalMicroseconds: 0))
        XCTAssertTrue(echoes.all.isEmpty)
        XCTAssertEqual(responder.snapshotStats().malformedBeacons, 1)
    }

    private final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64
        init(start: UInt64) { value = start }
        func next() -> ClientTimestamp {
            lock.lock()
            defer { lock.unlock() }
            let v = value
            value += 1_000_000
            return ClientTimestamp(microseconds: v)
        }
    }
}
