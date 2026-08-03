import Foundation
import XCTest

final class COpusDeclarationRatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        if let override = ProcessInfo.processInfo.environment["LYTE_REPOSITORY_ROOT"] {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testCOpusSystemLibraryHasOneDeclarationAndOneModuleMap() throws {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.repositoryRoot.appendingPathComponent("CLEANUP.md").path))
        let manifestPaths = ["Package.swift", "Host/Package.swift", "Common/Package.swift"]
        let declaration = try NSRegularExpression(
            pattern: #"\.systemLibrary\s*\(\s*name:\s*\"COpus\""#
        )
        var declarations: [String] = []

        for path in manifestPaths {
            let source = try String(
                contentsOf: Self.repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            let range = NSRange(source.startIndex..., in: source)
            if declaration.firstMatch(in: source, range: range) != nil {
                declarations.append(path)
            }
        }
        XCTAssertEqual(declarations, ["Common/Package.swift"])

        var moduleMaps: [String] = []
        for rootPath in ["Common", "Host/Sources", "Sources"] {
            let root = Self.repositoryRoot.appendingPathComponent(rootPath)
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
                        file.path.replacingOccurrences(
                            of: Self.repositoryRoot.path + "/", with: ""
                        )
                    )
                }
            }
        }
        XCTAssertEqual(moduleMaps.sorted(), ["Common/COpus/module.modulemap"])
    }
}
