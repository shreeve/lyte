import Foundation
import XCTest

/// Single-owner ratchet: each pure session organ is declared exactly once
/// in the host tree, inside HostSession. File layout inside the target is
/// free to change.
final class HostSessionBoundaryTests: XCTestCase {
    private var hostSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HostSessionTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Host
            .appendingPathComponent("Sources")
    }

    func testPureSessionOrgansHaveOneOwner() throws {
        let organs = [
            "HandshakeGate", "PathValidator", "SessionLifecycleLane",
            "FourTuple", "SessionPath",
        ]
        let kinds: Set<String> = ["struct", "class", "enum", "actor"]
        var owners: [String: [String]] = [:]
        let files = FileManager.default.enumerator(
            at: hostSources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let bytes = Array(try Data(contentsOf: file))
            let relative = file.path.replacingOccurrences(
                of: hostSources.path + "/", with: "")
            // Identifier words in order; a declaration is a kind keyword
            // followed by the organ's name.
            let words = bytes.split { byte in
                !(byte == UInt8(ascii: "_")
                    || (byte >= 0x30 && byte <= 0x39)
                    || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A))
            }
            for (previous, word) in zip(words, words.dropFirst())
            where kinds.contains(String(decoding: previous, as: UTF8.self)) {
                let name = String(decoding: word, as: UTF8.self)
                if organs.contains(name) {
                    owners[name, default: []].append(relative)
                }
            }
        }
        for organ in organs {
            let declared = owners[organ] ?? []
            XCTAssertEqual(declared.count, 1, "\(organ): \(declared)")
            XCTAssertTrue(
                declared.allSatisfy { $0.hasPrefix("HostSession/") },
                "\(organ) belongs to HostSession: \(declared)")
        }
    }
}
