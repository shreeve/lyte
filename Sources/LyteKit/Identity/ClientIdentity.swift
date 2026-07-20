import Foundation
import Crypto
import _CryptoExtras
import X509
import SwiftASN1
@preconcurrency import Security

/// The client's pairing identity: an RSA-2048 key + self-signed certificate,
/// stored in the login Keychain (key by application tag, cert by label) so it
/// survives relaunches. Sunshine identifies a paired client by this certificate.
public struct ClientIdentity: Sendable {
    public static let keyTag = "dev.shreeve.lyte.identity"
    public static let certLabel = "Lyte Client Identity"

    public let certificateDER: Data

    private let keyRef: SecKey

    /// PEM form of the certificate (what pairing sends, hex-encoded).
    public var certificatePEM: String {
        let b64 = certificateDER.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
    }

    /// The certificate's signature bytes (the signatureValue BIT STRING) —
    /// a pairing-protocol ingredient.
    public var certificateSignature: Data {
        get throws { try Self.signatureBytes(fromCertDER: certificateDER) }
    }

    /// RSA-PKCS1v1.5-SHA256 signature with the client private key.
    public func sign(_ message: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            keyRef, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) as Data?
        else {
            throw LyteError.identity("signing failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return sig
    }

    /// SecIdentity for TLS client authentication (HTTPS 47984).
    public func secIdentity() throws -> SecIdentity {
        guard let cert = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw LyteError.identity("bad cert DER")
        }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard status == errSecSuccess, let identity else {
            throw LyteError.identity("SecIdentityCreateWithCertificate: \(status)")
        }
        return identity
    }

    // MARK: - Load or create

    /// Load the identity: certificate DER travels in the client store (it is
    /// public); the private key is found in the Keychain by application tag
    /// (labels on certs are unreliable — macOS rewrites them from the CN).
    public static func load(certificatePEM: String) throws -> ClientIdentity {
        let der = try PEM.der(fromPEM: certificatePEM)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              let certPubKey = SecCertificateCopyKey(cert),
              let certPubDER = SecKeyCopyExternalRepresentation(certPubKey, nil) as Data? else {
            throw LyteError.identity("cannot parse stored certificate")
        }
        let keyQuery: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(keyTag.utf8),
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecUseDataProtectionKeychain: false,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]
        var keyItems: CFTypeRef?
        guard SecItemCopyMatching(keyQuery as CFDictionary, &keyItems) == errSecSuccess,
              let candidates = keyItems as? [SecKey], !candidates.isEmpty else {
            throw LyteError.identity("no stored private key")
        }
        // Multiple keys can share the tag (e.g. an interrupted pairing attempt) —
        // pick the one whose public key matches the certificate.
        for key in candidates {
            if let pub = SecKeyCopyPublicKey(key),
               let pubDER = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
               pubDER == certPubDER {
                return ClientIdentity(certificateDER: der, keyRef: key)
            }
        }
        throw LyteError.identity("no private key matches the stored certificate")
    }

    /// In-memory identity that is never persisted — for tests and previews.
    public static func createEphemeral() throws -> ClientIdentity {
        try create(persist: false)
    }

    public static func create() throws -> ClientIdentity {
        try create(persist: true)
    }

    static func create(persist: Bool) throws -> ClientIdentity {
        if persist {
            return try createInKeychain()
        }
        // Ephemeral: generate with swift-crypto so swift-certificates can self-sign.
        let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let certKey = Certificate.PrivateKey(rsa)

        let name = try DistinguishedName { CommonName("Lyte") }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certKey.publicKey,
            notValidBefore: now.addingTimeInterval(-86400),
            notValidAfter: now.addingTimeInterval(86400 * 365 * 20),
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: certKey
        )
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let der = Data(serializer.serializedBytes)

        // Import the private key into the Keychain.
        let pkcs1 = try pkcs1PrivateKeyDER(from: rsa)
        let keyAttrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, keyAttrs as CFDictionary, &error) else {
            throw LyteError.identity("SecKeyCreateWithData: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return ClientIdentity(certificateDER: der, keyRef: secKey)
    }

    /// Persistent path: generate the key *inside* the login keychain
    /// (kSecAttrIsPermanent), then export it just long enough to self-sign the
    /// certificate with swift-certificates. Avoids SecItemAdd(kSecClassKey),
    /// which macOS 26 denies to unsigned processes (-34018).
    static func createInKeychain() throws -> ClientIdentity {
        let keyParams: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrLabel: certLabel,
            kSecUseDataProtectionKeychain: false,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: Data(keyTag.utf8),
                kSecAttrIsExtractable: true,
            ] as [CFString: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error) else {
            throw LyteError.identity("SecKeyCreateRandomKey: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let pkcs1 = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw LyteError.identity("key export: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let rsa = try _RSA.Signing.PrivateKey(derRepresentation: pkcs1)
        let certKey = Certificate.PrivateKey(rsa)

        let name = try DistinguishedName { CommonName("Lyte") }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certKey.publicKey,
            notValidBefore: now.addingTimeInterval(-86400),
            notValidAfter: now.addingTimeInterval(86400 * 365 * 20),
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: certKey
        )
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let der = Data(serializer.serializedBytes)

        guard let secCert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw LyteError.identity("cert DER rejected by Security")
        }
        let addCert: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: secCert,
            kSecAttrLabel: certLabel,
            kSecUseDataProtectionKeychain: false,
        ]
        let certStatus = SecItemAdd(addCert as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw LyteError.identity("keychain add cert: \(certStatus)")
        }

        return ClientIdentity(certificateDER: der, keyRef: secKey)
    }

    // MARK: - ASN.1 helpers

    /// Extract the signatureValue BIT STRING bytes from a DER certificate:
    /// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    public static func signatureBytes(fromCertDER der: Data) throws -> Data {
        let root = try DER.parse([UInt8](der))
        guard case .constructed(let children) = root.content else {
            throw LyteError.identity("cert: root not a sequence")
        }
        let nodes = Array(children)
        guard nodes.count == 3 else {
            throw LyteError.identity("cert: expected 3 elements, got \(nodes.count)")
        }
        let bitString = try ASN1BitString(derEncoded: nodes[2])
        return Data(bitString.bytes)
    }

    /// swift-crypto emits PKCS#8; SecKeyCreateWithData wants PKCS#1 for RSA.
    /// PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey OCTET STRING }
    static func pkcs1PrivateKeyDER(from key: _RSA.Signing.PrivateKey) throws -> Data {
        let der = key.derRepresentation
        let root = try DER.parse([UInt8](der))
        guard case .constructed(let children) = root.content else { return der } // already PKCS#1
        let nodes = Array(children)
        // PKCS#8 has [INTEGER version, SEQUENCE algId, OCTET STRING key];
        // PKCS#1 has [INTEGER version, INTEGER modulus, ...] (9 integers).
        if nodes.count == 3, nodes[2].identifier == .octetString {
            guard case .primitive(let content) = nodes[2].content else {
                throw LyteError.identity("pkcs8: octet string not primitive")
            }
            return Data(content)
        }
        return der
    }
}

/// PEM utilities for host certificates received during pairing.
public enum PEM {
    public static func der(fromPEM pem: String) throws -> Data {
        let lines = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
        guard let der = Data(base64Encoded: lines.joined()) else {
            throw LyteError.identity("bad PEM base64")
        }
        return der
    }
}
