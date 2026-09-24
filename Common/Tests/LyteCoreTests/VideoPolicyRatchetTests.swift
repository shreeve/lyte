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
}
