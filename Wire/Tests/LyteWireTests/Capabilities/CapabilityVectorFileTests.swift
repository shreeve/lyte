import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/capabilities-v1.json byte-exact —
// the W7 layer both ends code against, on both platforms: the CBOR
// profile, the typed set, the intersect algebra as data (checked in
// BOTH orders — commutativity is frozen, not assumed), and the CTRL
// codecs 0x0F/0x11/0x12.

final class CapabilityVectorFileTests: XCTestCase {

    private func loadFile() throws -> CapabilityVectorFile {
        try CapabilityVectorFile.loadCommitted()
    }

    func testFileIdentity() throws {
        XCTAssertEqual(try loadFile().identityProblems, [])
    }

    func testCborVectors() throws {
        for vector in try loadFile().cborVectors {
            guard let bytes = Hex.bytes(vector.cborHex) else {
                XCTFail("\(vector.name): malformed cborHex")
                continue
            }
            switch vector.kind {
            case .canonical:
                let decoded = try Cbor.decode(bytes)
                XCTAssertEqual(
                    try Cbor.encode(decoded), bytes, vector.name
                )
            case .decodeReject:
                XCTAssertThrowsError(
                    try Cbor.decode(bytes), vector.name
                ) { error in
                    guard let error = error as? CborError else {
                        return XCTFail("\(vector.name): foreign error")
                    }
                    XCTAssertEqual(
                        vectorErrorName(error), vector.error, vector.name
                    )
                }
            }
        }
    }

    func testSetVectors() throws {
        for vector in try loadFile().setVectors {
            guard let bytes = Hex.bytes(vector.cborHex) else {
                XCTFail("\(vector.name): malformed cborHex")
                continue
            }
            switch vector.kind {
            case .roundtrip:
                let fields = try XCTUnwrap(vector.set, vector.name)
                let decoded = try Capabilities.decodeCbor(bytes)
                XCTAssertTrue(fields.matches(decoded), vector.name)
                XCTAssertEqual(
                    try decoded.encodeCbor(), bytes, vector.name
                )
                if fields.unknownKeyCount == 0 {
                    XCTAssertEqual(
                        try fields.capabilities.encodeCbor(), bytes,
                        vector.name
                    )
                }
            case .decodeLenient:
                let fields = try XCTUnwrap(vector.set, vector.name)
                let decoded = try Capabilities.decodeCbor(bytes)
                XCTAssertTrue(fields.matches(decoded), vector.name)
            case .decodeReject:
                XCTAssertThrowsError(
                    try Capabilities.decodeCbor(bytes), vector.name
                ) { error in
                    guard let error = error as? CapabilityError else {
                        return XCTFail("\(vector.name): foreign error")
                    }
                    XCTAssertEqual(
                        vectorErrorName(error), vector.error,
                        vector.name
                    )
                }
            }
        }
    }

    func testIntersectVectors() throws {
        for vector in try loadFile().intersectVectors {
            guard let aBytes = Hex.bytes(vector.aHex),
                  let bBytes = Hex.bytes(vector.bHex),
                  let agreedBytes = Hex.bytes(vector.agreedHex) else {
                XCTFail("\(vector.name): malformed hex")
                continue
            }
            let a = try Capabilities.decodeCbor(aBytes)
            let b = try Capabilities.decodeCbor(bBytes)
            XCTAssertEqual(
                try a.intersecting(b).encodeCbor(), agreedBytes,
                "\(vector.name) a∩b"
            )
            XCTAssertEqual(
                try b.intersecting(a).encodeCbor(), agreedBytes,
                "\(vector.name) b∩a"
            )
        }
    }

    func testMessageVectors() throws {
        for vector in try loadFile().messageVectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                XCTFail("\(vector.name): malformed messageHex")
                continue
            }
            switch vector.kind {
            case .roundtrip:
                switch vector.codec {
                case .declaration:
                    let decoded = try CapabilityDeclaration.decode(message)
                    XCTAssertEqual(
                        try decoded.encode(), message, vector.name
                    )
                case .update:
                    let decoded = try CapabilityUpdate.decode(message)
                    XCTAssertEqual(
                        try decoded.encode(), message, vector.name
                    )
                case .updateAck:
                    let decoded = try CapabilityUpdateAck.decode(message)
                    XCTAssertEqual(
                        try decoded.encode(), message, vector.name
                    )
                }
            case .decodeReject:
                let attempt: () throws -> Void = {
                    switch vector.codec {
                    case .declaration:
                        _ = try CapabilityDeclaration.decode(message)
                    case .update:
                        _ = try CapabilityUpdate.decode(message)
                    case .updateAck:
                        _ = try CapabilityUpdateAck.decode(message)
                    }
                }
                XCTAssertThrowsError(try attempt(), vector.name) { error in
                    guard let error = error as? CapabilityMessageError
                    else {
                        return XCTFail("\(vector.name): foreign error")
                    }
                    XCTAssertEqual(
                        vectorErrorName(error), vector.error,
                        vector.name
                    )
                }
            }
        }
    }
}
