import XCTest
@testable import Lyte

/// The diagnostic entry points read the environment only in a bundle
/// built with them; any other bundle sees none of it.
final class DiagnosticEnvironmentTests: XCTestCase {
    private let driving = [
        "LYTE_AUTOCONNECT": "pup",
        "LYTE_BENCHMARK_RUN_ID": "run-1",
        "LYTE_BENCHMARK_READBACK_RAW": "/tmp/frames.bgra",
    ]

    func testShippingBundleIgnoresTheEnvironment() {
        for info: [String: Any]? in [
            nil,
            [:],
            [DiagnosticEnvironment.infoKey: false],
            [DiagnosticEnvironment.infoKey: "YES"],
        ] {
            XCTAssertEqual(
                DiagnosticEnvironment.variables(info: info, environment: driving),
                [:])
        }
    }

    func testDiagnosticBundleReadsTheEnvironment() {
        XCTAssertEqual(
            DiagnosticEnvironment.variables(
                info: [DiagnosticEnvironment.infoKey: true],
                environment: driving),
            driving)
    }

    /// A synthetic-motion reference below its fixed geometry used to hit
    /// a precondition and crash the app; it is now the probe's reported
    /// setup error.
    @MainActor
    func testUndersizedSyntheticReferenceIsReportedNotFatal() {
        let probe = DiagnosticQualityProbe(
            environment: [
                "LYTE_BENCHMARK_SYNTHETIC_MOTION": "1",
                "LYTE_BENCHMARK_REFERENCE_WIDTH": "640",
                "LYTE_BENCHMARK_REFERENCE_HEIGHT": "400",
            ],
            enabled: true)
        XCTAssertEqual(probe.setupError, "synthetic_reference_below_960x600")
    }

    /// The test runner is not a diagnostic bundle: the benchmark claim
    /// stays unrequested whatever the environment says.
    func testUnmarkedProcessNeverClaimsABenchmarkRun() throws {
        XCTAssertFalse(DiagnosticEnvironment.isEnabled)
        XCTAssertFalse(DiagnosticRunIdentity.isRequested)
        XCTAssertFalse(try DiagnosticRunIdentity.publishIfRequested())
    }
}
