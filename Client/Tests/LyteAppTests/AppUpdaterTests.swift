import XCTest
@testable import Lyte

/// Sparkle starts only in a bundle that carries a feed and a public key,
/// and never in a diagnostic build.
final class AppUpdaterTests: XCTestCase {
    private let feed = "https://github.com/shreeve/lyte/releases/latest/download/appcast.xml"

    func testAReleaseBundleWithFeedAndKeyStartsTheUpdater() {
        XCTAssertTrue(AppUpdater.shouldStart(info: [
            "SUFeedURL": feed, "SUPublicEDKey": "YG6je6jUi4/f6LsqbgO1yP9n1CRwR+qWn8BGIp973M0=",
        ]))
    }

    func testABundleWithoutAKeyOrFeedStaysDormant() {
        XCTAssertFalse(AppUpdater.shouldStart(info: nil))
        XCTAssertFalse(AppUpdater.shouldStart(info: ["SUFeedURL": feed]))
        XCTAssertFalse(AppUpdater.shouldStart(info: ["SUFeedURL": feed, "SUPublicEDKey": ""]))
        XCTAssertFalse(AppUpdater.shouldStart(info: ["SUPublicEDKey": "key"]))
    }

    func testADiagnosticBundleNeverOffersToReplaceItself() {
        XCTAssertFalse(AppUpdater.shouldStart(info: [
            "SUFeedURL": feed, "SUPublicEDKey": "key",
            DiagnosticEnvironment.infoKey: true,
        ]))
    }
}
