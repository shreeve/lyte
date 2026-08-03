import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/fec-v1.json byte-exact — field codec,
// parity ladder, and RS matrices. The matrices passing on macOS and
// Linux is what makes nanors' parity bytes wire contract: cross-platform
// byte-exactness of the C leaf, not just of the Swift codecs.

final class FecVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/fec-v1.json"

    private static let packageRoot = WireTestPaths.packageRoot

    private func loadFile() throws -> FecVectorFile {
        try FecVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, FecVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.fieldVectors.isEmpty)
        XCTAssertFalse(file.geometryRows.isEmpty)
        XCTAssertFalse(file.recoveryMatrices.isEmpty)
        let names = file.fieldVectors.map(\.name) + file.recoveryMatrices.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "vector names must be unique")
    }

    func testFieldVectors() throws {
        for vector in try loadFile().fieldVectors {
            guard let raw = Hex.uint64(vector.rawHex) else {
                XCTFail("\(vector.name): bad rawHex")
                continue
            }
            switch vector.kind {
            case .roundtrip:
                let field = try XCTUnwrap(vector.field).makeField()
                XCTAssertEqual(field.encoded, raw, "\(vector.name): encode")
                XCTAssertEqual(try FecField.decode(raw), field, "\(vector.name): decode")
            case .decodeLenient:
                let field = try XCTUnwrap(vector.field).makeField()
                XCTAssertEqual(try FecField.decode(raw), field, vector.name)
                XCTAssertNotEqual(field.encoded, raw, "\(vector.name): should be non-canonical")
            case .decodeReject:
                let expected = try XCTUnwrap(vector.error)
                XCTAssertThrowsError(try FecField.decode(raw), vector.name) { error in
                    guard let fecError = error as? FecError else {
                        return XCTFail("\(vector.name): non-FecError \(error)")
                    }
                    XCTAssertEqual(fecErrorName(fecError), expected, vector.name)
                }
            }
        }
    }

    func testGeometryRows() throws {
        for row in try loadFile().geometryRows {
            let regime = try XCTUnwrap(FecRegime(rawValue: row.regime))
            if let expected = row.parityShards {
                XCTAssertEqual(
                    try FecGeometryTable.parityShards(
                        forDataShards: row.dataShards, regime: regime
                    ),
                    expected,
                    "k=\(row.dataShards) \(row.regime)"
                )
            } else {
                XCTAssertThrowsError(
                    try FecGeometryTable.parityShards(
                        forDataShards: row.dataShards, regime: regime
                    ),
                    "k=\(row.dataShards) \(row.regime)"
                )
            }
        }
    }

    func testRecoveryMatrices() throws {
        for matrix in try loadFile().recoveryMatrices {
            let geometry = try matrix.makeGeometry()
            let group = try XCTUnwrap(Hex.bytes(matrix.groupHex), matrix.name)
            let frozenShards = try matrix.shardsHex.map {
                try XCTUnwrap(Hex.bytes($0), matrix.name)
            }

            // The encoder must reproduce the frozen shards byte-exact.
            let shards = try FecEncoder.encode(group: group, geometry: geometry)
            XCTAssertEqual(
                shards.map(Hex.string), matrix.shardsHex,
                "\(matrix.name): encode is not byte-exact"
            )

            // And decoding the frozen shards under the erasure pattern
            // must recover the group — or fail honestly.
            var slots: [[UInt8]?] = frozenShards
            for index in matrix.erasedIndices { slots[index] = nil }
            switch matrix.expect {
            case .recovered:
                XCTAssertEqual(
                    try FecDecoder.decode(shards: slots, geometry: geometry),
                    group,
                    "\(matrix.name): recovery is not byte-exact"
                )
            case .unrecoverable:
                XCTAssertThrowsError(
                    try FecDecoder.decode(shards: slots, geometry: geometry),
                    matrix.name
                ) { error in
                    guard case .unrecoverableGroup? = error as? FecError else {
                        return XCTFail("\(matrix.name): unexpected \(error)")
                    }
                }
            }
        }
    }
}
