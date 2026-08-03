import Foundation
import XCTest

final class VideoPolicyRatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        if let override = ProcessInfo.processInfo.environment[
            "LYTE_REPOSITORY_ROOT"
        ] {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSharedVideoPoliciesHaveNoProductionTwin() throws {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.repositoryRoot.appendingPathComponent("CLEANUP.md").path))
        let roots = [
            Self.repositoryRoot.appendingPathComponent("Sources"),
            Self.repositoryRoot.appendingPathComponent("Host/Sources"),
            Self.repositoryRoot.appendingPathComponent("Wire/Sources"),
            Self.repositoryRoot.appendingPathComponent("Common/IO"),
        ]
        let forbidden = [
            "struct ProofCounter",
            "struct RateMeter",
            "struct VideoBeatConductor",
            "struct VideoDeliveryGauge",
        ]
        var violations: [String] = []

        for root in roots {
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for declaration in forbidden where source.contains(declaration) {
                    violations.append(
                        file.path.replacingOccurrences(
                            of: Self.repositoryRoot.path + "/", with: "")
                            + ": " + declaration)
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "video policy twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n"))
    }

    func testSynchronizationStaysInOneShellPerCrossQueueOwner() throws {
        let conductor = try source(
            "Sources/LyteTransport/VideoBeatConductorController.swift")
        let delivery = try source(
            "Sources/LyteTransport/VideoDeliveryBooks.swift")
        let core = try source("Common/Core/VideoBeatConductor.swift")
            + source("Common/Core/VideoDeliveryGauge.swift")

        XCTAssertEqual(conductor.components(separatedBy: "NSLock()").count - 1, 1)
        XCTAssertEqual(delivery.components(separatedBy: "NSLock()").count - 1, 1)
        XCTAssertFalse(core.contains("NSLock"))
        XCTAssertFalse(core.contains("import Foundation"))
        XCTAssertFalse(delivery.contains("RateMeter("))
        XCTAssertFalse(delivery.contains("Histogram<"))
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(path),
            encoding: .utf8)
    }
}
