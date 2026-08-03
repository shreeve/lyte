import LyteTestKit
import XCTest

final class ClockProviderRatchetTests: XCTestCase {
    func testProductionShellsUseTheSharedMonotonicClock() throws {
        let forbidden = [
            "DispatchTime.now()",
            "clock_gettime(CLOCK_MONOTONIC",
            "ContinuousClock.now",
        ]
        let violations = try RepositorySourceTree().violations(
            containing: forbidden,
            excludingRelativePaths: [
                "Common/Sources/LyteIO/SystemMonotonicClock.swift"
            ]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "monotonic clock bypasses:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }

    func testVideoPoliciesReceiveTimeInsteadOfReadingTheShellClock() throws {
        let repositoryRoot = RepositorySourceTree().repositoryRoot
        let paths = [
            "Client/Sources/LyteTransport/LyteVideoPipeline.swift",
            "Client/Sources/LyteTransport/VideoFlightRecorder.swift",
        ]
        for path in paths {
            let file = repositoryRoot.appendingPathComponent(path)
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                source.contains("SystemMonotonicClock"),
                "\(path) must receive time through its constructor")
        }
    }
}
