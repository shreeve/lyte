// The host's pinned Noise static keypair (HS-7): generated once, persisted
// like the portal token, printed so the J-G1 debug client can be handed the
// public key out-of-band (pairing — W6 PIN-PAKE — is what replaces this
// hand-carry later; the file and the print are the stub's whole key
// distribution story).

import Foundation
import LyteWire

enum HostStaticKey {
    /// Raw 32-byte X25519 private key, mode 0600, alongside the portal
    /// token. The public key derives; it is never stored.
    static let keyPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyte-host/noise_static.key")

    /// Loads the persisted static, or mints and persists a fresh one on
    /// first run. Loud on a corrupt file: a wrong-sized key is someone
    /// else's write, never something to regenerate over silently.
    static func loadOrCreate() throws -> NoiseKeyPair {
        if FileManager.default.fileExists(atPath: keyPath.path) {
            let data = try Data(contentsOf: keyPath)
            guard data.count == 32 else {
                throw HostError("host static key at \(keyPath.path) is "
                    + "\(data.count) bytes, expected 32 — refusing to "
                    + "overwrite; move it aside to re-key")
            }
            return try NoiseKeyPair(privateKey: [UInt8](data))
        }
        let pair = NoiseKeyPair.generate()
        try FileManager.default.createDirectory(
            at: keyPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(pair.privateKey).write(to: keyPath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyPath.path
        )
        print("noise: generated host static key → \(keyPath.path)")
        return pair
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
