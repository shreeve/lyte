import Foundation
import LyteTestKit
import XCTest

final class COpusDeclarationRatchetTests: XCTestCase {
    func testCOpusSystemLibraryHasOneDeclarationAndOneModuleMap() throws {
        let tree = RepositorySourceTree()
        let manifestPaths = [
            "Client/Package.swift", "Common/Package.swift", "Host/Package.swift",
            "SystemTests/Package.swift", "Wire/Package.swift",
        ]
        let declaration = try NSRegularExpression(
            pattern: #"\.systemLibrary\s*\(\s*name:\s*\"COpus\""#
        )
        var declarations: [String] = []

        for path in manifestPaths {
            let source = try String(
                contentsOf: tree.repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            let range = NSRange(source.startIndex..., in: source)
            if declaration.firstMatch(in: source, range: range) != nil {
                declarations.append(path)
            }
        }
        XCTAssertEqual(declarations, ["Common/Package.swift"])

        var moduleMaps: [String] = []
        for rootPath in [
            "Client/Sources", "Common/Sources", "Host/Sources", "Wire/Sources",
        ] {
            let root = tree.repositoryRoot.appendingPathComponent(rootPath)
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil
            ) else {
                XCTFail("cannot enumerate \(rootPath)")
                continue
            }
            for case let file as URL in files
            where file.lastPathComponent == "module.modulemap" {
                let source = try String(contentsOf: file, encoding: .utf8)
                if source.contains("module COpus") {
                    moduleMaps.append(
                        tree.relativePath(for: file)
                    )
                }
            }
        }
        XCTAssertEqual(
            moduleMaps.sorted(),
            ["Common/Sources/COpus/module.modulemap"]
        )
    }
}
