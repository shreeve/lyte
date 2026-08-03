import XCTest
import LyteCore
import LyteWire
import LyteWireTestKit

// The stateless retry cookie: mint/verify determinism, the transcript
// binding (tuple, timestamp window, msg1), and secret rotation. The
// MAC itself is anchored against an INDEPENDENT HMAC-SHA256 built here
// on LyteCore's FIPS-verified Sha256 — RetryCookie's swift-crypto HMAC
// never grades its own homework.

final class RetryCookieTests: XCTestCase {

    private static let secret = (0..<32).map { UInt8(0x40 &+ $0) }
    private static let otherSecret = (0..<32).map { UInt8(0x80 &+ $0) }
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

    func testMintIsDeterministic() throws {
        // Pure function of (tuple, msg1, now, secret) — the property
        // that makes the host's flood answer stateless.
        let a = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        let b = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        XCTAssertEqual(a, b)
    }

    // MARK: Verify — the window

    func testVerifyAcceptsWithinLifetimeWindow() throws {
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        for elapsed: UInt64 in
            [0, 1, RetryCookie.defaultLifetimeNanoseconds]
        {
            XCTAssertTrue(RetryCookie.verify(
                cookie: cookie, clientTuple: Self.tuple,
                message1: Self.message1, now: Self.now + elapsed,
                secrets: [Self.secret]
            ), "elapsed \(elapsed)")
        }
    }

    func testVerifyRejectsExpiredAndFutureCookies() throws {
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        // One nanosecond past the lifetime: harvested, dead.
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1,
            now: Self.now + RetryCookie.defaultLifetimeNanoseconds + 1,
            secrets: [Self.secret]
        ))
        // A stamp from the future: forged — the same monotonic clock
        // minted it.
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now - 1,
            secrets: [Self.secret]
        ))
        // A caller-chosen shorter lifetime is honored.
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now + 1_000_001,
            secrets: [Self.secret], lifetimeNanoseconds: 1_000_000
        ))
    }

    // MARK: Verify — the bindings

    func testVerifyRejectsForeignTupleOrMessage() throws {
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        // Same cookie presented from a different address: the whole
        // point of the mechanism.
        var movedTuple = Self.tuple
        movedTuple[3] &+= 1
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie, clientTuple: movedTuple,
            message1: Self.message1, now: Self.now,
            secrets: [Self.secret]
        ))
        // Same address, different msg1: one cookie authorizes one
        // exact handshake attempt.
        var alteredMessage = Self.message1
        alteredMessage[40] ^= 0x01
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: alteredMessage, now: Self.now,
            secrets: [Self.secret]
        ))
    }

    func testVerifyRejectsTamperedOrMalformedCookies() throws {
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        for flipIndex in [0, 7, 8, 23] {
            var tampered = cookie
            tampered[flipIndex] ^= 0x01
            // Flipping a timestamp byte invalidates the MAC (or the
            // window); flipping a MAC byte invalidates the MAC.
            XCTAssertFalse(RetryCookie.verify(
                cookie: tampered, clientTuple: Self.tuple,
                message1: Self.message1,
                now: Self.now + RetryCookie.defaultLifetimeNanoseconds,
                secrets: [Self.secret]
            ), "flipped byte \(flipIndex)")
        }
        // Wrong sizes are quietly false — the flood path never throws.
        XCTAssertFalse(RetryCookie.verify(
            cookie: Array(cookie.dropLast()), clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now,
            secrets: [Self.secret]
        ))
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie + [0], clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now,
            secrets: [Self.secret]
        ))
        XCTAssertFalse(RetryCookie.verify(
            cookie: [], clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now,
            secrets: [Self.secret]
        ))
    }

    // MARK: Rotation

    func testRotationWindow() throws {
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: Self.secret
        )
        // After rotation the previous secret still verifies…
        XCTAssertTrue(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now + 1,
            secrets: [Self.otherSecret, Self.secret]
        ))
        // …but current-only does not, and neither does a stranger.
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now + 1,
            secrets: [Self.otherSecret]
        ))
        XCTAssertFalse(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now + 1,
            secrets: []
        ))
        // Wrong-length entries are skipped, not consulted.
        XCTAssertTrue(RetryCookie.verify(
            cookie: cookie, clientTuple: Self.tuple,
            message1: Self.message1, now: Self.now + 1,
            secrets: [[1, 2, 3], Self.secret]
        ))
    }

    // MARK: Structural misuse of mint

    func testMintRejectsStructuralMisuse() {
        XCTAssertThrowsError(try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.message1,
            now: Self.now, secret: [1, 2, 3]
        )) {
            XCTAssertEqual(
                $0 as? RetryCookieError, .invalidSecretLength(3)
            )
        }
        XCTAssertThrowsError(try RetryCookie.mint(
            clientTuple: [], message1: Self.message1,
            now: Self.now, secret: Self.secret
        )) {
            XCTAssertEqual(
                $0 as? RetryCookieError, .invalidTupleLength(0)
            )
        }
        XCTAssertThrowsError(try RetryCookie.mint(
            clientTuple: [UInt8](repeating: 0, count: 256),
            message1: Self.message1,
            now: Self.now, secret: Self.secret
        )) {
            XCTAssertEqual(
                $0 as? RetryCookieError, .invalidTupleLength(256)
            )
        }
    }

    // MARK: Composition — the HS-9 escalation flow end to end

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
