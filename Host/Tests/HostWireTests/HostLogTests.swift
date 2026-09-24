#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import HostIO
import XCTest

final class HostLogTests: XCTestCase {
    private var directory = ""

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-log-\(getpid())-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func contents(_ path: String) throws -> String {
        guard let bytes = try SecretFile.read(path) else { return "<missing>" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func write(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { raw in
            #if canImport(Darwin)
            Darwin.write(fd, raw.baseAddress, raw.count)
            #else
            Glibc.write(fd, raw.baseAddress, raw.count)
            #endif
        }
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        _ = stat(path, &info)
        return info.st_mode & 0o777
    }

    /// The unit's layout: stdout and stderr share one O_APPEND host.log.
    private func openLog(_ path: String) -> (Int32, Int32) {
        let out = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        return (out, dup(out))
    }

    func testAnOversizeLogMovesAsideAndBothStreamsFollowTheFreshFile() throws {
        let path = directory + "/host.log"
        let (out, err) = openLog(path)
        defer { close(out); close(err) }
        write(String(repeating: "x", count: 99) + "\n", to: out)
        write("from stderr\n", to: err)

        XCTAssertTrue(try HostLog.rotateIfNeeded(
            path: path, limitBytes: 64, descriptors: [out, err]))
        write("after\n", to: out)
        write("after err\n", to: err)

        XCTAssertEqual(try contents(path + ".1"),
                       String(repeating: "x", count: 99) + "\nfrom stderr\n",
                       "every line before the swap is kept")
        XCTAssertEqual(try contents(path), "after\nafter err\n")
        XCTAssertEqual(mode(path), 0o600)

        XCTAssertFalse(try HostLog.rotateIfNeeded(
            path: path, limitBytes: 64, descriptors: [out, err]),
            "under the bound: nothing to do")
    }

    func testTheSecondGenerationIsReplaced() throws {
        let path = directory + "/host.log"
        let (out, err) = openLog(path)
        defer { close(out); close(err) }
        write(String(repeating: "a", count: 80), to: out)
        XCTAssertTrue(try HostLog.rotateIfNeeded(
            path: path, limitBytes: 64, descriptors: [out, err]))
        write(String(repeating: "b", count: 80), to: out)
        XCTAssertTrue(try HostLog.rotateIfNeeded(
            path: path, limitBytes: 64, descriptors: [out, err]))
        XCTAssertEqual(try contents(path + ".1"), String(repeating: "b", count: 80))
        XCTAssertEqual(try contents(path), "")
    }

    func testOutputThatIsNotTheLogIsLeftAlone() throws {
        let path = directory + "/host.log"
        let (log, logDup) = openLog(path)
        close(logDup)
        defer { close(log) }
        write(String(repeating: "z", count: 100), to: log)
        let other = open(directory + "/host.log.other", O_WRONLY | O_CREAT, 0o600)
        defer { close(other); unlink(directory + "/host.log.other") }
        XCTAssertFalse(try HostLog.rotateIfNeeded(
            path: path, limitBytes: 64, descriptors: [other]))
        XCTAssertEqual(try contents(path + ".1"), "<missing>")
    }
}
