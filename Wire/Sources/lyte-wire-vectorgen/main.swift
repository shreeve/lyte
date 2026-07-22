// Authoring tool for the Wire/Vectors/ artifacts. Run once per file,
// commit the output, and treat the committed file as frozen: a byte
// difference against it is a wire-contract break to investigate, never a
// prompt to regenerate. See Vectors/README.md for the freeze policy and
// each file's anchor against hand-computed bytes.
//
// Usage: swift run lyte-wire-vectorgen <envelope|fec|video|beacon|noise|session|arq|lifecycle|pairing|capabilities|retry> <output-path>
//   `video` reads the corpus from <output-dir>/video-corpus-v1/.
//
// The `video-roundtrip` subcommand is not an authoring tool but the
// W-G3 decode-evidence harness: it packetizes an Annex-B file, runs the
// shards through seeded shuffle + per-group loss at the parity limit,
// assembles, verifies byte-exactness, and writes the reassembled stream
// for an external `ffmpeg -f null -` decode check.
// Usage: swift run lyte-wire-vectorgen video-roundtrip <in.hevc> <out.hevc>

import Foundation
import LyteWire
import LyteWireTestKit

func counting(from offset: Int, count: Int) -> [UInt8] {
    (0..<count).map { UInt8((offset + $0) & 0xFF) }
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

guard (3...4).contains(CommandLine.arguments.count) else {
    die("""
    usage: lyte-wire-vectorgen <envelope|fec|video|beacon|noise|session|arq|lifecycle|pairing|capabilities|retry> <output-path>
           lyte-wire-vectorgen video-roundtrip <input.hevc> <output.hevc>
    """)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

let json: Data
let count: Int
switch CommandLine.arguments[1] {
case "envelope":
    let file = try makeEnvelopeVectorFile()
    json = try encoder.encode(file)
    count = file.vectors.count
case "fec":
    let file = try makeFecVectorFile()
    json = try encoder.encode(file)
    count = file.fieldVectors.count + file.geometryRows.count
        + file.recoveryMatrices.count
case "video":
    let outputDir = URL(fileURLWithPath: CommandLine.arguments[2])
        .deletingLastPathComponent().path
    let file = try makeVideoVectorFile(
        corpusDirectory: outputDir + "/video-corpus-v1"
    )
    json = try encoder.encode(file)
    count = file.frames.count + file.scenarios.count
case "beacon":
    let file = try makeBeaconVectorFile()
    json = try encoder.encode(file)
    count = file.beaconVectors.count + file.feedbackVectors.count + 1
case "noise":
    let file = try makeNoiseVectorFile()
    json = try encoder.encode(file)
    count = file.handshakeVectors.count + file.transportVectors.count
case "session":
    let file = try makeSessionVectorFile()
    json = try encoder.encode(file)
    count = file.vectors.count
case "arq":
    let file = try makeArqVectorFile()
    json = try encoder.encode(file)
    count = file.vectors.count
case "lifecycle":
    let file = try makeLifecycleVectorFile()
    json = try encoder.encode(file)
    count = file.vectors.count
case "pairing":
    let file = try makePairingVectorFile()
    json = try encoder.encode(file)
    count = file.exchangeVectors.count + file.messageVectors.count
        + file.draftVectors.lowOrder.cases.count
case "capabilities":
    let file = try makeCapabilityVectorFile()
    json = try encoder.encode(file)
    count = file.cborVectors.count + file.setVectors.count
        + file.intersectVectors.count + file.messageVectors.count
case "retry":
    let file = try makeRetryVectorFile()
    json = try encoder.encode(file)
    count = file.cookieVectors.count + file.messageVectors.count
case "video-roundtrip":
    try runVideoRoundTrip(
        inputPath: CommandLine.arguments[2],
        outputPath: CommandLine.arguments.count > 3
            ? CommandLine.arguments[3] : CommandLine.arguments[2] + ".roundtrip"
    )
    exit(0)
default:
    die("unknown vector kind '\(CommandLine.arguments[1])' — expected envelope, fec, video, beacon, noise, session, arq, lifecycle, pairing, capabilities, retry, or video-roundtrip")
}

try (json + Data("\n".utf8)).write(
    to: URL(fileURLWithPath: CommandLine.arguments[2])
)
print("wrote \(count) vectors to \(CommandLine.arguments[2])")
