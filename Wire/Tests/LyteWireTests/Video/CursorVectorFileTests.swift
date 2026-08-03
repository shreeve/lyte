import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/cursor-v1.json byte-exact — the E3
// cursor-shape codec (CursorShape 0x24) and the key-13 capability
// spine, on both platforms.

final class CursorVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/cursor-v1.json"

    private static let packageRoot = WireTestPaths.packageRoot

    private func loadFile() throws -> CursorVectorFile {
        try CursorVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, CursorVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        let names = file.vectors.map(\.name)
        XCTAssertEqual(Set(names).count, names.count,
                       "vector names must be unique")
    }

    /// The file's coverage discipline: the codec carries roundtrips
    /// including the hidden state, a non-square image, the exact side
    /// cap, and the exact image ceiling as legal; every error case
    /// name appears at least once; and the key-13 spine is pinned
    /// both declared and absent.
    func testCoverageDiscipline() throws {
        let file = try loadFile()
        let roundtrips = file.vectors.filter {
            $0.codec == .cursorShape && $0.kind == .roundtrip
        }
        XCTAssertFalse(roundtrips.isEmpty)
        XCTAssertTrue(
            roundtrips.contains { $0.width == 0 && $0.height == 0 },
            "the hidden state must be pinned as legal"
        )
        XCTAssertTrue(
            roundtrips.contains { $0.width != $0.height },
            "a non-square image must pin the field order"
        )
        XCTAssertTrue(
            roundtrips.contains {
                $0.width == CursorWire.maxSide
                    || $0.height == CursorWire.maxSide
            },
            "the exact side cap must be pinned as legal"
        )
        XCTAssertTrue(
            roundtrips.contains { vector in
                guard let w = vector.width, let h = vector.height
                else { return false }
                return w * h * 4 == CursorWire.maxImageByteCount
            },
            "the exact image ceiling must be pinned as legal"
        )
        let errors = Set(file.vectors.compactMap(\.error))
        XCTAssertEqual(
            errors,
            ["truncatedMessage", "unexpectedType", "invalidDimensions",
             "imageOverBudget", "pixelCountMismatch",
             "hotspotOutsideImage"],
            "every CursorMessageError case pinned at least once"
        )
        let spinePins = Set(file.vectors.lazy
            .filter { $0.codec == .capabilitySet }
            .compactMap(\.cursorShape))
        XCTAssertEqual(spinePins, [true, false],
                       "the key-13 spine pinned declared AND absent")
    }

    func testAllCursorVectors() throws {
        for vector in try loadFile().vectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                return XCTFail("\(vector.name): malformed messageHex")
            }
            switch vector.codec {
            case .cursorShape:
                try checkShape(vector, message: message)
            case .capabilitySet:
                try checkCapabilitySet(vector, message: message)
            }
        }
    }

    private func checkShape(
        _ vector: CursorVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let width = vector.width, let height = vector.height,
                  let hotspotX = vector.hotspotX,
                  let hotspotY = vector.hotspotY,
                  let pixels = vector.pixelsHex.flatMap(Hex.bytes) else {
                return XCTFail("\(vector.name): missing roundtrip fields")
            }
            let shape = CursorShape(
                width: UInt16(width), height: UInt16(height),
                hotspotX: UInt16(hotspotX), hotspotY: UInt16(hotspotY),
                pixels: pixels
            )
            XCTAssertEqual(try shape.encode(), message, vector.name)
            XCTAssertEqual(
                try CursorShape.decode(message), shape, vector.name
            )
        case .decodeReject:
            XCTAssertThrowsError(
                try CursorShape.decode(message), vector.name
            ) {
                guard let error = $0 as? CursorMessageError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(cursorMessageErrorName(error),
                               vector.error, vector.name)
            }
        }
    }

    private func checkCapabilitySet(
        _ vector: CursorVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let expected = vector.cursorShape else {
                return XCTFail("\(vector.name): missing cursorShape")
            }
            let set = try Capabilities.decodeCbor(message)
            XCTAssertEqual(set.cursorShape, expected, vector.name)
            XCTAssertEqual(try set.encodeCbor(), message, vector.name)
        case .decodeReject:
            XCTFail("\(vector.name): capabilitySet vectors are roundtrips")
        }
    }
}
