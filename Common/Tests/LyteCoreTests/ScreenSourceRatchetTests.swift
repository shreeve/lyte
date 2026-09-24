import Foundation
import LyteTestKit
import XCTest

final class ScreenSourceRatchetTests: XCTestCase {
    private let sourceTree = RepositorySourceTree()

    func testCaptureConsumersNeverRebuildTheRetiredLoop() throws {
        let paths = [
            "Host/Sources/lyte-host/DirectEyeLeg.swift",
            "Host/Sources/lyte-eye/EyeCapture.swift",
        ]
        let retiredCalls = [
            "currentFB(fd:",
            "grabTicket(fd:",
            "findActivePlanes(fd:",
            "drmSetClientCap(",
        ]

        for path in paths {
            let body = try source(path)
            XCTAssertFalse(body.contains("screen.poll()"), path)
            for call in retiredCalls {
                XCTAssertFalse(
                    body.contains(call),
                    "\(path) rebuilt the retired capture loop: \(call)")
            }
        }
    }

    func testScreenSourceHasOneSeamAndOneDRMImplementation() throws {
        let canonical =
            "Host/Sources/HostEye/ScreenSource.swift"
        let body = try source(canonical)
        XCTAssertTrue(body.contains("protocol ScreenSource:"))
        XCTAssertTrue(body.contains("class DirectScreenSource:"))

        let violations = try sourceTree.violations(
            containing: [
                "protocol ScreenSource:",
                "class DirectScreenSource:",
            ],
            excludingRelativePaths: [canonical])
        XCTAssertTrue(
            violations.isEmpty,
            "screen-source twins reintroduced:\n"
                + violations.joined(separator: "\n"))
    }

    private func source(_ path: String) throws -> String {
        try sourceTree.source(
            of: sourceTree.repositoryRoot.appendingPathComponent(path))
    }
}
