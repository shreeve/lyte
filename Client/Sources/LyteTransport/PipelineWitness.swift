import LyteIO
import Foundation
import Synchronization

/// One JSONL evidence file for diagnostic runs, named by an environment
/// variable. Until `configure(environment:)` runs, the variable is read
/// from the process environment (the CLI's behavior); a host app passes
/// only the environment its diagnostic gate admits. Disabled, `record`
/// returns before building its fields.
public final class JsonlWitness: Sendable {
    public let environmentKey: String
    /// Guards the path and serializes the appends.
    private let path: Mutex<String?>
    /// The per-packet hot check, lock-free.
    private let enabled: Atomic<Bool>

    public init(
        environmentKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environmentKey = environmentKey
        let value = Self.path(in: environment, key: environmentKey)
        path = Mutex(value)
        enabled = Atomic(value != nil)
    }

    /// Re-reads the witness's variable from `environment`; an absent or
    /// empty value disables it.
    public func configure(environment: [String: String]) {
        let value = Self.path(in: environment, key: environmentKey)
        path.withLock { $0 = value }
        enabled.store(value != nil, ordering: .relaxed)
    }

    public var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    public func record(
        _ event: String,
        fields: @autoclosure () -> [String: String]
    ) {
        guard isEnabled else { return }
        var object = fields()
        object["event"] = event
        object["monotonicNanoseconds"] =
            String(SystemMonotonicClock.nowNanoseconds)
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        else { return }
        path.withLock { path in
            guard let path else { return }
            if !FileManager.default.fileExists(atPath: path) {
                _ = FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                handle.write(data)
                handle.write(Data([0x0A]))
            } catch {}
        }
    }

    private static func path(
        in environment: [String: String], key: String
    ) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }
}

/// Per-packet/per-frame timing evidence (`LYTE_PIPELINE_WITNESS_JSONL`).
public enum PipelineWitness {
    private static let witness =
        JsonlWitness(environmentKey: "LYTE_PIPELINE_WITNESS_JSONL")

    public static var isEnabled: Bool { witness.isEnabled }

    /// See `JsonlWitness.configure(environment:)`.
    public static func configure(environment: [String: String]) {
        witness.configure(environment: environment)
    }

    public static func record(
        _ event: String,
        fields: @autoclosure () -> [String: String]
    ) {
        witness.record(event, fields: fields())
    }
}

/// Noise dial evidence (`LYTE_HANDSHAKE_WITNESS_JSONL`).
public enum HandshakeWitness {
    private static let witness =
        JsonlWitness(environmentKey: "LYTE_HANDSHAKE_WITNESS_JSONL")

    /// See `JsonlWitness.configure(environment:)`.
    public static func configure(environment: [String: String]) {
        witness.configure(environment: environment)
    }

    public static func record(
        _ event: String,
        fields: @autoclosure () -> [String: String] = [:]
    ) {
        witness.record(event, fields: fields())
    }
}
