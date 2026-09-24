import Foundation
import Security

/// Which build a helper binary is. The helper's `version` answer is the XPC
/// protocol version plus the code-directory hash of its signed code, and the
/// app compares it against the hash of the helper embedded in its own bundle.
/// Every rebuild re-signs the helper and changes the hash, so a helper still
/// running from an earlier build answers a version the app does not expect,
/// and the app re-registers instead of trusting a stale launch requirement.
public enum HelperCodeIdentity {
    public static func versionAnswer(
        protocolVersion: String, codeHash: String
    ) -> String {
        "\(protocolVersion)+\(codeHash)"
    }

    /// The running process's code hash, read from its code on disk. A
    /// daemon reads it once at startup, before any rebuild can replace the
    /// file under it.
    public static func currentProcessCodeHash() throws -> String {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            throw HelperClientRequirementError.security(
                operation: "SecCodeCopySelf", status: status)
        }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw HelperClientRequirementError.security(
                operation: "SecCodeCopyStaticCode", status: status)
        }
        return try codeHash(of: staticCode)
    }

    /// The code hash of the signed code at `url`.
    public static func codeHash(ofCodeAt url: URL) throws -> String {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw HelperClientRequirementError.security(
                operation: "SecStaticCodeCreateWithPath", status: status)
        }
        return try codeHash(of: code)
    }

    /// Lowercase hex of the code directory hash; unsigned code has none.
    private static func codeHash(of code: SecStaticCode) throws -> String {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess,
              let fields = information as? [String: Any]
        else {
            throw HelperClientRequirementError.security(
                operation: "SecCodeCopySigningInformation", status: status)
        }
        guard let unique = fields[kSecCodeInfoUnique as String] as? Data,
              !unique.isEmpty
        else {
            throw HelperClientRequirementError.security(
                operation: "kSecCodeInfoUnique", status: errSecCSUnsigned)
        }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
