import Foundation
import LyteTestKit
import XCTest

final class RepositorySourceTreeTests: XCTestCase {
    func testEveryRequiredProductionRootExistsAndContainsSwift() throws {
        let tree = RepositorySourceTree()
        let files = try tree.productionSwiftFiles()
        let coveredRoots = Set(files.map { file in
            tree.productionSourceRoots.first { root in
                file.path.hasPrefix(root.standardizedFileURL.path + "/")
            }!.standardizedFileURL.path
        })

        XCTAssertEqual(coveredRoots.count, tree.productionSourceRoots.count)
    }

    func testMissingRootFailsClosed() {
        let tree = RepositorySourceTree(
            repositoryRoot: URL(fileURLWithPath: "/lyte-root-that-does-not-exist")
        )

        XCTAssertThrowsError(try tree.productionSwiftFiles()) { error in
            XCTAssertTrue(error is RepositorySourceTreeError)
        }
    }

    func testScannerFindsTwinsAndHonorsOnlyExplicitExclusions() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent(
            "lyte-source-tree-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: scratch) }

        let tree = RepositorySourceTree(repositoryRoot: scratch)
        for (index, root) in tree.productionSourceRoots.enumerated() {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let source = index == 3 ? "struct ForbiddenTwin {}\n" : "// clean\n"
            try Data(source.utf8).write(
                to: root.appendingPathComponent("Source\(index).swift")
            )
        }

        let violations = try tree.violations(containing: ["ForbiddenTwin"])
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations[0].hasPrefix("Host/Sources/Source3.swift:"))

        let excluded = try tree.violations(
            containing: ["ForbiddenTwin"],
            excludingRelativePaths: ["Host/Sources/Source3.swift"]
        )
        XCTAssertTrue(excluded.isEmpty)
    }
}
