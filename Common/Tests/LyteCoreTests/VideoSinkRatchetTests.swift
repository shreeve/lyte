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

    func testProductionImplementationsRemainWired() throws {
        let app = try source("Client/Sources/Lyte/ConnectionModel.swift")
        let cli = try source("Client/Sources/lyte-cli/WireViewCommand.swift")
        let sink = try source(
            "Client/Sources/LyteTransport/VideoSink.swift")
        XCTAssertTrue(app.contains("VideoRendererHandoff: VideoSink"))
        XCTAssertTrue(app.contains("noteVideoIrapEnqueued"))
        XCTAssertTrue(cli.contains("AVSampleBufferRendererVideoSink"))
        // Diagnostic shell must close the IDR episode on IRAP enqueue —
        // omitting this re-armed static-screen IDRs under mild loss.
        XCTAssertTrue(cli.contains("noteVideoIrapEnqueued"))
        XCTAssertTrue(sink.contains("onIrapEnqueued"))
        XCTAssertTrue(
            sink.contains("onIrapEnqueued: @escaping @Sendable (FrameNumber) -> Void"),
            "diagnostic sink must require the IRAP-close callback")
    }

    func testSessionPolicyStaysNativeMediaTypeFree() throws {
        let core = try source(
            "Client/Sources/LyteTransport/LyteUdpSession.swift")
        let sink = try source(
            "Client/Sources/LyteTransport/VideoSink.swift")

        XCTAssertFalse(core.contains("import CoreMedia"))
        XCTAssertFalse(core.contains("CMSampleBuffer"))
        XCTAssertFalse(core.contains("class SessionVideoSink"))
        XCTAssertTrue(core.contains("func admitVideoUnit(_ unit: DecodeUnit) -> Bool"))
        XCTAssertTrue(core.contains("let sessionSink = SessionVideoSink"))
        XCTAssertTrue(core.contains("sessionSink.bind(self)"))

        XCTAssertTrue(sink.contains("final class SessionVideoSink"))
        XCTAssertTrue(sink.contains("owner.admitVideoUnit(unit)"))
        XCTAssertTrue(sink.contains("downstream.submit(sample: sample, unit: unit)"))
    }

    private func swiftSources() throws -> [(path: String, source: String)] {
        var result: [(String, String)] = []
        for file in try sourceTree.productionSwiftFiles() {
            result.append((
                sourceTree.relativePath(for: file),
                try String(contentsOf: file, encoding: .utf8)))
        }
        return result
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: sourceTree.repositoryRoot.appendingPathComponent(path),
            encoding: .utf8)
    }
}
