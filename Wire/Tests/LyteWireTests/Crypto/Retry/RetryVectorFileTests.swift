import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/retry-v1.json byte-exact — the
// stateless retry-cookie transcript MAC and the CTRL 0x13/0x14 codecs
// both ends code against, on both platforms.

final class RetryVectorFileTests: XCTestCase {

    private func loadFile() throws -> RetryVectorFile {
        try RetryVectorFile.loadCommitted()
    }

    func testAllCookieVectors() throws {
        for vector in try loadFile().cookieVectors {
            let tuple = try XCTUnwrap(
                Hex.bytes(vector.tupleHex), vector.name
            )
            let message1 = try XCTUnwrap(
                Hex.bytes(vector.message1Hex), vector.name
            )
            let cookie = try XCTUnwrap(
                Hex.bytes(vector.cookieHex), vector.name
            )
            let verifyNow = try XCTUnwrap(
                Hex.uint64(vector.verifyNowHex), vector.name
            )
            let secrets = try vector.secretsHex.map {
                try XCTUnwrap(Hex.bytes($0), vector.name)
            }

            if vector.kind == .mint {
                // The frozen bytes: minting must reproduce them
                // exactly, on both platforms.
                let mintNow = try XCTUnwrap(
                    Hex.uint64(try XCTUnwrap(
                        vector.mintNowHex, vector.name
                    )), vector.name
                )
                let secret = try XCTUnwrap(
                    Hex.bytes(try XCTUnwrap(
                        vector.secretHex, vector.name
                    )), vector.name
                )
                XCTAssertEqual(
                    try RetryCookie.mint(
                        clientTuple: tuple, message1: message1,
                        now: mintNow, secret: secret
                    ),
                    cookie, vector.name
                )
            }

            // The verdict, mint rows and presented-bytes rows alike.
            let valid: Bool
            if let lifetimeHex = vector.lifetimeHex {
                let lifetime = try XCTUnwrap(
                    Hex.uint64(lifetimeHex), vector.name
                )
                valid = RetryCookie.verify(
                    cookie: cookie, clientTuple: tuple,
                    message1: message1, now: verifyNow,
                    secrets: secrets, lifetimeNanoseconds: lifetime
                )
            } else {
                valid = RetryCookie.verify(
                    cookie: cookie, clientTuple: tuple,
                    message1: message1, now: verifyNow, secrets: secrets
                )
            }
            XCTAssertEqual(valid, vector.valid, vector.name)
        }
    }

    func testAllMessageVectors() throws {
        for vector in try loadFile().messageVectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                XCTFail("\(vector.name): malformed messageHex")
                continue
            }
            switch (vector.kind, vector.codec) {
            case (.roundtrip, .challenge):
                let cookie = try XCTUnwrap(
                    Hex.bytes(try XCTUnwrap(
                        vector.cookieHex, vector.name
                    )), vector.name
                )
                let decoded = try RetryChallenge.decode(message)
                XCTAssertEqual(decoded.cookie, cookie, vector.name)
                XCTAssertEqual(
                    try decoded.encode(), message, vector.name
                )
            case (.roundtrip, .handshake1):
                let cookie = try XCTUnwrap(
                    Hex.bytes(try XCTUnwrap(
                        vector.cookieHex, vector.name
                    )), vector.name
                )
                let message1 = try XCTUnwrap(
                    Hex.bytes(try XCTUnwrap(
                        vector.message1Hex, vector.name
                    )), vector.name
                )
                let decoded = try RetryHandshake1.decode(message)
                XCTAssertEqual(decoded.cookie, cookie, vector.name)
                XCTAssertEqual(decoded.message1, message1, vector.name)
                XCTAssertEqual(
                    try decoded.encode(), message, vector.name
                )
            case (.decodeReject, .challenge):
                assertVectorReject(
                    RetryMessageError.self, vector.error, vector.name
                ) {
                    try RetryChallenge.decode(message)
                }
            case (.decodeReject, .handshake1):
                assertVectorReject(
                    RetryMessageError.self, vector.error, vector.name
                ) {
                    try RetryHandshake1.decode(message)
                }
            }
        }
    }
}
