import XCTest
import Network
import Darwin
@testable import LyteTransport

final class LocalNetworkAccessTests: XCTestCase {
    func testBonjourPolicyDenialIsDefinitive() {
        XCTAssertEqual(
            LocalNetworkAccessProblem.browserError(.dns(-65_570)),
            .permissionRequired)
    }

    func testOtherBrowserFailuresDoNotMasqueradeAsPermissionDenial() {
        XCTAssertNil(LocalNetworkAccessProblem.browserError(.dns(-65_568)))
        XCTAssertNil(LocalNetworkAccessProblem.browserError(.posix(.ETIMEDOUT)))
    }

    func testNetworkPathDenialIsDefinitiveEvenWithAmbiguousPosixError() {
        XCTAssertEqual(
            LocalNetworkAccessProblem.pathReason(.localNetworkDenied),
            .permissionRequired)
        XCTAssertNil(LocalNetworkAccessProblem.pathReason(.notAvailable))
    }

    func testConnectionPrefersExactPathDenial() {
        XCTAssertEqual(
            LocalNetworkAccessProblem.connectionError(
                .posix(.EHOSTUNREACH),
                pathReason: .localNetworkDenied),
            .permissionRequired)
    }

    func testResolverRouteErrorGetsQualifiedNotDefinitiveAdvice() {
        XCTAssertEqual(
            LocalNetworkAccessProblem.connectionError(
                .posix(.EHOSTUNREACH), pathReason: nil),
            .routeOrPermissionUnavailable)
        XCTAssertEqual(
            LocalNetworkAccessProblem.connectionError(
                .posix(.ENETUNREACH), pathReason: nil),
            .routeOrPermissionUnavailable)
    }

    func testBrowserReadinessClearsEarlierPolicyDenial() {
        var evidence = LocalNetworkAccessEvidence()
        evidence.observe(browserError: .dns(-65_570))
        XCTAssertEqual(evidence.problem, .permissionRequired)

        evidence.browserReady()
        XCTAssertNil(evidence.problem)
    }

    func testHostUnreachableGetsQualifiedRecoveryAdvice() {
        XCTAssertEqual(
            LocalNetworkAccessProblem.endpointError(
                .socketFailed(errno: EHOSTUNREACH)),
            .routeOrPermissionUnavailable)
    }

    func testHandshakeSendPreservesTheSyscallErrno() {
        XCTAssertThrowsError(try SocketHandshakeIO.validateSend(
            sent: -1, expected: 48, capturedErrno: EHOSTUNREACH
        )) { error in
            guard case TransportEndpointError.socketFailed(let code) = error
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(code, EHOSTUNREACH)
        }
    }

    func testNonSendFailuresDoNotMasqueradeAsLocalNetworkAccess() {
        XCTAssertNil(LocalNetworkAccessProblem.endpointError(
            .bindFailed(errno: EACCES)))
        XCTAssertNil(LocalNetworkAccessProblem.endpointError(
            .badAddress("not-an-address")))
        XCTAssertNil(LocalNetworkAccessProblem.endpointError(
            .socketFailed(errno: ECONNREFUSED)))
    }

    func testScanRetainsHostsAlongsideIndependentAccessEvidence() {
        let host = DiscoveredLyteHost(
            name: "pup", address: "10.0.0.232", port: 41_151,
            wireVersion: 1, publicKeyHash: nil)
        let scan = LyteDiscoveryScan(
            hosts: [host], accessProblem: .permissionRequired)

        XCTAssertEqual(scan.hosts, [host])
        XCTAssertEqual(scan.accessProblem, .permissionRequired)
        XCTAssertNil(scan.blockingAccessProblem)
    }

    func testAccessEvidenceBlocksOnlyWhenNoHostResolved() {
        let scan = LyteDiscoveryScan(
            hosts: [], accessProblem: .routeOrPermissionUnavailable)

        XCTAssertEqual(
            scan.blockingAccessProblem,
            .routeOrPermissionUnavailable)
    }
}
