import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/clipboard-images-v1.json byte-exact —
// the cargo marker (ClipboardImageCargo 0x22) and the key-12
// capability spine, on both platforms.

final class ClipboardImageVectorFileTests: XCTestCase {

    private func loadFile() throws -> ClipboardImageVectorFile {
        try ClipboardImageVectorFile.loadCommitted()
    }

    func testAllClipboardImageVectors() throws {
        for vector in try loadFile().vectors {
            switch vector.codec {
            case .imageCargo:
                try checkCargo(vector)
            case .capabilitySet:
                try checkCapabilitySet(vector)
            }
        }
    }

    private func checkCargo(_ vector: ClipboardImageVector) throws {
        switch vector.kind {
        case .roundtrip:
            guard let message = vector.messageHex.flatMap(Hex.bytes),
                  let idHex = vector.transferIdHex,
                  let transferId = UInt64(idHex, radix: 16),
                  let mimeUtf8 = vector.mimeUtf8Hex.flatMap(Hex.bytes)
            else {
                return XCTFail("\(vector.name): missing roundtrip fields")
            }
            let mime = String(decoding: mimeUtf8, as: UTF8.self)
            XCTAssertEqual(Array(mime.utf8), mimeUtf8,
                           "\(vector.name): mime must be valid UTF-8")
            let cargo = try ClipboardImageCargo(
                transferId: transferId, mime: mime
            )
            XCTAssertEqual(cargo.encode(), message, vector.name)
            let decoded = try ClipboardImageCargo.decode(message)
            XCTAssertEqual(decoded.transferId, transferId, vector.name)
            XCTAssertEqual(decoded.mime, mime, vector.name)
        case .decodeReject:
            guard let message = vector.messageHex.flatMap(Hex.bytes)
            else {
                return XCTFail("\(vector.name): malformed messageHex")
            }
            assertVectorReject(
                ClipboardImageCargoError.self, vector.error, vector.name
            ) {
                try ClipboardImageCargo.decode(message)
            }
        case .encodeReject:
            guard let mimeUtf8 = vector.mimeUtf8Hex.flatMap(Hex.bytes)
            else {
                return XCTFail("\(vector.name): missing mimeUtf8Hex")
            }
            let mime = String(decoding: mimeUtf8, as: UTF8.self)
            assertVectorReject(
                ClipboardImageCargoError.self, vector.error, vector.name
            ) {
                try ClipboardImageCargo(transferId: 7, mime: mime)
            }
        }
    }

    private func checkCapabilitySet(
        _ vector: ClipboardImageVector
    ) throws {
        guard vector.kind == .roundtrip,
              let message = vector.messageHex.flatMap(Hex.bytes) else {
            return XCTFail(
                "\(vector.name): capabilitySet vectors are roundtrips"
            )
        }
        guard let expected = vector.clipboardImages else {
            return XCTFail("\(vector.name): missing clipboardImages")
        }
        let set = try Capabilities.decodeCbor(message)
        XCTAssertEqual(set.clipboardImages, expected, vector.name)
        XCTAssertEqual(try set.encodeCbor(), message, vector.name)
    }
}
