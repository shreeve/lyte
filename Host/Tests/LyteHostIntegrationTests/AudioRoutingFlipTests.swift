@testable import lyte_host
import LyteWire
import XCTest

/// A routing flip reports what actually runs afterwards.
final class AudioRoutingFlipTests: XCTestCase {
    private func flip(
        _ requested: HostAudioRoutingMode, from standing: HostAudioRoutingMode,
        starting: Set<HostAudioRoutingMode>
    ) -> (running: HostAudioRoutingMode, tried: [HostAudioRoutingMode]) {
        var tried: [HostAudioRoutingMode] = []
        let running = AudioRoutingFlip.apply(
            requested: requested, standing: standing
        ) { mode in
            tried.append(mode)
            return starting.contains(mode)
        }
        return (running, tried)
    }

    func testAFlipThatComesUpRunsTheRequest() {
        let result = flip(.hostMuted, from: .hostAudible, starting: [.hostMuted])
        XCTAssertEqual(result.running, .hostMuted)
        XCTAssertEqual(result.tried, [.hostMuted])
    }

    /// Standing stream-off, muted fails: nothing runs, and the client
    /// is told so — not audio restarted in the startup posture.
    func testAFailedFlipFromStreamOffStaysOff() {
        let result = flip(
            .hostMuted, from: .streamOff, starting: [.hostAudible])
        XCTAssertEqual(result.running, .streamOff)
        XCTAssertEqual(result.tried, [.hostMuted])
    }

    func testAFailedFlipComesBackToThePostureThatWasRunning() {
        let result = flip(.hostAudible, from: .hostMuted, starting: [.hostMuted])
        XCTAssertEqual(result.running, .hostMuted)
        XCTAssertEqual(result.tried, [.hostAudible, .hostMuted])
    }

    func testWhenNothingComesUpTheStreamIsOff() {
        let result = flip(.hostAudible, from: .hostMuted, starting: [])
        XCTAssertEqual(result.running, .streamOff)
    }

    func testStreamOffNeedsNoLeaf() {
        let result = flip(.streamOff, from: .hostAudible, starting: [])
        XCTAssertEqual(result.running, .streamOff)
        XCTAssertEqual(result.tried, [])
    }
}
