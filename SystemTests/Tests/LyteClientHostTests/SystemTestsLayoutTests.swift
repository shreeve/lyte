import Foundation
import LyteTestKit
import XCTest

/// The repository boundaries only this package can see whole: the client
/// and host roles meet here (and in the browser package's tests, recorded
/// below), nothing depends on the system-test package, and shipping client
/// code carries no test equipment. That both roles pack ARQ within the one
/// conn-id-tagged budget is behavior, gated where each role sends
/// (ReliableCtrlGateTests, ArqCtrlGateTests).
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
    /// sources import no host module.
    func testBrowserMeetsTheHostRoleOnlyInItsTests() throws {
        XCTAssertEqual(
            try importers(below: "Browser/Sources") {
                belongsToRole($0, role: .host)
            }, [],
            "Browser/Sources must not import host modules")
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
