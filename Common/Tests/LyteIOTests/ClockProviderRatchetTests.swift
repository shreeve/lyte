import Foundation
import XCTest

final class ClockProviderRatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LyteIOTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Common
    }

    func testProductionShellsUseTheSharedMonotonicClock() throws {
        let fileManager = FileManager.default
        let sourceRoots = [
            Self.repositoryRoot.appendingPathComponent("Sources"),
            Self.repositoryRoot.appendingPathComponent("Host/Sources"),
            Self.repositoryRoot.appendingPathComponent("Common/Core"),
            Self.repositoryRoot.appendingPathComponent("Common/IO"),
        ]
        let forbidden = [
            "DispatchTime.now()",
            "clock_gettime(CLOCK_MONOTONIC",
            "ContinuousClock.now",
        ]
        let provider = Self.repositoryRoot.appendingPathComponent(
            "Common/IO/SystemMonotonicClock.swift"
        ).standardizedFileURL.path
        var violations: [String] = []

        for root in sourceRoots {
            guard
                let files = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil
                )
            else { continue }
            for case let file as URL in files
            where file.pathExtension == "swift"
                && file.standardizedFileURL.path != provider
            {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden where source.contains(token) {
                    violations.append(
                        file.path.replacingOccurrences(
                            of: Self.repositoryRoot.path + "/", with: ""
                        ) + ": " + token
                    )
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "monotonic clock bypasses:\n"
                + violations.sorted().joined(
                    separator: "\n"
                )
        )
    }
}
