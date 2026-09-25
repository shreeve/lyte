import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/clipboard-v1.json byte-exact — the
// clipboard-text codecs (ClipboardSet 0x1A, ClipboardAnnounce
// 0x1B) and the key-10 capability spine, on both platforms.

final class ClipboardVectorFileTests: XCTestCase {

    private func loadFile() throws -> ClipboardVectorFile {
        try ClipboardVectorFile.loadCommitted()
    }

    func testAllClipboardVectors() throws {
        for vector in try loadFile().vectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                return XCTFail("\(vector.name): malformed messageHex")
            }
            switch vector.codec {
            case .clipboardSet:
                try checkMessage(
                    vector, message: message,
                    encode: { try ClipboardSet(text: $0).encode() },
                    decode: { try ClipboardSet.decode($0).text }
                )
            case .clipboardAnnounce:
                try checkMessage(
                    vector, message: message,
                    encode: { try ClipboardAnnounce(text: $0).encode() },
                    decode: { try ClipboardAnnounce.decode($0).text }
                )
            case .capabilitySet:
                try checkCapabilitySet(vector, message: message)
            }
        }
    }

    private func checkMessage(
        _ vector: ClipboardVector, message: [UInt8],
        encode: (String) throws -> [UInt8],
        decode: ([UInt8]) throws -> String
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let utf8 = vector.textUtf8Hex.flatMap(Hex.bytes) else {
                return XCTFail("\(vector.name): missing textUtf8Hex")
            }
            let text = String(decoding: utf8, as: UTF8.self)
            XCTAssertEqual(Array(text.utf8), utf8,
                           "\(vector.name): vector text must be valid UTF-8")
            XCTAssertEqual(try encode(text), message, vector.name)
            XCTAssertEqual(try decode(message), text, vector.name)
        case .decodeReject:
            assertVectorReject(
                ClipboardMessageError.self, vector.error, vector.name
            ) {
                try decode(message)
            }
        }
    }

    private func checkCapabilitySet(
        _ vector: ClipboardVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let expected = vector.clipboardText else {
                return XCTFail("\(vector.name): missing clipboardText")
            }
            let set = try Capabilities.decodeCbor(message)
            XCTAssertEqual(set.clipboardText, expected, vector.name)
            XCTAssertEqual(try set.encodeCbor(), message, vector.name)
        case .decodeReject:
            XCTFail("\(vector.name): capabilitySet vectors are roundtrips")
        }
    }
}
