// The paired-clients keystore file: the Foundation leaf under HostWire's
// ClientKeystore codec. Lives beside the host static and never touches
// it: pairing pins CLIENT statics into its own file only.

import HostIO
import HostWire

enum PairedClients {
    static let fileName = "paired_clients"

    /// The keystore path (adopting a legacy copy — HostPaths).
    static func path(paths: HostPaths) throws -> String {
        try HostIdentityFile.path(fileName, paths: paths)
    }

    /// A missing file is an empty store (nothing paired yet); a
    /// malformed one is loud — trust contents are never guessed at.
    static func load(paths: HostPaths) throws -> ClientKeystore {
        let path = try path(paths: paths)
        guard let bytes = try SecretFile.read(path) else {
            return ClientKeystore()
        }
        guard let text = String(validating: bytes, as: UTF8.self) else {
            throw HostError("""
                paired-clients store at \(path) is not \
                UTF-8 — refusing to guess; move it aside to reset
                """)
        }
        do {
            return try ClientKeystore.parse(text)
        } catch let ClientKeystore.ParseError.malformedLine(line, contents) {
            throw HostError("""
                paired-clients store at \(path) line \(line) is malformed \
                (\"\(contents)\") — refusing to guess; fix or move it aside
                """)
        }
    }

    /// Full canonical rewrite, 0600, atomically (SecretFile) — a crash
    /// mid-write never leaves a torn store. Only ever the new location.
    static func save(_ store: ClientKeystore, paths: HostPaths) throws {
        try SecretFile.write(Array(store.serialized().utf8), to: path(paths: paths))
    }
}
