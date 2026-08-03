import LyteIO
import Foundation

/// Environment-gated per-packet/per-frame timing evidence for one bounded
/// diagnostic run. Production sessions emit nothing.
public enum PipelineWitness {
    private static let lock = NSLock()
    private static let path: String? = {
        guard let value = ProcessInfo.processInfo.environment[
            "LYTE_PIPELINE_WITNESS_JSONL"],
              !value.isEmpty else { return nil }
        return value
    }()
    public static var isEnabled: Bool { path != nil }

    public static func record(
        _ event: String,
        fields: [String: String]
    ) {
        guard let path else { return }
        var object = fields
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
