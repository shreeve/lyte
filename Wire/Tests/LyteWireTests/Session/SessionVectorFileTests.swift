import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/session-v1.json byte-exact — the
// promoted end-side codecs (conn-id TLV value, path challenge/response,
// IDR request) both ends now code against, on both platforms.

final class SessionVectorFileTests: XCTestCase {

    private func loadFile() throws -> SessionVectorFile {
        try SessionVectorFile.loadCommitted()
    }

    func testAllSessionVectors() throws {
        for vector in try loadFile().vectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                XCTFail("\(vector.name): malformed messageHex")
                continue
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
            assertVectorReject(
                PathMessageError.self, vector.error, vector.name
            ) {
                try PathChallenge.decode(message)
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
            assertVectorReject(
                PathMessageError.self, vector.error, vector.name
            ) {
                try PathResponse.decode(message)
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
            assertVectorReject(
                IdrRequestError.self, vector.error, vector.name
            ) {
                try IdrRequest.decode(message)
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
            assertVectorReject(
                ConnectionIdError.self, vector.error, vector.name
            ) {
                try ConnectionId.decode(extensions: envelope.extensions)
            }
        }
    }
}
