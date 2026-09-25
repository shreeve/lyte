// Authoring tool for the Wire/Vectors/ artifacts: writes one builder's
// file for a NEW vector file. A committed file is frozen, so the tool
// refuses to replace an existing path unless `--force` is given (for a
// scratch comparison, never for Wire/Vectors/). See Vectors/README.md for
// the freeze policy.
//
// `video` always reads the committed corpus, Wire/Vectors/video-corpus-v1/.

import Foundation
import LyteWireTestKit
import LyteWireVectorGen

/// Usage errors exit 64 (EX_USAGE); runtime failures exit 1.
func die(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let kinds = vectorFileBuilders.map(\.kind)
let usage = "usage: lyte-wire-vectorgen [--force] <\(kinds.joined(separator: "|"))> <output-path>"

var arguments = Array(CommandLine.arguments.dropFirst())
let force = arguments.first == "--force"
if force { arguments.removeFirst() }
guard arguments.count == 2 else { die(usage, status: 64) }
guard let builder = vectorFileBuilders.first(where: { $0.kind == arguments[0] }) else {
    die("unknown vector kind '\(arguments[0])' — expected \(kinds.joined(separator: ", "))", status: 64)
}
let output = arguments[1]
if !force, FileManager.default.fileExists(atPath: output) {
    die("\(output) exists; committed vector files are frozen. New cases go in a new file; pass --force only to overwrite a scratch copy.")
}
do {
    let file = try builder.build()
    try file.canonicalJSON().write(to: URL(fileURLWithPath: output))
    print("wrote \(file.vectorNameGroups.joined().count) vectors to \(output)")
} catch {
    die("\(builder.kind): \(error)")
}
