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

    /// A tree reached through a symlink still relativizes: the root may
    /// be spelled through the link while files come back from the
    /// enumerator by their real path (macOS spells `/tmp` checkouts
    /// `/private/tmp`), and ratchets hash these relative paths.
    func testRelativePathsSurviveSymlinkedRoots() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent(
            "lyte-relative-path-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: scratch) }
        let real = scratch.appendingPathComponent("real")
        let link = scratch.appendingPathComponent("link")
        try fileManager.createDirectory(
            at: real.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        let file = real.appendingPathComponent("sub/File.swift")
        try Data("// file\n".utf8).write(to: file)
        try fileManager.createSymbolicLink(
            at: link, withDestinationURL: real)

        XCTAssertEqual(
            RepositorySourceTree(repositoryRoot: link).relativePath(for: file),
            "sub/File.swift")
        XCTAssertEqual(
            RepositorySourceTree.relativePath(
                of: link.appendingPathComponent("sub/File.swift"), below: real),
            "sub/File.swift")
        let enumerated = try XCTUnwrap(
            fileManager.enumerator(at: real, includingPropertiesForKeys: nil))
        let names = enumerated.compactMap { $0 as? URL }.map {
            RepositorySourceTree.relativePath(of: $0, below: real)
        }
        XCTAssertEqual(names.sorted(), ["sub", "sub/File.swift"])
    }

    func testOnlyImmediateTestKitTargetsAreExcluded() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent(
            "lyte-testkit-boundary-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: scratch) }

        let tree = RepositorySourceTree(repositoryRoot: scratch)
        for root in tree.productionSourceRoots {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try Data("// clean\n".utf8).write(
                to: root.appendingPathComponent("Source.swift")
            )
        }

        let clientRoot = scratch.appendingPathComponent("Client/Sources")
        let targetTestKit = clientRoot.appendingPathComponent(
            "LyteClientTestKit"
        )
        let hiddenTestKit = clientRoot.appendingPathComponent(
            "LyteTransport/HiddenTestKit"
        )
        for directory in [targetTestKit, hiddenTestKit] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data("struct ForbiddenTwin {}\n".utf8).write(
                to: directory.appendingPathComponent("Twin.swift")
            )
        }

        let scanned = try tree.productionSwiftFiles().map(tree.relativePath(for:))
        XCTAssertTrue(scanned.contains(
            "Client/Sources/LyteTransport/HiddenTestKit/Twin.swift"))
        XCTAssertFalse(scanned.contains(
            "Client/Sources/LyteClientTestKit/Twin.swift"))
    }
}
