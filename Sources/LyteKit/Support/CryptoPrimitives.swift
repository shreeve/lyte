import Foundation
import Crypto
import CommonCrypto

/// Crypto building blocks for the Moonlight pairing protocol (Sunshine / Gen 7+).
public enum PairingCrypto {

    /// AES key = SHA-256(salt || pin-ascii), truncated to 16 bytes.
    public static func aesKey(salt: Data, pin: String) -> Data {
        var material = salt
        material.append(Data(pin.utf8))
        return Data(SHA256.hash(data: material)).prefix(16)
    }

    /// AES-128-ECB, no padding. Input must be a multiple of 16 bytes.
    public static func aesEcb(_ operation: CCOperation, key: Data, data: Data) throws -> Data {
        precondition(key.count == kCCKeySizeAES128)
        precondition(data.count % kCCBlockSizeAES128 == 0, "ECB input must be block-aligned")
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, key.count, nil,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, outCapacity, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw LyteError.crypto("AES-ECB failed: \(status)") }
        return out.prefix(moved)
    }

    public static func encryptEcb(key: Data, data: Data) throws -> Data {
        try aesEcb(CCOperation(kCCEncrypt), key: key, data: data)
    }

    public static func decryptEcb(key: Data, data: Data) throws -> Data {
        try aesEcb(CCOperation(kCCDecrypt), key: key, data: data)
    }

    public static func sha256(_ chunks: Data...) -> Data {
        var h = SHA256()
        for c in chunks { h.update(data: c) }
        return Data(h.finalize())
    }
}

public enum LyteError: Error, CustomStringConvertible {
    case crypto(String)
    case http(String)
    case host(String)
    case pairing(String)
    case identity(String)

    public var description: String {
        switch self {
        case .crypto(let m): return "crypto: \(m)"
        case .http(let m): return "http: \(m)"
        case .host(let m): return "host: \(m)"
        case .pairing(let m): return "pairing: \(m)"
        case .identity(let m): return "identity: \(m)"
        }
    }
}
