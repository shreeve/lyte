import Foundation
import LyteTestKit
import XCTest

/// The repository boundaries only this package can see whole: the client
/// and host roles meet here (and in the browser package's tests, recorded
/// below), nothing depends on the system-test package, shipping client
/// code carries no test equipment, and ARQ carrier packing has one owner
/// (LyteWire).
final class SystemTestsLayoutTests: XCTestCase {
    private let sourceTree = RepositorySourceTree()

    private enum ProductRole {
        case client
        case host
    }

    func testClientAndHostRolesMeetOnlyInSystemTests() throws {
        for root in ["Client/Sources", "Client/Tests"] {
            XCTAssertEqual(
                try importers(below: root) { belongsToRole($0, role: .host) }, [],
                "\(root) must not import host modules")
        }
        for root in ["Host/Sources", "Host/Tests"] {
            XCTAssertEqual(
                try importers(below: root) { belongsToRole($0, role: .client) }, [],
                "\(root) must not import client modules")
        }

        let clientManifest = try source(at: "Client/Package.swift")
        XCTAssertFalse(clientManifest.contains("../Host"),
                       "Client must not depend on the Host package")
        XCTAssertFalse(clientManifest.contains("package: \"Host\""),
                       "Client targets must not import Host products")
        let hostManifest = try source(at: "Host/Package.swift")
        XCTAssertFalse(hostManifest.contains("../Client"),
                       "Host must not depend on the Client package")
        for package in ["Client", "Common", "Host", "Wire"] {
            XCTAssertFalse(
                try source(at: "\(package)/Package.swift").contains("../SystemTests"),
                "\(package) must not depend on the system-test package")
        }
    }

    /// The one other place the roles meet is the browser package's tests:
    /// they drive the browser client against a real in-process HostWire
    /// session, the engine lyte-control-peer serves to Chrome. Browser
    /// sources import no host module, and only the test target depends on
    /// Host products.
    func testBrowserMeetsTheHostRoleOnlyInItsTests() throws {
        XCTAssertEqual(
            try importers(below: "Browser/Sources") {
                belongsToRole($0, role: .host)
            }, [],
            "Browser/Sources must not import host modules")
        let manifest = try source(at: "Browser/Package.swift")
        let testTarget = try XCTUnwrap(
            manifest.range(of: ".testTarget("),
            "the Browser package declares its test target")
        XCTAssertNil(
            manifest.range(of: ".testTarget(", range: testTarget.upperBound
                ..< manifest.endIndex),
            "one Browser test target")
        var cursor = manifest.startIndex
        while let hostProduct = manifest.range(
            of: "package: \"Host\"", range: cursor..<manifest.endIndex
        ) {
            XCTAssertGreaterThan(
                hostProduct.lowerBound, testTarget.lowerBound,
                "only the Browser test target may depend on Host products")
            cursor = hostProduct.upperBound
        }
    }

    func testAttributedAndQualifiedImportsCannotEvadeTheBoundary() {
        let source = [
            "@testable " + "import HostWire",
            "package " + "import HostWire",
            "@preconcurrency public " + "import LyteClientShell",
            "import " + "struct HostCore.Pacer",
            "import " + "let LyteClientShell.defaultValue",
        ].joined(separator: "\n")
        XCTAssertEqual(
            SwiftSourceScanner.importedModules(in: source),
            ["HostWire", "HostWire", "LyteClientShell", "HostCore", "LyteClientShell"]
        )
    }

    func testShippingClientCodeCarriesNoTestEquipment() throws {
        let testKit = "Client/Sources/LyteClientTestKit/"
        XCTAssertEqual(
            try importers(below: "Client/Sources") {
                $0 == "LyteClientTestKit" || $0 == "LyteTestKit" || $0 == "XCTest"
            }.filter { !$0.hasPrefix(testKit) },
            [])
    }

    func testArqCarrierPackingLivesOnlyInWire() throws {
        for path in [
            "Client/Sources/LyteTransport/ReliableCtrlEndpoint.swift",
            "Host/Sources/HostWire/Session.swift",
        ] {
            let tokens = SwiftSourceScanner.tokens(in: try source(at: path))
            XCTAssertTrue(
                SwiftSourceScanner.contains(
                    ["maxDatagramPayloadByteCount", "="],
                    in: tokens
                ),
                "\(path) must inject its carrier ceiling into LyteWire"
            )
            XCTAssertTrue(
                tokens.contains("maxConnectionIdTaggedPlaintextByteCount"),
                "\(path) must consume the one connection-id budget"
            )
            XCTAssertFalse(
                SwiftSourceScanner.contains(
                    ["ArqFrame", ".", "decodeAll", "("], in: tokens
                ),
                "\(path) must not decode and re-cut LyteWire output"
            )
            XCTAssertFalse(
                tokens.contains { $0.lowercased().contains("repack") },
                "\(path) must not grow another downstream ARQ packer"
            )
        }
    }

    // MARK: - Scanning

    private func importers(
        below relativeRoot: String,
        matching predicate: (String) -> Bool
    ) throws -> [String] {
        let root = sourceTree.repositoryRoot.appendingPathComponent(relativeRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("cannot enumerate \(relativeRoot)")
            return []
        }

        var result: [String] = []
        for case let file as URL in enumerator
        where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if SwiftSourceScanner.importedModules(in: source)
                .contains(where: predicate) {
                result.append(sourceTree.relativePath(for: file))
            }
        }
        return result.sorted()
    }

    private func belongsToRole(_ module: String, role: ProductRole) -> Bool {
        switch role {
        case .host:
            return module.hasPrefix("Host") || module.hasPrefix("LyteHost")
        case .client:
            return ["Lyte", "LyteCorpus", "LyteHelperProtocol", "LyteHelperSecurity",
                    "LyteTransport", "LyteUI"]
                .contains(module)
                || module.hasPrefix("LyteClient")
        }
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: sourceTree.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
