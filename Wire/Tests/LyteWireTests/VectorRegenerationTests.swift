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
        XCTAssertTrue(
            committed == rebuilt,
            "\(File.fileName): builder output differs from the committed file",
            file: file, line: line
        )
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

    func testVideo() throws {
        try assertRegenerates {
            try makeVideoVectorFile(
                corpusDirectory: WireVectors.path("video-corpus-v1")
            )
        }
    }
}
