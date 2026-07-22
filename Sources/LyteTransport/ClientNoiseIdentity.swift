// The client's persistent Noise static identity (CL-6): one X25519 key
// pair per Mac, minted on first pairing, presented in message 1 of every
// Noise IK handshake thereafter. The host pins exactly this public key at
// pairing and `--require-paired` admits only pinned statics — so the
// private half must survive relaunches and rebuilds, and it must never
// sit in a plain file (it IS the client's authentication credential; the
// host's file-based `noise_static.key` answers to a different threat
// model — a headless box the operator owns end to end).
//
// Storage: a generic-password item in the login Keychain holding the raw
// 32-byte private key. The ClientIdentity lesson (HANDOFF #9) does not
// transfer literally — `SecKeyCreateRandomKey(kSecAttrIsPermanent)` only
// mints RSA/EC-P256 keys, never X25519 — so `SecItemAdd` is the only
// door, and that door has the macOS 26 constraint the signing workflow
// exists for: an UNSIGNED binary has no stable code identity, so the
// item's ACL re-prompts (or denies) on every rebuild. Anything touching
// this identity must be built via `Scripts/build-cli.sh` /
// `Scripts/make-app.sh` — the stable "Lyte Dev" signature is what makes
// the one-time Keychain approval stick (docs/MACOS-SIGNING.md).
//
// The plain `swift test` runner is unsigned, so unit tests never call
// into this file's Keychain paths; the live pairing gate (signed
// lyte-cli against the real host) is where this code is proven.

import Foundation
import LyteWire
import Security

public enum ClientNoiseIdentityError: Error, Sendable {
    /// A Keychain call failed; the OSStatus names the reason
    /// (-34018 = missing entitlement/unsigned-binary denial — rebuild
    /// via Scripts/build-cli.sh).
    case keychain(OSStatus)
    /// The stored item exists but is not a well-formed 32-byte X25519
    /// private key — never expected; refuse loudly rather than mint a
    /// silent replacement (the host has the OLD public key pinned).
    case corruptStoredKey
}

public enum ClientNoiseIdentity {
    /// The generic-password coordinates. Service + account are the
    /// item's identity; the label is what Keychain Access shows.
    public static let service = "dev.shreeve.lyte.noise-identity"
    public static let account = "client-static"
    static let label = "Lyte Client Noise Identity"

    /// The persisted identity, or nil when none exists yet (fresh
    /// install / never paired). Throws on Keychain errors other than
    /// not-found and on a corrupt stored key.
    public static func load() throws -> NoiseKeyPair? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: false,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ClientNoiseIdentityError.keychain(status)
        }
        guard let data = item as? Data, data.count == 32,
              let pair = try? NoiseKeyPair(privateKey: [UInt8](data))
        else {
            throw ClientNoiseIdentityError.corruptStoredKey
        }
        return pair
    }

    /// The persisted identity, minted and stored on first use. The
    /// private key never leaves this call unpersisted: generate → add →
    /// return, so a Keychain write failure means no identity was
    /// presented anywhere.
    public static func loadOrCreate() throws -> NoiseKeyPair {
        if let existing = try load() { return existing }
        let fresh = NoiseKeyPair.generate()
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: label,
            kSecUseDataProtectionKeychain: false,
            kSecValueData: Data(fresh.privateKey),
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Raced another process to first-mint: theirs won, use it.
            if let existing = try load() { return existing }
        }
        guard status == errSecSuccess else {
            throw ClientNoiseIdentityError.keychain(status)
        }
        return fresh
    }
}
