import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/session-v1.json byte-exact — the
// promoted end-side codecs (conn-id TLV value, path challenge/response,
// IDR request) both ends now code against, on both platforms.

final class SessionVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/session-v1.json"

    private static let packageRoot = WireTestPaths.packageRoot

    private func loadFile() throws -> SessionVectorFile {
        try SessionVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, SessionVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        let names = file.vectors.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "vector names must be unique")
    }

    func testAllSessionVectors() throws {
        for vector in try loadFile().vectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                return XCTFail("\(vector.name): malformed messageHex")
            }
            switch vector.codec {
            case .pathChallenge:
                try checkPathChallenge(vector, message: message)
            case .pathResponse:
                try checkPathResponse(vector, message: message)
            case .idrRequest:
                try checkIdrRequest(vector, message: message)
            case .connectionIdTlv:
                try checkConnectionIdTlv(vector, message: message)
            }
        }
    }

    private func checkPathChallenge(
        _ vector: SessionVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let tokenHex = vector.tokenHex,
                  let token = Hex.uint64(tokenHex) else {
                return XCTFail("\(vector.name): missing token")
            }
            XCTAssertEqual(PathChallenge(token: token).encode(), message,
                           vector.name)
            XCTAssertEqual(try PathChallenge.decode(message).token, token,
                           vector.name)
        case .decodeReject:
            XCTAssertThrowsError(try PathChallenge.decode(message),
                                 vector.name) {
                guard let error = $0 as? PathMessageError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(pathMessageErrorName(error), vector.error,
                               vector.name)
            }
        }
    }

    private func checkPathResponse(
        _ vector: SessionVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let tokenHex = vector.tokenHex,
                  let token = Hex.uint64(tokenHex) else {
                return XCTFail("\(vector.name): missing token")
            }
            XCTAssertEqual(PathResponse(token: token).encode(), message,
                           vector.name)
            XCTAssertEqual(try PathResponse.decode(message).token, token,
                           vector.name)
        case .decodeReject:
            XCTAssertThrowsError(try PathResponse.decode(message),
                                 vector.name) {
                guard let error = $0 as? PathMessageError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(pathMessageErrorName(error), vector.error,
                               vector.name)
            }
        }
    }

    private func checkIdrRequest(
        _ vector: SessionVector, message: [UInt8]
    ) throws {
        switch vector.kind {
        case .roundtrip:
            guard let requestSeq = vector.requestSeq,
                  let frame = vector.frame,
                  let coalescedCount = vector.coalescedCount else {
                return XCTFail("\(vector.name): missing fields")
            }
            let request = IdrRequest(
                requestSeq: requestSeq,
                frame: FrameNumber(rawValue: frame),
                coalescedCount: coalescedCount
            )
            XCTAssertEqual(request.encode(), message, vector.name)
            XCTAssertEqual(try IdrRequest.decode(message), request,
                           vector.name)
        case .decodeReject:
            XCTAssertThrowsError(try IdrRequest.decode(message),
                                 vector.name) {
                guard let error = $0 as? IdrRequestError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(idrRequestErrorName(error), vector.error,
                               vector.name)
            }
        }
    }

    private func checkConnectionIdTlv(
        _ vector: SessionVector, message: [UInt8]
    ) throws {
        // The datagram itself always decodes — the identity codec is
        // what the vector exercises.
        let (envelope, payload) = try Envelope.decode(message)
        switch vector.kind {
        case .roundtrip:
            guard let hex = vector.connectionIdHex,
                  let expected = Hex.bytes(hex) else {
                return XCTFail("\(vector.name): missing connectionIdHex")
            }
            let connId = try ConnectionId.decode(extensions: envelope.extensions)
            XCTAssertEqual(connId?.bytes, expected, vector.name)
            // The whole datagram re-encodes byte-exactly.
            XCTAssertEqual(try envelope.encode(payload: Array(payload)),
                           message, vector.name)
        case .decodeReject:
            XCTAssertThrowsError(
                try ConnectionId.decode(extensions: envelope.extensions),
                vector.name
            ) {
                guard let error = $0 as? ConnectionIdError else {
                    return XCTFail("\(vector.name): foreign error \($0)")
                }
                XCTAssertEqual(connectionIdErrorName(error), vector.error,
                               vector.name)
            }
        }
    }
}
