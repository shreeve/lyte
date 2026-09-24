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
        let tree = RepositorySourceTree()
        let paths = [
            "Client/Sources/LyteTransport/LyteVideoPipeline.swift",
            "Client/Sources/LyteTransport/VideoFlightRecorder.swift",
        ]
        for path in paths {
            let source = try tree.source(
                of: tree.repositoryRoot.appendingPathComponent(path))
            XCTAssertFalse(
                source.contains("SystemMonotonicClock"),
                "\(path) must receive time through its constructor")
        }
    }
}
