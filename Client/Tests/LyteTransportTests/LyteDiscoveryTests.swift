import XCTest
import Foundation
@testable import LyteTransport
import LyteWire

// CL-5's testable core: the TXT identity parse and the pinned-key hash
// match. The browse/resolve legs need a live mDNS advertiser and are
// gated live against the HS-10 host (`lyte-host advertise`); the seam
// tested here is everything between the TXT bytes and the API surface.
final class LyteDiscoveryTests: XCTestCase {

    /// SHA-256(32 zero bytes) — independently computable
    /// (`head -c 32 /dev/zero | shasum -a 256`).
    private static let zeroKeyHash =
        "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"

    // MARK: - pkh hashing (both ends consume LyteCore's exact digest)

    func testPublicKeyHashMatchesKnownSha256Vector() {
        let hash = LyteDiscovery.publicKeyHash(
            ofStaticPublicKey: [UInt8](repeating: 0, count: 32))
        XCTAssertEqual(hash, Self.zeroKeyHash)
    }

    func testPublicKeyHashIsLowercased64Hex() {
        let hash = LyteDiscovery.publicKeyHash(
            ofStaticPublicKey: [UInt8](repeating: 0xAB, count: 32))
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
    }

    // MARK: - TXT parsing

    func testParsesWellFormedTxt() {
        let parsed = LyteDiscovery.parseTxt(
            ["v": "1", "pkh": Self.zeroKeyHash])
        XCTAssertEqual(parsed.wireVersion, 1)
        XCTAssertEqual(parsed.publicKeyHash, Self.zeroKeyHash)
    }

    func testUppercasePkhIsNormalizedLowercase() {
        let parsed = LyteDiscovery.parseTxt(
            ["v": "1", "pkh": Self.zeroKeyHash.uppercased()])
        XCTAssertEqual(parsed.publicKeyHash, Self.zeroKeyHash)
    }

    func testMissingRecordsYieldNilNotFailure() {
        let parsed = LyteDiscovery.parseTxt([:])
        XCTAssertNil(parsed.wireVersion)
        XCTAssertNil(parsed.publicKeyHash)
    }

    func testMalformedRecordsYieldNil() {
        // Non-numeric version, pkh wrong length, pkh non-hex.
        XCTAssertNil(LyteDiscovery.parseTxt(["v": "banana"]).wireVersion)
        XCTAssertNil(LyteDiscovery.parseTxt(["v": "300"]).wireVersion)
        XCTAssertNil(LyteDiscovery.parseTxt(["pkh": "abc123"]).publicKeyHash)
        XCTAssertNil(LyteDiscovery.parseTxt(
            ["pkh": String(repeating: "g", count: 64)]).publicKeyHash)
    }

    // MARK: - Host model

    func testWireVersionCompatibility() {
        let compatible = DiscoveredLyteHost(
            name: "pup", address: "10.0.0.249", port: 41003,
            wireVersion: WireVersion.major, publicKeyHash: Self.zeroKeyHash)
        XCTAssertTrue(compatible.speaksOurWireVersion)

        let future = DiscoveredLyteHost(
            name: "pup", address: "10.0.0.249", port: 41003,
            wireVersion: WireVersion.major &+ 1, publicKeyHash: Self.zeroKeyHash)
        XCTAssertFalse(future.speaksOurWireVersion)

        let unversioned = DiscoveredLyteHost(
            name: "pup", address: "10.0.0.249", port: 41003,
            wireVersion: nil, publicKeyHash: nil)
        XCTAssertFalse(unversioned.speaksOurWireVersion)
    }

    func testPinnedKeyRecognition() {
        let pinned = [UInt8](repeating: 0, count: 32)
        let host = DiscoveredLyteHost(
            name: "pup", address: "10.0.0.249", port: 41003,
            wireVersion: 1, publicKeyHash: Self.zeroKeyHash)
        XCTAssertTrue(host.matches(pinnedStaticPublicKey: pinned))
        XCTAssertFalse(host.matches(
            pinnedStaticPublicKey: [UInt8](repeating: 1, count: 32)))

        // No advertised hash → never a match, never a crash.
        let bare = DiscoveredLyteHost(
            name: "old", address: "10.0.0.7", port: 41000,
            wireVersion: nil, publicKeyHash: nil)
        XCTAssertFalse(bare.matches(pinnedStaticPublicKey: pinned))
    }

    // MARK: - Scan diagnosis

    func testDefinitiveResolverDenialOutranksQualifiedEvidence() {
        XCTAssertEqual(
            LyteDiscovery.combinedAccessProblem(
                browserProblem: .routeOrPermissionUnavailable,
                resolutionProblems: [.permissionRequired],
                hadUnresolvedService: true),
            .permissionRequired)
    }

    func testBrowserEvidenceSurvivesWithoutResolverEvidence() {
        for problem in [
            LocalNetworkAccessProblem.permissionRequired,
            .routeOrPermissionUnavailable,
        ] {
            XCTAssertEqual(
                LyteDiscovery.combinedAccessProblem(
                    browserProblem: problem,
                    resolutionProblems: [],
                    hadUnresolvedService: false),
                problem)
        }
    }

    func testResolverRouteEvidenceSurvivesAHealthyBrowser() {
        XCTAssertEqual(
            LyteDiscovery.combinedAccessProblem(
                browserProblem: nil,
                resolutionProblems: [.routeOrPermissionUnavailable],
                hadUnresolvedService: false),
            .routeOrPermissionUnavailable)
    }

    func testUnresolvedAdvertisedServiceIsNotReportedAsEmptyNetwork() {
        XCTAssertEqual(
            LyteDiscovery.combinedAccessProblem(
                browserProblem: nil,
                resolutionProblems: [],
                hadUnresolvedService: true),
            .routeOrPermissionUnavailable)
    }

    func testTrulyEmptySuccessfulBrowseHasNoInventedAccessProblem() {
        XCTAssertNil(LyteDiscovery.combinedAccessProblem(
            browserProblem: nil,
            resolutionProblems: [],
            hadUnresolvedService: false))
    }
}
