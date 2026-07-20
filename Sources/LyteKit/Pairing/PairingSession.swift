import Foundation
import Security

/// The 5-stage Moonlight pairing handshake (Sunshine / Gen 7+, SHA-256).
///
/// Reference: docs/moonlight-macos.md §8, misc/moonlight-macos PairManager, Sunshine nvhttp.
///
///  1. getservercert (+salt, +client cert PEM)      → server cert   [blocks on PIN]
///  2. clientchallenge (AES-ECB encrypted)          → challengeresponse
///  3. serverchallengeresp (hash of server challenge ‖ our cert sig ‖ client secret)
///                                                   → pairingsecret (secret ‖ RSA sig)
///  4. verify server signature + expected-response hash (detects wrong PIN)
///  5. clientpairingsecret (secret ‖ our RSA sig), then pairchallenge over HTTPS
public struct PairingSession {
    public let client: HostClient
    public let identity: ClientIdentity

    public init(client: HostClient, identity: ClientIdentity) {
        self.client = client
        self.identity = identity
    }

    public struct Result: Sendable {
        public let serverCertDER: Data
        public let serverCertPEM: String
    }

    /// Generate a 4-digit PIN for the user to enter in the Sunshine web UI.
    public static func generatePIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    /// Run the full handshake. `pin` must already be displayed to the user —
    /// stage 1 blocks until they enter it on the host.
    public func pair(pin: String) async throws -> Result {
        let salt = Data.random(count: 16)
        let aesKey = PairingCrypto.aesKey(salt: salt, pin: pin)
        let base = client.baseQuery + [("devicename", "roth"), ("updateState", "1")]

        // Stage 1 — getservercert (blocks until PIN entered on host)
        let s1 = try await client.http.get("pair", query: base + [
            ("phrase", "getservercert"),
            ("salt", salt.hexString),
            ("clientcert", Data(identity.certificatePEM.utf8).hexString),
        ], https: false)
        guard s1["paired"] == "1", let plainCertHex = s1["plaincert"],
              let serverCertPEMData = Data(hexString: plainCertHex),
              let serverCertPEM = String(data: serverCertPEMData, encoding: .utf8) else {
            throw LyteError.pairing("stage 1 rejected (already pairing? bad state?)")
        }
        let serverCertDER = try PEM.der(fromPEM: serverCertPEM)

        // Stage 2 — encrypted client challenge
        let clientChallenge = Data.random(count: 16)
        let s2 = try await client.http.get("pair", query: base + [
            ("clientchallenge", try PairingCrypto.encryptEcb(key: aesKey, data: clientChallenge).hexString),
        ], https: false)
        guard s2["paired"] == "1", let encResponseHex = s2["challengeresponse"],
              let encResponse = Data(hexString: encResponseHex) else {
            throw LyteError.pairing("stage 2 rejected")
        }

        // Decrypt → serverResponse(32) ‖ serverChallenge(16)
        let decrypted = try PairingCrypto.decryptEcb(key: aesKey, data: encResponse)
        guard decrypted.count >= 48 else { throw LyteError.pairing("stage 2: short response") }
        let serverResponse = decrypted.prefix(32)
        let serverChallenge = decrypted.dropFirst(32).prefix(16)

        // Stage 3 — prove we know the PIN and own our cert
        let clientSecret = Data.random(count: 16)
        let challengeHash = PairingCrypto.sha256(
            Data(serverChallenge), try identity.certificateSignature, clientSecret)
        let s3 = try await client.http.get("pair", query: base + [
            ("serverchallengeresp", try PairingCrypto.encryptEcb(key: aesKey, data: challengeHash).hexString),
        ], https: false)
        guard s3["paired"] == "1", let pairingSecretHex = s3["pairingsecret"],
              let pairingSecret = Data(hexString: pairingSecretHex),
              pairingSecret.count > 16 else {
            throw LyteError.pairing("stage 3 rejected")
        }
        let serverSecret = pairingSecret.prefix(16)
        let serverSignature = pairingSecret.dropFirst(16)

        // Stage 4 — authenticate the host, detect wrong PIN
        try verifyServerSignature(certDER: serverCertDER,
                                  message: Data(serverSecret), signature: Data(serverSignature))
        let expectedResponse = PairingCrypto.sha256(
            clientChallenge,
            try ClientIdentity.signatureBytes(fromCertDER: serverCertDER),
            Data(serverSecret))
        guard expectedResponse == serverResponse else {
            _ = try? await unpair()
            throw LyteError.pairing("PIN mismatch (server response hash incorrect)")
        }

        // Stage 5 — send our signed secret, then confirm over HTTPS
        let clientPairingSecret = clientSecret + (try identity.sign(clientSecret))
        let s5 = try await client.http.get("pair", query: base + [
            ("clientpairingsecret", clientPairingSecret.hexString),
        ], https: false)
        guard s5["paired"] == "1" else { throw LyteError.pairing("stage 5 rejected") }

        let httpsClient = HostClient(address: client.http.address, uniqueID: client.uniqueID,
                                     identity: identity, pinnedServerCertDER: serverCertDER)
        let s6 = try await httpsClient.http.get("pair", query: httpsClient.baseQuery + [
            ("devicename", "roth"), ("updateState", "1"), ("phrase", "pairchallenge"),
        ], https: true)
        guard s6["paired"] == "1" else { throw LyteError.pairing("HTTPS pairchallenge rejected") }

        return Result(serverCertDER: serverCertDER, serverCertPEM: serverCertPEM)
    }

    public func unpair() async throws {
        _ = try? await client.http.get("unpair", query: client.baseQuery, https: false)
    }

    private func verifyServerSignature(certDER: Data, message: Data, signature: Data) throws {
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData),
              let key = SecCertificateCopyKey(cert) else {
            throw LyteError.pairing("cannot extract server public key")
        }
        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                       message as CFData, signature as CFData, &error)
        guard ok else { throw LyteError.pairing("server signature invalid — MITM or corrupt host") }
    }
}
