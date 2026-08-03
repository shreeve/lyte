import Foundation
import LyteTestKit
import XCTest

final class VideoPolicyRatchetTests: XCTestCase {
    private let sourceTree = RepositorySourceTree()

    func testSharedVideoPoliciesHaveNoProductionTwin() throws {
        let forbidden = [
            "struct ProofCounter",
            "struct RateMeter",
            "struct VideoBeatConductor",
            "struct VideoDeliveryGauge",
        ]
        let violations = try sourceTree.violations(
            containing: forbidden,
            excludingRelativePaths: [
                "Common/Sources/LyteCore/ConductorPrimitives.swift",
                "Common/Sources/LyteCore/VideoBeatConductor.swift",
                "Common/Sources/LyteCore/VideoDeliveryGauge.swift",
            ]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "video policy twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }

    func testSynchronizationStaysInOneShellPerCrossQueueOwner() throws {
        let conductor = try source(
            "Sources/LyteTransport/VideoBeatConductorController.swift")
        let delivery = try source(
            "Sources/LyteTransport/VideoDeliveryBooks.swift")
        let core = try source(
            "Common/Sources/LyteCore/VideoBeatConductor.swift")
            + source("Common/Sources/LyteCore/VideoDeliveryGauge.swift")

        XCTAssertEqual(conductor.components(separatedBy: "NSLock()").count - 1, 1)
        XCTAssertEqual(delivery.components(separatedBy: "NSLock()").count - 1, 1)
        XCTAssertFalse(core.contains("NSLock"))
        XCTAssertFalse(core.contains("import Foundation"))
        XCTAssertFalse(delivery.contains("RateMeter("))
        XCTAssertFalse(delivery.contains("Histogram<"))
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: sourceTree.repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
