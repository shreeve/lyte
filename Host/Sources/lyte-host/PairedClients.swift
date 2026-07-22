// The paired-clients keystore file (HS-9): the Foundation leaf under
// HostWire's ClientKeystore codec. Lives beside the portal token and
// the host static — and touches NEITHER: pairing pins CLIENT statics
// into its own file; ~/.config/lyte-host/{portal_token,noise_static.key}
// are never written by this path.

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
            throw HostError("paired-clients store at \(path.path) is not "
                + "UTF-8 — refusing to guess; move it aside to reset")
        }
        do {
            return try ClientKeystore.parse(text)
        } catch let ClientKeystore.ParseError.malformedLine(line, contents) {
            throw HostError("paired-clients store at \(path.path) line "
                + "\(line) is malformed (\"\(contents)\") — refusing to "
                + "guess; fix or move it aside")
        }
    }

    /// Full rewrite (the codec's canonical-serialization rule), 0600
    /// like its keyfile neighbors.
    static func save(_ store: ClientKeystore) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(store.serialized().utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path.path
        )
    }
}
