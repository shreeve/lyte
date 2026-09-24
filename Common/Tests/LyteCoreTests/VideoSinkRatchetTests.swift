import Foundation
import LyteTestKit
import XCTest

final class VideoSinkRatchetTests: XCTestCase {
    private let sourceTree = RepositorySourceTree()

    func testVideoSinkIsTheOnlyProductionSampleBoundary() throws {
        let sources = try swiftSources()
        let declarations = sources.filter {
            $0.source.contains("protocol VideoSink:")
        }
        XCTAssertEqual(
            declarations.map(\.path),
            ["Client/Sources/LyteTransport/VideoSink.swift"])

        let rawSampleClosure = try NSRegularExpression(
            pattern: #"@Sendable\s*\(CMSampleBuffer,\s*DecodeUnit\)\s*->\s*Void"#)
        let violations = sources.filter { file in
            rawSampleClosure.firstMatch(
                in: file.source,
                range: NSRange(file.source.startIndex..., in: file.source)
            ) != nil
        }
        XCTAssertTrue(
            violations.isEmpty,
            "raw video sample closures reintroduced:\n"
                + violations.map(\.path).sorted().joined(separator: "\n"))
    }

    /// The session core decides on decoded wire units; CoreMedia stays in
    /// the sink adapter. Found by declaration, not by path, so the files
    /// can move.
    func testSessionPolicyStaysNativeMediaTypeFree() throws {
        let sources = try swiftSources()
        let cores = sources.filter {
            $0.source.contains("final class LyteUdpSessionCore")
        }
        XCTAssertEqual(cores.count, 1, "one file declares LyteUdpSessionCore")
        for core in cores {
            XCTAssertFalse(
                SwiftSourceScanner.importedModules(in: core.source)
                    .contains("CoreMedia"),
                core.path)
            XCTAssertFalse(core.source.contains("CMSampleBuffer"), core.path)
        }
        XCTAssertEqual(
            sources.filter { $0.source.contains("class SessionVideoSink") }
                .map(\.path),
            ["Client/Sources/LyteTransport/VideoSink.swift"])
    }

    private func swiftSources() throws -> [(path: String, source: String)] {
        var result: [(String, String)] = []
        for file in try sourceTree.productionSwiftFiles() {
            result.append((
                sourceTree.relativePath(for: file),
                try sourceTree.source(of: file)))
        }
        return result
    }

    private func source(_ path: String) throws -> String {
        try sourceTree.source(
            of: sourceTree.repositoryRoot.appendingPathComponent(path))
    }
}
