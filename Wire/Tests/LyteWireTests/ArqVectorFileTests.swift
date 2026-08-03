import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/arq-v1.json byte-exact — the W3 frame
// formats (data segment 0x07, ACK 0x08, and the frame-sequence payload
// rule) both ends code against, on both platforms.

final class ArqVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/arq-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> ArqVectorFile {
        try ArqVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, ArqVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        let names = file.vectors.map(\.name)
        XCTAssertEqual(
            Set(names).count, names.count, "vector names must be unique"
        )
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
                    try ArqFrame.encodeAll(decoded), payload,
                    "\(vector.name): re-encode is not byte-exact"
                )
            case .decodeLenient:
                let expected = try (vector.frames ?? []).map(arqFrame(from:))
                let decoded = try ArqFrame.decodeAll(payload)
                XCTAssertEqual(decoded, expected, vector.name)
                XCTAssertNotEqual(
                    try ArqFrame.encodeAll(decoded), payload,
                    "\(vector.name): lenient decode re-encoded identically"
                )
            case .decodeReject:
                XCTAssertThrowsError(
                    try ArqFrame.decodeAll(payload), vector.name
                ) { error in
                    guard let frameError = error as? ArqFrameError else {
                        return XCTFail("\(vector.name): foreign error type")
                    }
                    XCTAssertEqual(
                        arqFrameErrorName(frameError), vector.error,
                        vector.name
                    )
                }
            }
        }
    }
}
