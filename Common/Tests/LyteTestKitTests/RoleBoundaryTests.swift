import LyteTestKit
import XCTest

/// The two roles are independent ends: client and host code import none of
/// each other's modules. They meet only in SystemTests and in the browser
/// package's tests, which drive the browser client against a real HostWire
/// session. No shipping target imports test equipment: XCTest, a
/// `*TestKit` or the vector builders.
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

    func testShippingCodeCarriesNoTestEquipment() throws {
        for root in ["Common/Sources", "Wire/Sources", "Host/Sources",
                     "Client/Sources", "Browser/Sources"] {
            XCTAssertEqual(
                try importers(below: root, of: Self.isTestEquipment)
                    .filter { !Self.isTestEquipmentTarget($0) },
                [], "\(root) shipping targets must not import test equipment")
        }
    }

    private static func isTestEquipment(_ module: String) -> Bool {
        module == "XCTest" || module.hasSuffix("TestKit")
            || module.hasPrefix("LyteWireVectorGen")
    }

    /// Test kits and the vector builders are test equipment themselves.
    private static func isTestEquipmentTarget(_ path: String) -> Bool {
        let target = path.split(separator: "/").dropFirst(2).first ?? ""
        return target.hasSuffix("TestKit")
            || target.hasPrefix("LyteWireVectorGen")
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
