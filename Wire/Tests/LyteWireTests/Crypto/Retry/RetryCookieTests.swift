import XCTest
import LyteCore
import LyteWire
import LyteWireTestKit

// The stateless retry cookie. The MAC is anchored against an INDEPENDENT
// HMAC-SHA256 built here on LyteCore's FIPS-verified Sha256, so
// RetryCookie's swift-crypto HMAC never grades its own homework; the
// window, binding and rotation verdicts live in retry-v1.json's
// cookieVectors, and the tests here carry the cases those do not.

final class RetryCookieTests: XCTestCase {

    private static let secret = (0..<32).map { UInt8(0x40 &+ $0) }
    private static let tuple: [UInt8] = [10, 0, 0, 249, 0xA0, 0x2B]
    private static let message1 = (0..<122).map {
        UInt8(truncatingIfNeeded: $0 * 3)
    }
    private static let now: UInt64 = 5_000_000_000

    // MARK: The MAC, against an independent implementation

    func testCookieBytesMatchIndependentHmac() throws {
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        XCTAssertEqual(cookie.count, RetryCookie.byteCount)
        // timestamp u64 LE at offset 0.
        var expected = [UInt8]()
        for shift in stride(from: 0, to: 64, by: 8) {
            expected.append(UInt8(truncatingIfNeeded: Self.now >> shift))
        }
        XCTAssertEqual(Array(cookie.prefix(8)), expected)
        // mac = HMAC-SHA256(secret, "lyte-retry-cookie-v1" ‖ ts ‖
        // tupleLen ‖ tuple ‖ msg1) truncated to 16 — recomputed via
        // RFC 2104 over LyteCore's Sha256.
        var transcript = Array("lyte-retry-cookie-v1".utf8) + expected
        transcript.append(UInt8(Self.tuple.count))
        transcript += Self.tuple
        transcript += Self.message1
        let mac = Self.independentHmacSha256(
            key: Self.secret, message: transcript
        )
        XCTAssertEqual(Array(cookie.suffix(16)), Array(mac.prefix(16)))
    }

    // MARK: Verify — cases the vectors do not carry

    func testVerifyRejectsTamperedOrMalformedCookies() throws {
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        // The timestamp's high byte and the MAC's last byte are bound too.
        for flipIndex in [7, 23] {
            var tampered = cookie
            tampered[flipIndex] ^= 0x01
            XCTAssertFalse(RetryCookie.verify(
                cookie: tampered, clientTuple: Self.tuple,
                message1: Self.message1,
                now: Self.now + RetryCookie.defaultLifetimeNanoseconds,
                secrets: [Self.secret]
            ), "flipped byte \(flipIndex)")
        }
        // Wrong sizes are quietly false — the flood path never throws.
        for malformed in [cookie + [0], []] {
            XCTAssertFalse(RetryCookie.verify(
                cookie: malformed, clientTuple: Self.tuple,
                message1: Self.message1, now: Self.now,
                secrets: [Self.secret]
            ))
        }
    }

    func testVerifySkipsWrongLengthSecretsAndFailsWithNone() throws {
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        XCTAssertTrue(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now + 1,
            secrets: [[1, 2, 3], Self.secret]
        ))
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now + 1,
            secrets: []
        ))
    }

    // MARK: Structural misuse of mint

    func testMintRejectsStructuralMisuse() {
        assertThrows(RetryCookieError.invalidSecretLength(3)) {
            try RetryCookie.mint(
                clientTuple: Self.tuple, message1: Self.message1,
                now: Self.now, secret: [1, 2, 3]
            )
        }
        assertThrows(RetryCookieError.invalidTupleLength(0)) {
            try RetryCookie.mint(
                clientTuple: [], message1: Self.message1,
                now: Self.now, secret: Self.secret
            )
        }
        assertThrows(RetryCookieError.invalidTupleLength(256)) {
            try RetryCookie.mint(
                clientTuple: [UInt8](repeating: 0, count: 256),
                message1: Self.message1,
                now: Self.now, secret: Self.secret
            )
        }
    }

    // MARK: Composition — the escalation flow end to end

    func testFullRetryFlowWithRealNoiseMessage1() throws {
        // A real IK msg1 through the whole loop: flood-mode host mints
        // from (tuple, now, secret) alone, forgets everything; the
        // client echoes the cookie with the SAME msg1 verbatim; the
        // host verifies against the arrival tuple and only then spends
        // the crypto — and the handshake it spent it on completes.
        let hostStatic = try NoiseKeyPair(
            privateKey: (1...32).map { UInt8($0) }
        )
        let clientStatic = try NoiseKeyPair(
            privateKey: (33...64).map { UInt8($0) }
        )
        var initiator = try NoiseSession(
            role: .initiator, staticKeys: clientStatic,
            remoteStaticPublicKey: hostStatic.publicKey
        )
        let message1 = try initiator.writeMessage1()

        // Host under flood: challenge, statelessly.
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: message1,
            now: Self.now, secret: Self.secret
        )
        let challengeBytes = try RetryChallenge(cookie: cookie).encode()

        // Client: decode the challenge, resubmit the SAME msg1.
        let challenge = try RetryChallenge.decode(challengeBytes)
        let resubmissionBytes = try RetryHandshake1(
            echoing: challenge, message1: message1
        ).encode()

        // Host: verify against the tuple the datagram came from, at a
        // later now, then handshake for real.
        let resubmission = try RetryHandshake1.decode(resubmissionBytes)
        XCTAssertTrue(RetryCookie.verify(
            cookie: resubmission.cookie, clientTuple: Self.tuple,
            message1: resubmission.message1,
            now: Self.now + 200_000_000, secrets: [Self.secret]
        ))
        // A spoofed source never gets this far.
        XCTAssertFalse(RetryCookie.verify(
            cookie: resubmission.cookie,
            clientTuple: [192, 168, 1, 66, 0x13, 0x37],
            message1: resubmission.message1,
            now: Self.now + 200_000_000, secrets: [Self.secret]
        ))

        var responder = try NoiseSession(
            role: .responder, staticKeys: hostStatic
        )
        _ = try responder.readMessage1(resubmission.message1[...])
        let message2 = try responder.writeMessage2()
        _ = try initiator.readMessage2(message2[...])
    }

    // MARK: RFC 2104 HMAC over LyteCore's Sha256 (test-only oracle)

    private static func independentHmacSha256(
        key: [UInt8], message: [UInt8]
    ) -> [UInt8] {
        var normalizedKey = key.count > 64 ? Sha256.digest(key) : key
        normalizedKey += [UInt8](
            repeating: 0, count: 64 - normalizedKey.count
        )
        let inner = normalizedKey.map { $0 ^ 0x36 }
        let outer = normalizedKey.map { $0 ^ 0x5C }
        return Sha256.digest(outer + Sha256.digest(inner + message))
    }
}
