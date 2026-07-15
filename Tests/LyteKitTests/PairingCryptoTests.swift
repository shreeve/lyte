import XCTest
import Foundation
@testable import LyteKit

final class PairingCryptoTests: XCTestCase {
    func testHexRoundTrip() {
        let data = Data.random(count: 33)
        XCTAssertEqual(Data(hexString: data.hexString), data)
        XCTAssertEqual(Data(hexString: "0aFf10"), Data([0x0a, 0xff, 0x10]))
        XCTAssertNil(Data(hexString: "xyz0"))
        XCTAssertNil(Data(hexString: "abc"))   // odd length
    }

    func testKeyDerivationIsDeterministicAndTruncated() {
        let salt = Data(repeating: 0x42, count: 16)
        let k1 = PairingCrypto.aesKey(salt: salt, pin: "1234")
        let k2 = PairingCrypto.aesKey(salt: salt, pin: "1234")
        let k3 = PairingCrypto.aesKey(salt: salt, pin: "1235")
        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
        XCTAssertEqual(k1.count, 16)
        // Must equal SHA256(salt || pin)[0..<16]
        XCTAssertEqual(k1, PairingCrypto.sha256(salt, Data("1234".utf8)).prefix(16))
    }

    func testEcbRoundTripNoPadding() throws {
        let key = Data.random(count: 16)
        let plain = Data.random(count: 48)
        let enc = try PairingCrypto.encryptEcb(key: key, data: plain)
        XCTAssertEqual(enc.count, 48)          // no padding growth
        XCTAssertNotEqual(enc, plain)
        XCTAssertEqual(try PairingCrypto.decryptEcb(key: key, data: enc), plain)
    }

    func testCertSignatureExtraction() throws {
        let identity = try ClientIdentity.createEphemeral()
        let sig = try identity.certificateSignature
        XCTAssertEqual(sig.count, 256)         // RSA-2048 signature
    }

    func testPemToDer() throws {
        let identity = try ClientIdentity.createEphemeral()
        let der = try PEM.der(fromPEM: identity.certificatePEM)
        XCTAssertEqual(der, identity.certificateDER)
    }
}
