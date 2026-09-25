import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/arq-v1.json byte-exact — the ARQ frame
// formats (data segment 0x07, ACK 0x08, and the frame-sequence payload
// rule) both ends code against, on both platforms.

final class ArqVectorFileTests: XCTestCase {

    private func loadFile() throws -> ArqVectorFile {
        try ArqVectorFile.loadCommitted()
    }

    func testAllArqVectors() throws {
        for vector in try loadFile().vectors {
            guard let payload = Hex.bytes(vector.payloadHex) else {
                XCTFail("\(vector.name): malformed payloadHex")
                continue
            }
            switch vector.kind {
            case .roundtrip:
                let expected = try (vector.frames ?? []).map(arqFrame(from:))
                XCTAssertFalse(expected.isEmpty, vector.name)
                let decoded = try ArqFrame.decodeAll(payload)
                XCTAssertEqual(decoded, expected, vector.name)
                XCTAssertEqual(
                    decoded.flatMap { $0.encode() }, payload,
                    "\(vector.name): re-encode is not byte-exact"
                )
            case .decodeLenient:
                let expected = try (vector.frames ?? []).map(arqFrame(from:))
                let decoded = try ArqFrame.decodeAll(payload)
                XCTAssertEqual(decoded, expected, vector.name)
                XCTAssertNotEqual(
                    decoded.flatMap { $0.encode() }, payload,
                    "\(vector.name): lenient decode re-encoded identically"
                )
            case .decodeReject:
                assertVectorReject(
                    ArqFrameError.self, vector.error, vector.name
                ) {
                    try ArqFrame.decodeAll(payload)
                }
            }
        }
    }
}
