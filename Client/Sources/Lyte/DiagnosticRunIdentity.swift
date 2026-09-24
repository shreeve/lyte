import Foundation

/// What the app's diagnostic entry points (autoconnect, the benchmark
/// driver and its overrides, the build badge, the link-health trace) may
/// read. A bundle obeys the environment only when its signed Info.plist
/// says `LyteDiagnosticEntryPoints` (make-app.sh writes it on request);
/// every other bundle reads an empty environment, so no same-user process
/// can drive it into a Keychain-authenticated connect or a frame readback
/// with `open --env` or `launchctl setenv`.
enum DiagnosticEnvironment {
    static let infoKey = "LyteDiagnosticEntryPoints"

    static let current = variables(
        info: Bundle.main.infoDictionary,
        environment: ProcessInfo.processInfo.environment)

    static func variables(
        info: [String: Any]?, environment: [String: String]
    ) -> [String: String] {
        info?[infoKey] as? Bool == true ? environment : [:]
    }

    static var isEnabled: Bool {
        Bundle.main.infoDictionary?[infoKey] as? Bool == true
    }
}

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
        guard DiagnosticEnvironment.isEnabled else { return false }
        let environment = DiagnosticEnvironment.current
        return environment["LYTE_BENCHMARK_RUN_ID"] != nil
            || environment["LYTE_BENCHMARK_PIDFILE"] != nil
            || CommandLine.arguments.contains(argument)
    }

    @discardableResult
    static func publishIfRequested() throws -> Bool {
        guard isRequested else { return false }

        let environment = DiagnosticEnvironment.current
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
