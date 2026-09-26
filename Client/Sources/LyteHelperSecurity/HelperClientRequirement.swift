import Foundation
import Security

public enum HelperClientRequirementError: Error, Equatable {
    case security(operation: String, status: OSStatus)
    case unexpectedDesignatedRequirement
}

/// The two code requirements that bind Lyte.app and its privileged helper.
/// They are signed together, so each side derives the other's requirement
/// from its own validated designated requirement by changing only the code
/// identifier. That preserves the exact signer `sign-dev.sh` chose for both
/// supported development identities.
///
/// A derivable requirement names exactly one identifier clause, pins a
/// signer (an Apple anchor or an exact root certificate) and has no `or`
/// alternative, so the rewrite can never admit an ad-hoc or foreign signer.
public enum HelperClientRequirement {
    public static let helperIdentifier = "dev.shreeve.lyte-helperd"
    public static let applicationIdentifier = "dev.shreeve.lyte"

    /// The helper's Mach listener requirement: its own DR, app identifier.
    public static func applicationRequirement(
        fromHelperDesignatedRequirement helperRequirement: String
    ) throws -> String {
        try rewrite(
            helperRequirement, from: helperIdentifier,
            to: applicationIdentifier)
    }

    /// What the app demands of the helper it registers and talks to: its
    /// own DR, helper identifier.
    public static func helperRequirement(
        fromApplicationDesignatedRequirement applicationRequirement: String
    ) throws -> String {
        try rewrite(
            applicationRequirement, from: applicationIdentifier,
            to: helperIdentifier)
    }

    /// The helper side: the requirement its listener installs.
    public static func forCurrentProcess() throws -> String {
        try applicationRequirement(
            fromHelperDesignatedRequirement:
                currentProcessDesignatedRequirement())
    }

    /// The app side: the requirement the embedded helper must satisfy.
    public static func helperRequirementForCurrentProcess() throws -> String {
        try helperRequirement(
            fromApplicationDesignatedRequirement:
                currentProcessDesignatedRequirement())
    }

    /// Validates the code on disk at `url` — every architecture, strictly —
    /// and requires it to satisfy `requirement`.
    public static func validateStaticCode(
        at url: URL, satisfies requirement: String
    ) throws {
        var compiled: SecRequirement?
        var status = SecRequirementCreateWithString(
            requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            throw HelperClientRequirementError.security(
                operation: "SecRequirementCreateWithString", status: status)
        }
        var code: SecStaticCode?
        status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw HelperClientRequirementError.security(
                operation: "SecStaticCodeCreateWithPath", status: status)
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(code, flags, compiled)
        guard status == errSecSuccess else {
            throw HelperClientRequirementError.security(
                operation: "SecStaticCodeCheckValidity", status: status)
        }
    }

    private static func rewrite(
        _ requirement: String, from source: String, to target: String
    ) throws -> String {
        let sourceClause = "identifier \"\(source)\""
        let matches = requirement.components(separatedBy: sourceClause).count - 1
        let structure = unquoted(requirement)
        let pinsSigner = structure.contains("anchor apple generic")
            || structure.contains("certificate root = H")
        let hasAlternative = structure
            .components(separatedBy: .whitespacesAndNewlines).contains("or")
        guard matches == 1, pinsSigner, !hasAlternative else {
            throw HelperClientRequirementError
                .unexpectedDesignatedRequirement
        }

        let result = requirement.replacingOccurrences(
            of: sourceClause, with: "identifier \"\(target)\"")
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(
            result as CFString, [], &compiled)
        guard status == errSecSuccess, compiled != nil else {
            throw HelperClientRequirementError.security(
                operation: "SecRequirementCreateWithString", status: status)
        }
        return result
    }

    /// The requirement text with every quoted string blanked, so a signer
    /// name can never read as structure.
    private static func unquoted(_ text: String) -> String {
        var result = ""
        var quoted = false
        var escaped = false
        for character in text {
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                    result.append("\"")
                }
                continue
            }
            if character == "\"" { quoted = true }
            result.append(character)
        }
        return result
    }

    /// The running process's designated requirement, from its validated
    /// signature.
    private static func currentProcessDesignatedRequirement() throws -> String {
        let staticCode = try HelperCodeIdentity.currentStaticCode(validated: true)
        var requirement: SecRequirement?
        var status = SecCodeCopyDesignatedRequirement(
            staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw HelperClientRequirementError.security(
                operation: "SecCodeCopyDesignatedRequirement", status: status)
        }

        var text: CFString?
        status = SecRequirementCopyString(requirement, [], &text)
        guard status == errSecSuccess, let text else {
            throw HelperClientRequirementError.security(
                operation: "SecRequirementCopyString", status: status)
        }
        return text as String
    }
}
