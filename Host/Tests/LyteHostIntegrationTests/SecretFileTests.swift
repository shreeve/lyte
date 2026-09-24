import Foundation
import Glibc
@testable import lyte_host
import XCTest

final class SecretFileTests: XCTestCase {
    /// B12: key material was written with the umask's 0644 and chmod'ed
    /// afterwards, non-atomically. It must be 0600 from the first byte
    /// and replace the old file whole.
    func testSecretsLandOwnerOnlyAndReplaceWhole() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-secret-\(getpid())-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("noise_static.key")

        try SecretFile.write([UInt8](repeating: 1, count: 32), to: target)
        try SecretFile.write([UInt8](repeating: 2, count: 16), to: target)

        XCTAssertEqual(
            [UInt8](try Data(contentsOf: target)),
            [UInt8](repeating: 2, count: 16))
        var info = stat()
        XCTAssertEqual(stat(target.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["noise_static.key"], "no temporary file is left behind")
    }
}
