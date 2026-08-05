import Foundation
import Security

public enum HelperClientRequirementError: Error, Equatable {
    case security(operation: String, status: OSStatus)
    case unexpectedDesignatedRequirement
}

private final class RequirementResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?

    func store(_ result: Result<String, Error>) {
        lock.lock(); self.result = result; lock.unlock()
    }

    func take() -> Result<String, Error>? {
        lock.lock(); defer { lock.unlock() }
        let value = result
        result = nil
        return value
    }
}

/// Builds the exact app requirement enforced by the privileged helper's Mach
/// listener. The helper and app are signed together; deriving from the running
/// helper preserves that exact signer for both supported development identities
/// while changing only the peer's required code identifier.
public enum HelperClientRequirement {
    public static let helperIdentifier = "dev.shreeve.lyte-helperd"
    public static let applicationIdentifier = "dev.shreeve.lyte"

    public static func applicationRequirement(
        fromHelperDesignatedRequirement helperRequirement: String
    ) throws -> String {
        let helperClause = "identifier \"\(helperIdentifier)\""
        let applicationClause = "identifier \"\(applicationIdentifier)\""
        let matches = helperRequirement.components(
            separatedBy: helperClause).count - 1
        guard matches == 1 else {
            throw HelperClientRequirementError
                .unexpectedDesignatedRequirement
        }

        let result = helperRequirement.replacingOccurrences(
            of: helperClause, with: applicationClause)
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(
            result as CFString, [], &compiled)
        guard status == errSecSuccess, compiled != nil else {
            throw HelperClientRequirementError.security(
                operation: "SecRequirementCreateWithString", status: status)
        }
        return result
    }

    /// Security may consult trust services while validating the certificate.
    /// Keep that one-time startup work off a daemon's listener thread.
    public static func forCurrentProcess() throws -> String {
        let completed = DispatchSemaphore(value: 0)
        let box = RequirementResultBox()
        DispatchQueue.global(qos: .utility).async {
            box.store(Result { try currentProcessRequirement() })
            completed.signal()
        }
        completed.wait()
        guard let result = box.take() else {
            throw HelperClientRequirementError
                .unexpectedDesignatedRequirement
        }
        return try result.get()
    }

    private static func currentProcessRequirement() throws -> String {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            throw HelperClientRequirementError.security(
                operation: "SecCodeCopySelf", status: status)
        }

        status = SecCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else {
            throw HelperClientRequirementError.security(
                operation: "SecCodeCheckValidity", status: status)
        }

        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw HelperClientRequirementError.security(
                operation: "SecCodeCopyStaticCode", status: status)
        }

        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(
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
        return try applicationRequirement(
            fromHelperDesignatedRequirement: text as String)
    }
}
