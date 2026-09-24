// Authors Vectors/video-decisions-v1.json: every video-v1.json assembly
// scenario replayed through the default assembler, its whole ordered
// event stream frozen. Pinned self-consistent: no external oracle covers
// assembler policy, so the file exists to make any drift in drop, skip,
// NACK or eviction decisions loud.

import LyteWire
import LyteWireTestKit

public func makeVideoDecisionVectorFile(
    corpusDirectory: String
) throws -> VideoDecisionVectorFile {
    let video = try makeVideoVectorFile(corpusDirectory: corpusDirectory)
    let replays = try replayVideoScenarios(video, corpusDirectory: corpusDirectory)
    return VideoDecisionVectorFile(
        format: VideoDecisionVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: 1,
        scenarioFile: VideoVectorFile.fileName,
        provenance: "pinned-self-consistent",
        scenarios: replays.map {
            VideoDecisionScenario(
                name: $0.scenario.name, events: $0.events.map(videoDecisionLine)
            )
        }
    )
}
