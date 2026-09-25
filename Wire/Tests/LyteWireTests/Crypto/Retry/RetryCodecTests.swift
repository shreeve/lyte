import XCTest
import LyteWire
import LyteWireTestKit

// The retry message codecs (CTRL 0x13/0x14), anchored by hand-built
// byte layouts — the anchor retry-v1.json's messageVectors are checked
// against, so vectorgen never grades its own homework — plus the encode
// guards. Decode rejects live in the vectors.

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

    func testResubmissionCarriesAnyCookieLength() throws {
        // The cookie is opaque to the client: the codec carries any
        // 1…255 bytes even though RetryCookie's v1 interior is 24.
        for length in [1, 255] {
            let cookie = [UInt8](repeating: 0x5A, count: length)
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
        assertThrows(RetryMessageError.invalidCookieLength(0)) {
            try RetryChallenge(cookie: []).encode()
        }
        assertThrows(RetryMessageError.invalidCookieLength(256)) {
            try RetryChallenge(
                cookie: [UInt8](repeating: 0, count: 256)
            ).encode()
        }
        assertThrows(RetryMessageError.message1TooShort(95)) {
            try RetryHandshake1(
                cookie: Self.cookie,
                message1: Array(Self.message1.prefix(95))
            ).encode()
        }
    }
}
