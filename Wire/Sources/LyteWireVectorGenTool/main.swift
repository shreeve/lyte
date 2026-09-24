// Authoring tool for the Wire/Vectors/ artifacts. Run once per file,
// commit the output, and treat the committed file as frozen: a byte
// difference against it is a wire-contract break to investigate, never a
// prompt to regenerate. See Vectors/README.md for the freeze policy.
//
// `video` reads the corpus from <output-dir>/video-corpus-v1/.
// `video-roundtrip` is the decode-evidence harness (VideoRoundTrip.swift).

import Foundation
import LyteWireTestKit
import LyteWireVectorGen

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

/// Every vector kind and its builder; the argument is the output path.
let builders: KeyValuePairs<String, (String) throws -> any FrozenVectorFile> = [
    "envelope": { _ in try makeEnvelopeVectorFile() },
    "fec": { _ in try makeFecVectorFile() },
    "video": { output in
        try makeVideoVectorFile(corpusDirectory: URL(fileURLWithPath: output)
            .deletingLastPathComponent().path + "/video-corpus-v1")
    },
    "beacon": { _ in try makeBeaconVectorFile() },
    "noise": { _ in try makeNoiseVectorFile() },
    "session": { _ in try makeSessionVectorFile() },
    "arq": { _ in try makeArqVectorFile() },
    "lifecycle": { _ in try makeLifecycleVectorFile() },
    "pairing": { _ in try makePairingVectorFile() },
    "capabilities": { _ in try makeCapabilityVectorFile() },
    "retry": { _ in try makeRetryVectorFile() },
    "control": { _ in try makeControlVectorFile() },
    "clipboard": { _ in try makeClipboardVectorFile() },
    "bulk": { _ in try makeBulkVectorFile() },
    "clipboard-images": { _ in try makeClipboardImageVectorFile() },
    "cursor": { _ in try makeCursorVectorFile() },
    "repair-refusal": { _ in try makeRepairRefusalVectorFile() },
    "postures": { _ in try makePostureVectorFile() },
    "input-coordinates": { _ in try makeInputCoordinateVectorFile() },
]

let arguments = CommandLine.arguments
guard (3...4).contains(arguments.count) else {
    die("""
    usage: lyte-wire-vectorgen <\(builders.map(\.key).joined(separator: "|"))> <output-path>
           lyte-wire-vectorgen video-roundtrip <input.hevc> <output.hevc>
    """)
}
if arguments[1] == "video-roundtrip" {
    try runVideoRoundTrip(
        inputPath: arguments[2],
        outputPath: arguments.count > 3 ? arguments[3] : arguments[2] + ".roundtrip"
    )
    exit(0)
}
guard let build = builders.first(where: { $0.key == arguments[1] })?.value else {
    die("unknown vector kind '\(arguments[1])' — expected \(builders.map(\.key).joined(separator: ", ")), or video-roundtrip")
}
let file = try build(arguments[2])
try file.canonicalJSON().write(to: URL(fileURLWithPath: arguments[2]))
print("wrote \(file.vectorNameGroups.joined().count) vectors to \(arguments[2])")
