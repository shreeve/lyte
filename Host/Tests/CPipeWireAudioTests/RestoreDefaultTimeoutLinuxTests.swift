import CPipeWireAudio
import Foundation
import Glibc
import LyteIO
import XCTest

/// The next-start sweep against a PipeWire server that accepts the
/// connection and never answers. The runtime directory is a private
/// temp dir holding listening-but-silent sockets under every default
/// remote name, so the sweep can never reach the desktop's real server.
final class RestoreDefaultTimeoutLinuxTests: XCTestCase {
    private var runtimeDir = ""
    private var listeners: [Int32] = []
    private var savedEnvironment: [String: String?] = [:]

    override func setUpWithError() throws {
        runtimeDir = NSTemporaryDirectory() + "lyte-pw-wedged-\(getpid())"
        try FileManager.default.createDirectory(
            atPath: runtimeDir, withIntermediateDirectories: true)
        for name in ["pipewire-0", "pipewire-0-manager"] {
            listeners.append(try listenSilently(at: "\(runtimeDir)/\(name)"))
        }
        for key in ["PIPEWIRE_RUNTIME_DIR", "XDG_RUNTIME_DIR",
                    "PIPEWIRE_REMOTE"] {
            savedEnvironment.updateValue(
                ProcessInfo.processInfo.environment[key], forKey: key)
        }
        setenv("PIPEWIRE_RUNTIME_DIR", runtimeDir, 1)
        setenv("XDG_RUNTIME_DIR", runtimeDir, 1)
        unsetenv("PIPEWIRE_REMOTE")
    }

    override func tearDownWithError() throws {
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        for fd in listeners { close(fd) }
        listeners = []
        try? FileManager.default.removeItem(atPath: runtimeDir)
    }

    func testSweepAgainstASilentServerTimesOutInsteadOfHanging() throws {
        let finished = DispatchSemaphore(value: 0)
        let result = SweepResult()
        Thread.detachNewThread {
            var err = [CChar](repeating: 0, count: 256)
            let rc = lyte_pw_audio_restore_default(nil, &err, err.count)
            result.set(rc: rc, message: String(cBuffer: err))
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 15) == .success else {
            return XCTFail("the sweep is still waiting on a silent server")
        }
        let (rc, message) = result.get()
        XCTAssertEqual(rc, -1)
        XCTAssertTrue(message.contains("timed out"), message)
    }

    private func listenSilently(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path)
        else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }
}

private final class SweepResult: @unchecked Sendable {
    private let lock = NSLock()
    private var rc: Int32 = 0
    private var message = ""

    func set(rc: Int32, message: String) {
        lock.lock(); defer { lock.unlock() }
        self.rc = rc
        self.message = message
    }

    func get() -> (Int32, String) {
        lock.lock(); defer { lock.unlock() }
        return (rc, message)
    }
}
