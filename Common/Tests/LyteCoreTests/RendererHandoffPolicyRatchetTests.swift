import LyteTestKit
import XCTest

final class RendererHandoffPolicyRatchetTests: XCTestCase {
    func testSharedRendererHandoffHasNoProductionTwin() throws {
        let forbidden = [
            "struct RendererFrameDescriptor",
            "struct BoundedRendererHandoff",
            "struct RendererRecoveryFlushBarrier",
        ]
        let violations = try RepositorySourceTree().violations(
            containing: forbidden,
            excludingRelativePaths: [
                "Common/Sources/LyteCore/RendererHandoffPolicy.swift"
            ]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "renderer handoff policy twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
