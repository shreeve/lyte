import Foundation
import LyteClientSession
import LyteClientTestKit
import LyteWire
import XCTest
@testable import LyteTransport

/// The 0x10 IDR request carries no cause, so the client names it: every
/// episode that opens announces its cause once and books it by cause;
/// demands that join an open episode, and its retries, stay silent.
final class VideoRecoveryAttributionTests: XCTestCase {
    private static let now = ClientTimestamp(microseconds: 5_000_000)

    private func makeCore(
        events: Locked<[LyteUdpSessionEvent]>
    ) -> LyteUdpSessionCore {
        let crypto = PassthroughTransportCrypto()
        return LyteUdpSessionCore(
            demux: ReceiveDemux(crypto: crypto),
            sender: TransportSender(crypto: crypto, transmit: { _ in true }),
            now: { Self.now },
            videoSink: HeadlessVideoSink(),
            onEvent: { event in events.append(event) })
    }

    private func requested(_ events: Locked<[LyteUdpSessionEvent]>) -> [String] {
        events.all.compactMap {
            guard case .videoRecoveryRequested(let cause, let frame) = $0
            else { return nil }
            return "\(cause.rawValue)@\(frame.rawValue)"
        }
    }

    func testEachEpisodeNamesTheCauseThatOpenedIt() {
        let events = Locked<[LyteUdpSessionEvent]>()
        let core = makeCore(events: events)

        core.beginVideoRecovery(
            cause: .hostPurgeInferredDamage, frame: FrameNumber(rawValue: 5),
            now: Self.now)
        // Joins the open episode: no second request, no second name.
        core.beginVideoRecovery(
            cause: .fecAssemblerDamage, frame: FrameNumber(rawValue: 6),
            now: Self.now)
        XCTAssertEqual(requested(events), ["hostPurgeInferredDamage@5"])

        core.noteVideoIrapEnqueued()
        core.requestVideoRecovery(
            after: FrameNumber(rawValue: 9), cause: .rendererFailure)
        XCTAssertEqual(
            requested(events),
            ["hostPurgeInferredDamage@5", "rendererFailure@9"])

        let causes = core.snapshotCounters().videoRecoveryEpisodesByCause
        XCTAssertEqual(causes, [.hostPurgeInferredDamage: 1, .rendererFailure: 1])
        XCTAssertEqual(core.idrStats.episodesStarted, 2)
        XCTAssertEqual(
            SessionStatsFormatter.idrLine(core.idrStats, causes: causes),
            "2 requested · host purge 1 · decode 1 · AWAITING IDR")
    }

    func testNoEpisodeNoRow() {
        XCTAssertNil(SessionStatsFormatter.idrLine(
            ClientIdrRecovery.Stats(), causes: [:]))
    }
}
