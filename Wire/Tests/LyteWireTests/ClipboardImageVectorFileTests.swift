import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/clipboard-images-v1.json byte-exact —
// the P-1 cargo marker (ClipboardImageCargo 0x22) and the key-12
// capability spine, on both platforms.

final class ClipboardImageVectorFileTests: XCTestCase {

    private static let vectorsPath =
        packageRoot + "/Vectors/clipboard-images-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> ClipboardImageVectorFile {
        try ClipboardImageVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, ClipboardImageVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        let names = file.vectors.map(\.name)
        XCTAssertEqual(Set(names).count, names.count,
                       "vector names must be unique")
    }

    /// The file's coverage discipline: the marker carries roundtrips
    /// including a foreign-but-well-formed mime (format policy is the
    /// channel's, never the codec's) and the exact 255-byte mime
    /// ceiling; every decode-reachable error case appears at least
    /// once plus the one wire-inexpressible encode reject; and the
    /// key-12 spine is pinned declared AND absent.
    func testCoverageDiscipline() throws {
        let file = try loadFile()
        let roundtrips = file.vectors.filter {
            $0.codec == .imageCargo && $0.kind == .roundtrip
        }
        XCTAssertFalse(roundtrips.isEmpty, "imageCargo needs roundtrips")
        XCTAssertTrue(
            roundtrips.contains { vector in
                guard let mime = vector.mimeUtf8Hex.flatMap(Hex.bytes)
                else { return false }
                return !ClipboardImageWire.accepts(
                    mime: String(decoding: mime, as: UTF8.self)
                )
            },
            "a foreign-but-well-formed mime must be pinned as decodable"
        )
        XCTAssertTrue(
            roundtrips.contains { vector in
                vector.mimeUtf8Hex.flatMap(Hex.bytes)?.count == 255
            },
            "the exact 255-byte mime ceiling must be pinned as legal"
        )
        let decodeErrors = Set(file.vectors.lazy
            .filter { $0.kind == .decodeReject }.compactMap(\.error))
        XCTAssertEqual(
            decodeErrors,
            ["truncatedMessage", "unexpectedType", "trailingBytes",
             "zeroTransferId", "emptyMime", "invalidUtf8"],
            "every decode-reachable error case pinned at least once"
        )
        let encodeErrors = Set(file.vectors.lazy
            .filter { $0.kind == .encodeReject }.compactMap(\.error))
        XCTAssertEqual(encodeErrors, ["mimeOverBudget"],
                       "the u8-width bound pinned as an encode reject")
        let spinePins = Set(file.vectors.lazy
            .filter { $0.codec == .capabilitySet }
            .compactMap(\.clipboardImages))
        XCTAssertEqual(spinePins, [true, false],
                       "the key-12 spine pinned declared AND absent")
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
            XCTAssertThrowsError(
                try ClipboardImageCargo.decode(message), vector.name
            ) {
                guard let error = $0 as? ClipboardImageCargoError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(clipboardImageCargoErrorName(error),
                               vector.error, vector.name)
            }
        case .encodeReject:
            guard let mimeUtf8 = vector.mimeUtf8Hex.flatMap(Hex.bytes)
            else {
                return XCTFail("\(vector.name): missing mimeUtf8Hex")
            }
            let mime = String(decoding: mimeUtf8, as: UTF8.self)
            XCTAssertThrowsError(
                try ClipboardImageCargo(transferId: 7, mime: mime),
                vector.name
            ) {
                guard let error = $0 as? ClipboardImageCargoError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(clipboardImageCargoErrorName(error),
                               vector.error, vector.name)
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
