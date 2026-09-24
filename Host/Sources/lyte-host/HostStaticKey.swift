// The host's pinned Noise static keypair: generated once, persisted 0600
// (SecretFile), and its public half printed and advertised so a client can
// pin it (pairing's PIN-PAKE carries it too).

import HostIO
import LyteCore
import LyteWire

enum HostStaticKey {
    static let fileName = "noise_static.key"

    /// Loads the persisted static (adopting a legacy copy — HostPaths), or
    /// mints and persists a fresh one on first run. Raw 32-byte X25519
    /// private key, mode 0600, beside paired_clients; the public key
    /// derives and is never stored. Loud on a corrupt file: a wrong-sized
    /// key is someone else's write, never something to regenerate over
    /// silently. The mint is create-if-absent: when two starters race,
    /// one key lands and both run with it.
    static func loadOrCreate(paths: HostPaths) throws -> NoiseKeyPair {
        let path = try HostIdentityFile.path(fileName, paths: paths)
        if let pair = try load(path) {
            return pair
        }
        let pair = NoiseKeyPair.generate()
        if try SecretFile.create(pair.privateKey, at: path) {
            print("noise: generated host static key → \(path)")
            return pair
        }
        guard let winner = try load(path) else {
            throw HostError("host static key at \(path) vanished while minting")
        }
        print("noise: another starter minted the host static key first — using it")
        return winner
    }

    private static func load(_ path: String) throws -> NoiseKeyPair? {
        guard let bytes = try SecretFile.read(path) else { return nil }
        guard bytes.count == 32 else {
            throw HostError("""
                host static key at \(path) is \(bytes.count) bytes, \
                expected 32 — refusing to overwrite; move it aside to \
                re-key
                """)
        }
        return try NoiseKeyPair(privateKey: bytes)
    }

    static func loadOrCreate() throws -> NoiseKeyPair {
        try loadOrCreate(paths: HostPaths.current())
    }
}

/// Resolves an identity file through HostPaths and prints the one-line
/// note when a legacy copy was adopted.
enum HostIdentityFile {
    static func path(_ name: String, paths: HostPaths) throws -> String {
        let (path, note) = try paths.adoptConfigFile(name)
        if let note { print(note) }
        return path
    }
}
