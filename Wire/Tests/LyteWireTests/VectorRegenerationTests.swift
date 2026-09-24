import Foundation
import XCTest
import LyteWireTestKit
import LyteWireVectorGen

// Every committed vector file must be byte-for-byte what its builder in
// LyteWireVectorGen writes today, and the builder registry must name
// every committed file exactly once. Raw bytes, not decoded values, are
// compared: a decode-then-re-encode comparison forgives escaping,
// whitespace, key order and any key the model does not declare.

final class VectorRegenerationTests: XCTestCase {

    /// `cursor-v1.json` was committed with one `/` unescaped where the
    /// encoder writes `\/`. The frozen file stays as committed, so its
    /// comparison un-escapes `\/` in the rebuilt bytes and forgives
    /// nothing else.
    private static let unescapedSlashFiles: Set<String> = ["cursor-v1.json"]

    func testRegistryNamesEveryCommittedFileOnce() throws {
        let committed = try FileManager.default
            .contentsOfDirectory(atPath: WireVectors.directory)
            .filter { $0.hasSuffix(".json") }
        let registered = vectorFileBuilders.map(\.fileName)
        XCTAssertEqual(Set(registered).count, registered.count,
                       "one builder per file")
        XCTAssertEqual(Set(vectorFileBuilders.map(\.kind)).count,
                       registered.count, "one kind per builder")
        XCTAssertEqual(Set(committed), Set(registered),
                       "every Vectors/*.json has a builder and vice versa")
    }

    func testEveryCommittedFileHasItsIdentity() throws {
        for builder in vectorFileBuilders {
            XCTAssertEqual(
                try builder.loadCommitted().identityProblems, [],
                builder.fileName
            )
        }
    }

    func testEveryCommittedFileIsItsBuildersExactBytes() throws {
        for builder in vectorFileBuilders {
            let committed = try Data(contentsOf: URL(
                fileURLWithPath: WireVectors.path(builder.fileName)
            ))
            var rebuilt = try builder.build().canonicalJSON()
            if Self.unescapedSlashFiles.contains(builder.fileName) {
                rebuilt = Data(String(decoding: rebuilt, as: UTF8.self)
                    .replacingOccurrences(of: "\\/", with: "/").utf8)
            }
            guard committed != rebuilt else { continue }
            XCTFail(
                "\(builder.fileName): builder output differs from the committed bytes\(firstDifference(committed, rebuilt))"
            )
        }
    }

    /// The exemption is live: without it the cursor file would differ.
    func testSlashExemptionIsStillNeeded() throws {
        for fileName in Self.unescapedSlashFiles {
            let builder = try XCTUnwrap(
                vectorFileBuilders.first { $0.fileName == fileName }
            )
            let committed = try Data(contentsOf: URL(
                fileURLWithPath: WireVectors.path(fileName)
            ))
            XCTAssertNotEqual(try builder.build().canonicalJSON(), committed,
                              fileName)
        }
    }

    /// Where two renderings first diverge, so a failure names the drifted
    /// line instead of just the file.
    private func firstDifference(_ committed: Data, _ rebuilt: Data) -> String {
        let old = String(decoding: committed, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let new = String(decoding: rebuilt, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        for index in 0..<max(old.count, new.count) {
            let was = index < old.count ? String(old[index]) : "<end>"
            let now = index < new.count ? String(new[index]) : "<end>"
            if was != now {
                return " at line \(index + 1): committed `\(was)`, rebuilt `\(now)`"
            }
        }
        return ""
    }
}
