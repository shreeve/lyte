// The video-decision vector-file model and the scenario replay both its
// builder and its test run: `Wire/Vectors/video-decisions-v1.json`
// freezes, for every assembly scenario in video-v1.json, the assembler's
// whole ordered decision stream — decodes, skips, fec-impossible
// verdicts, NACK candidates, repairs, evictions and drops — not only the
// decodes video-v1.json pins.

import Foundation
import LyteCore
import LyteWire

/// One vector file: `Wire/Vectors/video-decisions-v1.json`.
public struct VideoDecisionVectorFile: FrozenVectorFile {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    /// The file whose frames and scenarios these decisions replay.
    public var scenarioFile: String
    /// "pinned-self-consistent": the assembler's own recorded output,
    /// frozen so any policy drift is loud.
    public var provenance: String
    public var scenarios: [VideoDecisionScenario]

    public static let expectedFormat = "lyte-wire-video-decision-vectors"
    public static let fileName = "video-decisions-v1.json"

    public var vectorNameGroups: [[String]] {
        [scenarios.map(\.name)]
    }

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        scenarioFile: String,
        provenance: String,
        scenarios: [VideoDecisionScenario]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.scenarioFile = scenarioFile
        self.provenance = provenance
        self.scenarios = scenarios
    }
}

/// One scenario's frozen decision stream, one line per assembler event
/// in emission order (`videoDecisionLine`).
public struct VideoDecisionScenario: Codable, Sendable {
    /// A `VideoScenario.name` in the scenario file.
    public var name: String
    public var events: [String]

    public init(name: String, events: [String]) {
        self.name = name
        self.events = events
    }
}

/// Replays every scenario of a video vector file through a default
/// `VideoAssembler` over the envelope codec both ways, exactly as the
/// scenario's contract describes, returning each scenario's events.
public func replayVideoScenarios(
    _ file: VideoVectorFile, corpusDirectory: String
) throws -> [(scenario: VideoScenario, events: [VideoAssemblerEvent])] {
    var shardsByFrame: [String: [VideoShard]] = [:]
    for vector in file.frames {
        let bytes = try vector.source.loadBytes(corpusDirectory: corpusDirectory)
        guard let timestamp = Hex.uint64(vector.timestampHex),
              let regime = FecRegime(rawValue: vector.regime) else {
            throw VectorFileError.malformedField("\(vector.name) timestamp/regime")
        }
        var packetizer = VideoPacketizer(
            firstSeq: ChannelSeq(rawValue: vector.firstSeq)
        )
        shardsByFrame[vector.name] = try packetizer.packetize(
            frame: bytes,
            frameNumber: FrameNumber(rawValue: vector.frameNumber),
            captureTimestamp: HostTimestamp(microseconds: timestamp),
            isIDR: vector.isIDR,
            regime: regime
        )
    }
    return try file.scenarios.map { scenario in
        var assembler = VideoAssembler()
        let now = ClientTimestamp(microseconds: 0)
        var events: [VideoAssemblerEvent] = []
        for step in scenario.steps {
            guard let shards = shardsByFrame[step.frame],
                  shards.indices.contains(step.shardIndex) else {
                throw VectorFileError.malformedField(
                    "\(scenario.name): step \(step.frame)#\(step.shardIndex)"
                )
            }
            let (envelope, payload) = try Envelope.decode(
                try shards[step.shardIndex].encodeDatagram()
            )
            events += assembler.ingest(
                envelope: envelope, payload: payload, now: now
            )
        }
        if let tick = scenario.finalTickMicroseconds {
            events += assembler.evictStale(
                now: ClientTimestamp(microseconds: UInt64(tick))
            )
        }
        return (scenario, events)
    }
}

/// The frozen text of one assembler event: every field that is a
/// decision, none that restates the frame's bytes (video-v1.json pins
/// those).
public func videoDecisionLine(_ event: VideoAssemblerEvent) -> String {
    switch event {
    case .decoded(let unit):
        return "decoded \(unit.frameNumber.rawValue) idr \(unit.isIDR)"
    case .framesSkipped(let from, let through, let reason):
        return "framesSkipped \(from.rawValue)...\(through.rawValue) \(reason)"
    case .fecImpossible(let frame, let lost, let parity):
        return "fecImpossible \(frame.rawValue) presumedLostData \(lost) bestCaseParity \(parity)"
    case .nackCandidates(let frame, let seqs, let indices, let parity, let age):
        return "nackCandidates \(frame.rawValue) seqs \(seqs.map(\.rawValue)) "
            + "shards \(indices) parity \(parity) ageMicros \(age)"
    case .repairShardAccepted(let frame, let index):
        return "repairShardAccepted \(frame.rawValue) shard \(index)"
    case .evicted(let frame, let reason):
        return "evicted \(frame.rawValue) \(reason)"
    case .shardDropped(let reason):
        switch reason {
        case .wrongChannel(let channel):
            return "shardDropped wrongChannel \(channel.rawValue)"
        case .malformedFecField:
            return "shardDropped malformedFecField"
        case .payloadLengthMismatch(let index, let expected, let actual):
            return "shardDropped payloadLengthMismatch shard \(index) expected \(expected) actual \(actual)"
        case .staleFrame(let frame):
            return "shardDropped staleFrame \(frame.rawValue)"
        case .inconsistentGroup(let frame):
            return "shardDropped inconsistentGroup \(frame.rawValue)"
        case .duplicateShard(let frame, let index):
            return "shardDropped duplicateShard \(frame.rawValue) shard \(index)"
        }
    }
}
