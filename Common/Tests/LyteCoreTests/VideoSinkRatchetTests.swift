import Foundation
import XCTest

final class VideoSinkRatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        if let override = ProcessInfo.processInfo.environment[
            "LYTE_REPOSITORY_ROOT"
        ] {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testVideoSinkIsTheOnlyProductionSampleBoundary() throws {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.repositoryRoot.appendingPathComponent("CLEANUP.md").path))
        let sources = try swiftSources(
            under: Self.repositoryRoot.appendingPathComponent("Sources"))
        let declarations = sources.filter {
            $0.source.contains("protocol VideoSink:")
        }
        XCTAssertEqual(
            declarations.map(\.path),
            ["Sources/LyteTransport/VideoSink.swift"])

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

    func testEveryNamedImplementationRemainsWired() throws {
        let app = try source("Sources/Lyte/ConnectionModel.swift")
        let cli = try source("Sources/lyte-cli/WireViewCommand.swift")
        let tests = try source(
            "Tests/LyteTransportTests/HeadlessVideoSink.swift")
        XCTAssertTrue(app.contains("VideoRendererHandoff: VideoSink"))
        XCTAssertTrue(cli.contains("AVSampleBufferRendererVideoSink"))
        XCTAssertTrue(tests.contains("HeadlessVideoSink: VideoSink"))
    }

    private func swiftSources(
        under root: URL
    ) throws -> [(path: String, source: String)] {
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [(String, String)] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            result.append((
                file.path.replacingOccurrences(
                    of: Self.repositoryRoot.path + "/", with: ""),
                try String(contentsOf: file, encoding: .utf8)))
        }
        return result
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(path),
            encoding: .utf8)
    }
}
