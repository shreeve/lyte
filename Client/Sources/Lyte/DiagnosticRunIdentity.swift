import Foundation

/// A benchmark process proves its identity before connection work begins.
/// The matching command-line claim lets the harness attest the PID again
/// before it sends a signal; environment alone is not reliably observable
/// from another macOS process.
enum DiagnosticRunIdentity {
    static let argument = "--lyte-benchmark-run-id"

    enum ConfigurationError: LocalizedError {
        case incomplete
        case invalidRunID
        case mismatchedRunID
        case relativePIDFile
        case mismatchedPIDFile

        var errorDescription: String? {
            switch self {
            case .incomplete:
                return "incomplete benchmark process identity"
            case .invalidRunID:
                return "invalid benchmark run identifier"
            case .mismatchedRunID:
                return "benchmark environment and argument disagree"
            case .relativePIDFile:
                return "benchmark PID file must be an absolute path"
            case .mismatchedPIDFile:
                return "benchmark PID file does not match its run identifier"
            }
        }
    }

    static var isRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["LYTE_BENCHMARK_RUN_ID"] != nil
            || environment["LYTE_BENCHMARK_PIDFILE"] != nil
            || CommandLine.arguments.contains(argument)
    }

    @discardableResult
    static func publishIfRequested() throws -> Bool {
        guard isRequested else { return false }

        let environment = ProcessInfo.processInfo.environment
        let argumentIndices = CommandLine.arguments.indices.filter {
            CommandLine.arguments[$0] == argument
        }
        guard let environmentRunID = environment["LYTE_BENCHMARK_RUN_ID"],
              let pidPath = environment["LYTE_BENCHMARK_PIDFILE"],
              argumentIndices.count == 1,
              let argumentIndex = argumentIndices.first,
              CommandLine.arguments.indices.contains(argumentIndex + 1)
        else { throw ConfigurationError.incomplete }

        let argumentRunID = CommandLine.arguments[argumentIndex + 1]
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz"
                + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard !environmentRunID.isEmpty, environmentRunID.count <= 128,
              environmentRunID.unicodeScalars.allSatisfy(allowed.contains)
        else { throw ConfigurationError.invalidRunID }
        guard argumentRunID == environmentRunID else {
            throw ConfigurationError.mismatchedRunID
        }
        guard pidPath.hasPrefix("/") else {
            throw ConfigurationError.relativePIDFile
        }
        guard URL(fileURLWithPath: pidPath).lastPathComponent
                == "\(environmentRunID).pid"
        else { throw ConfigurationError.mismatchedPIDFile }

        let claim = "\(ProcessInfo.processInfo.processIdentifier) "
            + "\(environmentRunID)\n"
        try claim.write(
            to: URL(fileURLWithPath: pidPath),
            atomically: true,
            encoding: .utf8)
        return true
    }
}
