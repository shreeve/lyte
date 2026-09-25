import LyteTestKit
import XCTest

/// The two roles are independent ends: client and host code import none of
/// each other's modules. They meet only in SystemTests and in the browser
/// package's tests, which drive the browser client against a real HostWire
/// session. Shipping client code carries no test equipment.
final class RoleBoundaryTests: XCTestCase {
    private let tree = RepositorySourceTree()

    func testClientAndHostImportNoneOfEachOthersModules() throws {
        for root in ["Client/Sources", "Client/Tests", "Browser/Sources"] {
            XCTAssertEqual(try importers(below: root, of: Self.isHostModule),
                           [], "\(root) must not import host modules")
        }
        for root in ["Host/Sources", "Host/Tests"] {
            XCTAssertEqual(try importers(below: root, of: Self.isClientModule),
                           [], "\(root) must not import client modules")
        }
    }

    func testShippingClientCodeCarriesNoTestEquipment() throws {
        let testKit = "Client/Sources/LyteClientTestKit/"
        XCTAssertEqual(
            try importers(below: "Client/Sources") {
                ["LyteClientTestKit", "LyteTestKit", "XCTest"].contains($0)
            }.filter { !$0.hasPrefix(testKit) },
            [])
    }

    private static func isHostModule(_ module: String) -> Bool {
        module.hasPrefix("Host") || module.hasPrefix("LyteHost")
    }

    private static func isClientModule(_ module: String) -> Bool {
        ["Lyte", "LyteCorpus", "LyteHelperProtocol", "LyteHelperSecurity",
         "LyteTransport", "LyteUI"].contains(module)
            || module.hasPrefix("LyteClient")
    }

    private func importers(
        below root: String, of predicate: (String) -> Bool
    ) throws -> [String] {
        try tree.swiftFiles(below: root).filter {
            SwiftSourceScanner.importedModules(in: try tree.source(of: $0))
                .contains(where: predicate)
        }.map(tree.relativePath(for:)).sorted()
    }
}
