// The paired-clients keystore file: the Foundation leaf under HostWire's
// ClientKeystore codec. Lives beside the host static and never touches
// it: pairing pins CLIENT statics into its own file only.

import Foundation
import HostWire

enum PairedClients {
    static let path = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyte-host/paired_clients")

    /// A missing file is an empty store (nothing paired yet); a
    /// malformed one is loud — trust contents are never guessed at.
    static func load() throws -> ClientKeystore {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return ClientKeystore()
        }
        let data = try Data(contentsOf: path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostError("""
                paired-clients store at \(path.path) is not \
                UTF-8 — refusing to guess; move it aside to reset
                """)
        }
        do {
            return try ClientKeystore.parse(text)
        } catch let ClientKeystore.ParseError.malformedLine(line, contents) {
            throw HostError("""
                paired-clients store at \(path.path) line \
                \(line) is malformed (\"\(contents)\") — refusing to \
                guess; fix or move it aside
                """)
        }
    }

    /// Full rewrite (the codec's canonical-serialization rule), 0600
    /// like the host static, atomically (SecretFile) — a crash mid-write
    /// never leaves a torn store that locks every client out.
    static func save(_ store: ClientKeystore) throws {
        try SecretFile.write(Array(store.serialized().utf8), to: path)
    }
}
