// Authoring tool for the Wire/Vectors/ artifacts. Run once per file,
// commit the output, and treat the committed file as frozen: a byte
// difference against it is a wire-contract break to investigate, never a
// prompt to regenerate. See Vectors/README.md for the freeze policy and
// each file's anchor against hand-computed bytes.
//
// Usage: swift run lyte-wire-vectorgen <envelope|fec> <output-path>

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

guard CommandLine.arguments.count == 3 else {
    die("usage: lyte-wire-vectorgen <envelope|fec> <output-path>")
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
default:
    die("unknown vector kind '\(CommandLine.arguments[1])' — expected envelope or fec")
}

try (json + Data("\n".utf8)).write(
    to: URL(fileURLWithPath: CommandLine.arguments[2])
)
print("wrote \(count) vectors to \(CommandLine.arguments[2])")
