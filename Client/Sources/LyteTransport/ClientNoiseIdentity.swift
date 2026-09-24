// The client's persistent Noise static identity: one X25519 key pair per
// Mac, minted on first pairing and presented in every IK handshake. The
// host pins exactly this public key, so the private half must survive
// rebuilds and never sit in a plain file.
//
// Stored as a generic-password login-Keychain item holding the raw 32-byte
// private key (SecKey cannot mint X25519). An unsigned binary's ACL
// re-prompts on every rebuild, so anything touching this identity must be
// built via `Scripts/build-cli.sh` or `Scripts/make-app.sh`
// (docs/MACOS-SIGNING.md). Unit tests never call the Keychain paths.

import Dispatch
import Foundation
import LocalAuthentication
import LyteWire
import Security

public enum ClientNoiseIdentityError: Error, Sendable {
    /// A Keychain call failed; the OSStatus names the reason
    /// (-34018 = missing entitlement/unsigned-binary denial — rebuild
    /// via Scripts/build-cli.sh).
    case keychain(OSStatus)
    /// The stored item is not a well-formed 32-byte X25519 private key;
    /// refuse rather than mint a replacement the host has not pinned.
    case corruptStoredKey
}

public enum ClientNoiseIdentity {
    /// Service + account are the item's identity; the label is display.
    public static let service = "dev.shreeve.lyte.noise-identity"
    public static let account = "client-static"
    static let label = "Lyte Client Noise Identity"

    /// The persisted identity, or nil when none exists yet. Throws on
    /// other Keychain errors and on a corrupt stored key.
    public static func load(
        allowAuthenticationUI: Bool = true
    ) throws -> NoiseKeyPair? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: false,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if !allowAuthenticationUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }
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

    /// The persisted identity, minted and stored on first use; a key is
    /// never returned unpersisted.
    public static func loadOrCreate(
        allowAuthenticationUI: Bool = true
    ) throws -> NoiseKeyPair {
        try loadOrCreate(
            allowAuthenticationUI: allowAuthenticationUI,
            load: { try load(allowAuthenticationUI: $0) },
            add: { fresh in
                let add: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: service,
                    kSecAttrAccount: account,
                    kSecAttrLabel: label,
                    kSecUseDataProtectionKeychain: false,
                    kSecValueData: Data(fresh.privateKey),
                ]
                return SecItemAdd(add as CFDictionary, nil)
            })
    }

    /// The mint-or-load decision over injected Keychain calls. Every load,
    /// the duplicate-item re-read included, carries the caller's
    /// authentication-UI policy.
    static func loadOrCreate(
        allowAuthenticationUI: Bool,
        load: (Bool) throws -> NoiseKeyPair?,
        add: (NoiseKeyPair) -> OSStatus
    ) throws -> NoiseKeyPair {
        if let existing = try load(allowAuthenticationUI) { return existing }
        let fresh = NoiseKeyPair.generate()
        let status = add(fresh)
        if status == errSecDuplicateItem {
            // Another process minted first: its key is the identity.
            if let existing = try load(allowAuthenticationUI) {
                return existing
            }
        }
        guard status == errSecSuccess else {
            throw ClientNoiseIdentityError.keychain(status)
        }
        return fresh
    }
}

/// One process-wide door to the blocking login-Keychain API. Explicit
/// Pair/Connect may show authorization UI; automatic roaming never does.
/// Successful identity bytes are cached for the process lifetime.
public final class ClientNoiseIdentityProvider: @unchecked Sendable {
    public static let shared = ClientNoiseIdentityProvider()

    public enum AuthenticationUI: Equatable, Sendable {
        case allow
        case fail
    }

    public typealias Loader = @Sendable (AuthenticationUI) throws
        -> NoiseKeyPair

    private let queue = DispatchQueue(
        label: "lyte.keychain.identity", qos: .userInitiated)
    private let cacheLock = NSLock()
    private var cached: NoiseKeyPair?
    private let loader: Loader

    public init(loader: @escaping Loader = { policy in
        try ClientNoiseIdentity.loadOrCreate(
            allowAuthenticationUI: policy == .allow)
    }) {
        self.loader = loader
    }

    /// Never waits behind an in-flight Keychain call.
    public var cachedIdentity: NoiseKeyPair? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cached
    }

    public func identity(
        authenticationUI: AuthenticationUI = .allow
    ) async throws -> NoiseKeyPair {
        if let cachedIdentity { return cachedIdentity }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let cachedIdentity {
                    continuation.resume(returning: cachedIdentity)
                    return
                }
                do {
                    let identity = try loader(authenticationUI)
                    cacheLock.lock()
                    cached = identity
                    cacheLock.unlock()
                    continuation.resume(returning: identity)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
