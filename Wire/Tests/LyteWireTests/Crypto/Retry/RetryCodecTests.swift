import XCTest
import LyteWire
import LyteWireTestKit

// The retry message codecs (CTRL 0x13/0x14), anchored by hand-built
// byte layouts — the anchor retry-v1.json's messageVectors are checked
// against, so vectorgen never grades its own homework.

final class RetryCodecTests: XCTestCase {

    private static let cookie = (0..<24).map { UInt8(0xA0 &+ $0) }
    private static let message1 = (0..<96).map { UInt8($0) }

    // MARK: Hand-computed anchors

    func testChallengeHandComputedBytes() throws {
        let message = RetryChallenge(cookie: Self.cookie)
        let encoded = try message.encode()
        XCTAssertEqual(encoded, [0x13, 0x18] + Self.cookie)
        XCTAssertEqual(try RetryChallenge.decode(encoded), message)
        XCTAssertEqual(
            CtrlMessageType.peek(encoded), CtrlMessageType.retryChallenge
        )
    }

    func testHandshake1HandComputedBytes() throws {
        let message = RetryHandshake1(
            cookie: Self.cookie, message1: Self.message1
        )
        let encoded = try message.encode()
        XCTAssertEqual(
            encoded, [0x14, 0x18] + Self.cookie + Self.message1
        )
        XCTAssertEqual(try RetryHandshake1.decode(encoded), message)
        XCTAssertEqual(
            CtrlMessageType.peek(encoded),
            CtrlMessageType.retryHandshake1
        )
    }

    func testEchoingInitializerCarriesCookieVerbatim() throws {
        let challenge = RetryChallenge(cookie: Self.cookie)
        let resubmission = RetryHandshake1(
            echoing: challenge, message1: Self.message1
        )
        XCTAssertEqual(resubmission.cookie, Self.cookie)
        XCTAssertEqual(resubmission.message1, Self.message1)
    }

    func testCookieLengthIsGenericOnTheWire() throws {
        // The cookie is opaque to the client: the codec carries any
        // 1…255 bytes even though RetryCookie's v1 interior is 24.
        for length in [1, 255] {
            let cookie = [UInt8](repeating: 0x5A, count: length)
            let challenge = try RetryChallenge(cookie: cookie).encode()
            XCTAssertEqual(
                try RetryChallenge.decode(challenge).cookie, cookie
            )
            let resubmission = try RetryHandshake1(
                cookie: cookie, message1: Self.message1
            ).encode()
            XCTAssertEqual(
                try RetryHandshake1.decode(resubmission).cookie, cookie
            )
        }
    }

    // MARK: Encode guards

    func testEncodeRejectsMisSizedFields() {
        XCTAssertThrowsError(
            try RetryChallenge(cookie: []).encode()
        ) {
            XCTAssertEqual(
                $0 as? RetryMessageError, .invalidCookieLength(0)
            )
        }
        XCTAssertThrowsError(
            try RetryChallenge(
                cookie: [UInt8](repeating: 0, count: 256)
            ).encode()
        ) {
            XCTAssertEqual(
                $0 as? RetryMessageError, .invalidCookieLength(256)
            )
        }
        XCTAssertThrowsError(
            try RetryHandshake1(
                cookie: Self.cookie,
                message1: Array(Self.message1.prefix(95))
            ).encode()
        ) {
            XCTAssertEqual(
                $0 as? RetryMessageError, .message1TooShort(95)
            )
        }
    }

    // MARK: Decode rejects — hostile bytes throw, never trap

    func testDecodeRejectsHostileBytes() {
        // Truncation: bare type byte, then a cookieLen the payload
        // cannot honor.
        XCTAssertThrowsError(try RetryChallenge.decode([0x13])) {
            XCTAssertEqual($0 as? RetryMessageError, .truncatedMessage)
        }
        XCTAssertThrowsError(
            try RetryChallenge.decode([0x13, 0x18] + Self.cookie.prefix(23))
        ) {
            XCTAssertEqual($0 as? RetryMessageError, .truncatedMessage)
        }
        XCTAssertThrowsError(
            try RetryHandshake1.decode([0x14, 0x18] + Self.cookie.prefix(10))
        ) {
            XCTAssertEqual($0 as? RetryMessageError, .truncatedMessage)
        }
        // Zero cookieLen — the loud zero-fill bug.
        XCTAssertThrowsError(
            try RetryChallenge.decode([0x13, 0x00])
        ) {
            XCTAssertEqual($0 as? RetryMessageError, .zeroCookieLength)
        }
        XCTAssertThrowsError(
            try RetryHandshake1.decode([0x14, 0x00] + Self.message1)
        ) {
            XCTAssertEqual($0 as? RetryMessageError, .zeroCookieLength)
        }
        // Trailing bytes after a challenge — exactly its layout.
        XCTAssertThrowsError(
            try RetryChallenge.decode([0x13, 0x18] + Self.cookie + [0x00])
        ) {
            XCTAssertEqual($0 as? RetryMessageError, .trailingBytes)
        }
        // Foreign type bytes.
        XCTAssertThrowsError(
            try RetryChallenge.decode([0x14, 0x18] + Self.cookie)
        ) {
            XCTAssertEqual(
                $0 as? RetryMessageError, .unexpectedType(0x14)
            )
        }
        XCTAssertThrowsError(
            try RetryHandshake1.decode(
                [0x13, 0x18] + Self.cookie + Self.message1
            )
        ) {
            XCTAssertEqual(
                $0 as? RetryMessageError, .unexpectedType(0x13)
            )
        }
        // A resubmission whose msg1 could never handshake.
        XCTAssertThrowsError(
            try RetryHandshake1.decode(
                [0x14, 0x18] + Self.cookie + Self.message1.prefix(95)
            )
        ) {
            XCTAssertEqual(
                $0 as? RetryMessageError, .message1TooShort(95)
            )
        }
    }
}
