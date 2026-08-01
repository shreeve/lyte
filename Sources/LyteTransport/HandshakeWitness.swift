import Foundation

/// Fail-closed, environment-gated JSONL evidence for bounded Noise dials.
/// Normal launches pay one nil environment lookup and emit nothing.
public enum HandshakeWitness {
    private static let lock = NSLock()

    public static func record(
        _ event: String,
        fields: [String: String] = [:]
    ) {
        guard let path = ProcessInfo.processInfo.environment[
            "LYTE_HANDSHAKE_WITNESS_JSONL"] else { return }
        var object = fields
        object["event"] = event
        object["monotonicNanoseconds"] =
            String(DispatchTime.now().uptimeNanoseconds)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
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
