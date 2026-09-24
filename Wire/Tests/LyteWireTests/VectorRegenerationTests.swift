import Foundation
import XCTest
import LyteWireTestKit
import LyteWireVectorGen

// Every committed vector file must be exactly what its builder in
// LyteWireVectorGen produces today. The builders are how new cases get
// appended, so a builder that drifted from the frozen bytes would
// silently rewrite old cases the next time someone regenerates a file.
// Comparison is by the canonical JSON of the decoded values, which is
// platform-independent where raw file bytes need not be.

final class VectorRegenerationTests: XCTestCase {

    private func assertRegenerates<File: FrozenVectorFile>(
        _ build: () throws -> File,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let committed = try File.loadCommitted().canonicalJSON()
        let rebuilt = try build().canonicalJSON()
        guard committed != rebuilt else { return }
        XCTFail(
            "\(File.fileName): builder output differs from the committed file\(firstDifference(committed, rebuilt))",
            file: file, line: line
        )
    }

    /// Where two canonical JSON renderings first diverge, so a failure
    /// names the drifted field instead of just the file.
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

    func testEnvelope() throws { try assertRegenerates(makeEnvelopeVectorFile) }
    func testFec() throws { try assertRegenerates(makeFecVectorFile) }
    func testBeacon() throws { try assertRegenerates(makeBeaconVectorFile) }
    func testNoise() throws { try assertRegenerates(makeNoiseVectorFile) }
    func testSession() throws { try assertRegenerates(makeSessionVectorFile) }
    func testArq() throws { try assertRegenerates(makeArqVectorFile) }
    func testLifecycle() throws { try assertRegenerates(makeLifecycleVectorFile) }
    func testPairing() throws { try assertRegenerates(makePairingVectorFile) }
    func testCapabilities() throws { try assertRegenerates(makeCapabilityVectorFile) }
    func testRetry() throws { try assertRegenerates(makeRetryVectorFile) }
    func testControl() throws { try assertRegenerates(makeControlVectorFile) }
    func testClipboard() throws { try assertRegenerates(makeClipboardVectorFile) }
    func testBulk() throws { try assertRegenerates(makeBulkVectorFile) }
    func testClipboardImages() throws { try assertRegenerates(makeClipboardImageVectorFile) }
    func testCursor() throws { try assertRegenerates(makeCursorVectorFile) }
    func testRepairRefusal() throws { try assertRegenerates(makeRepairRefusalVectorFile) }
    func testPostures() throws { try assertRegenerates(makePostureVectorFile) }
    func testInputCoordinates() throws { try assertRegenerates(makeInputCoordinateVectorFile) }

    func testVideo() throws {
        try assertRegenerates {
            try makeVideoVectorFile(
                corpusDirectory: WireVectors.path("video-corpus-v1")
            )
        }
    }
}
