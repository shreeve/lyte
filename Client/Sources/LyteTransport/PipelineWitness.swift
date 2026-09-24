import LyteIO
import Foundation

/// One environment-gated JSONL evidence file for bounded diagnostic runs.
/// The path is read once per process; when the variable is unset,
/// `record` returns before building its fields, so production sessions
/// pay one branch per call and emit nothing.
public struct JsonlWitness: Sendable {
    private let path: String?
    private let lock = NSLock()

    public init(environmentKey: String) {
        let value = ProcessInfo.processInfo.environment[environmentKey]
        path = value?.isEmpty == false ? value : nil
    }

    public var isEnabled: Bool { path != nil }

    public func record(
        _ event: String,
        fields: @autoclosure () -> [String: String]
    ) {
        guard let path else { return }
        var object = fields()
        object["event"] = event
        object["monotonicNanoseconds"] =
            String(SystemMonotonicClock.nowNanoseconds)
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        else { return }
        lock.lock()
        defer { lock.unlock() }
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

/// Per-packet/per-frame timing evidence (`LYTE_PIPELINE_WITNESS_JSONL`).
public enum PipelineWitness {
    private static let witness =
        JsonlWitness(environmentKey: "LYTE_PIPELINE_WITNESS_JSONL")

    public static var isEnabled: Bool { witness.isEnabled }

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

    public static func record(
        _ event: String,
        fields: @autoclosure () -> [String: String] = [:]
    ) {
        witness.record(event, fields: fields())
    }
}
