import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/video-decisions-v1.json: replaying every
// video-v1.json scenario must reproduce the assembler's frozen decision
// stream line for line — the drops, skips, NACK candidates, write-offs
// and evictions the client's recovery depends on, not just the decodes.

final class VideoDecisionVectorFileTests: XCTestCase {

    private func loadFile() throws -> VideoDecisionVectorFile {
        try VideoDecisionVectorFile.loadCommitted()
    }

    func testEveryScenarioIsPinnedHonestly() throws {
        let file = try loadFile()
        XCTAssertEqual(file.scenarioFile, VideoVectorFile.fileName)
        XCTAssertEqual(file.provenance, "pinned-self-consistent")
        XCTAssertEqual(
            file.scenarios.map(\.name),
            try VideoVectorFile.loadCommitted().scenarios.map(\.name)
        )
    }

    func testReplayReproducesEveryDecision() throws {
        let frozen = Dictionary(
            uniqueKeysWithValues: try loadFile().scenarios.map { ($0.name, $0.events) }
        )
        for (scenario, events) in try replayVideoScenarios(
            VideoVectorFile.loadCommitted(),
            corpusDirectory: WireVectors.path("video-corpus-v1")
        ) {
            XCTAssertEqual(
                events.map(videoDecisionLine), frozen[scenario.name],
                scenario.name
            )
        }
    }
}
