// The host's pinned Noise static keypair: generated once, persisted 0600
// (SecretFile), and its public half printed and advertised so a client can
// pin it (pairing's PIN-PAKE carries it too).

import Foundation
import LyteCore
import LyteWire

enum HostStaticKey {
    /// Raw 32-byte X25519 private key, mode 0600, beside paired_clients.
    /// The public key derives; it is never stored.
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
                throw HostError("""
                    host static key at \(keyPath.path) is \
                    \(data.count) bytes, expected 32 — refusing to \
                    overwrite; move it aside to re-key
                    """)
            }
            return try NoiseKeyPair(privateKey: [UInt8](data))
        }
        let pair = NoiseKeyPair.generate()
        try SecretFile.write(pair.privateKey, to: keyPath)
        print("noise: generated host static key → \(keyPath.path)")
        return pair
    }
}
