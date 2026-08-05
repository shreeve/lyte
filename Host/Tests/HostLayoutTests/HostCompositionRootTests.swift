import Foundation
import XCTest

final class HostCompositionRootTests: XCTestCase {
    private var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    func testExecutableEntryPointOnlyDelegatesToCompositionRoot() throws {
        let main = try source("main.swift")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            main,
            "HostApplication.main(arguments: CommandLine.arguments)"
        )
    }

    func testCompositionRootOwnsDispatchConstructionAndFailure() throws {
        let root = try source("HostApplication.swift")
        for witness in [
            "enum HostApplication",
            "static func main(arguments: [String])",
            "try run(arguments: arguments)",
            "let opts = try Options.parse(arguments)",
            "SessionWire(",
            "AvahiAdvertiser(",
            "AudioWire(",
            "DirectEyeLeg(",
        ] {
            XCTAssertTrue(root.contains(witness), "missing \(witness)")
        }
        XCTAssertFalse(root.contains("CommandLine.arguments"))
    }

    func testShippingHostHasNoPlaintextTransportMode() throws {
        for name in ["HostApplication.swift", "SessionWire.swift"] {
            let shippingSource = try source(name)
            XCTAssertFalse(
                shippingSource.contains("--insecure"),
                "shipping plaintext option returned in \(name)"
            )
            XCTAssertFalse(
                shippingSource.contains("testPassthrough"),
                "test transport entered shipping executable \(name)"
            )
        }
    }

    private func source(_ name: String) throws -> String {
        try String(
            contentsOfFile: packageRoot + "/Sources/lyte-host/" + name,
            encoding: .utf8
        )
    }
}
