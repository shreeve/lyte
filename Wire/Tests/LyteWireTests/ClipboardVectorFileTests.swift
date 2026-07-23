import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/clipboard-v1.json byte-exact — the
// CL-15 clipboard-text codecs (ClipboardSet 0x1A, ClipboardAnnounce
// 0x1B) and the key-10 capability spine, on both platforms.

final class ClipboardVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/clipboard-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> ClipboardVectorFile {
        try ClipboardVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, ClipboardVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        let names = file.vectors.map(\.name)
        XCTAssertEqual(Set(names).count, names.count,
                       "vector names must be unique")
    }

    /// The file's coverage discipline: both message codecs carry
    /// roundtrips including a multi-byte UTF-8 case, the exact ceiling
    /// is pinned as legal, every error case name appears at least
    /// once, and the key-10 spine is pinned both declared and absent.
    func testCoverageDiscipline() throws {
        let file = try loadFile()
        for codec: ClipboardVector.ClipboardCodec
            in [.clipboardSet, .clipboardAnnounce] {
            let roundtrips = file.vectors.filter {
                $0.codec == codec && $0.kind == .roundtrip
            }
            XCTAssertFalse(roundtrips.isEmpty, "\(codec) needs roundtrips")
            XCTAssertTrue(
                roundtrips.contains { vector in
                    guard let bytes = vector.textUtf8Hex.flatMap(Hex.bytes)
                    else { return false }
                    return bytes.contains { $0 >= 0x80 }
                },
                "\(codec) needs a multi-byte UTF-8 roundtrip"
            )
        }
        XCTAssertTrue(
            file.vectors.contains { vector in
                vector.kind == .roundtrip
                    && vector.textUtf8Hex.flatMap(Hex.bytes)?.count
                        == ClipboardWire.maxTextByteCount
            },
            "the exact ceiling must be pinned as legal"
        )
        let errors = Set(file.vectors.compactMap(\.error))
        XCTAssertEqual(
            errors,
            ["truncatedMessage", "unexpectedType", "emptyText",
             "textOverBudget", "invalidUtf8"],
            "every ClipboardMessageError case pinned at least once"
        )
        let spinePins = Set(file.vectors.lazy
            .filter { $0.codec == .capabilitySet }
            .compactMap(\.clipboardText))
        XCTAssertEqual(spinePins, [true, false],
                       "the key-10 spine pinned declared AND absent")
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
            XCTAssertThrowsError(try decode(message), vector.name) {
                guard let error = $0 as? ClipboardMessageError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(clipboardMessageErrorName(error),
                               vector.error, vector.name)
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
