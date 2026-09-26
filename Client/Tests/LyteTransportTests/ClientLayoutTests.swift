import Foundation
import LyteClientTestKit
import XCTest

final class ClientLayoutTests: XCTestCase {
    /// The source-layout grammar: every manifest target owns exactly
    /// `Sources/<Target>/`, every test target `Tests/<Target>Tests/`, and
    /// no directory exists that the manifest does not declare.
    func testClientPackageKeepsTheDeclaredTargetGrammar() throws {
        let root = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
            .appendingPathComponent("Client")
        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8)
        let declaration = try NSRegularExpression(
            pattern: #"\.(target|executableTarget|testTarget)\(\s*name:\s*"([^"]+)""#)
        var sourceTargets: [String] = []
        var testTargets: [String] = []
        for match in declaration.matches(
            in: manifest, range: NSRange(manifest.startIndex..., in: manifest)
        ) {
            let kind = String(manifest[Range(match.range(at: 1), in: manifest)!])
            let name = String(manifest[Range(match.range(at: 2), in: manifest)!])
            if kind == "testTarget" {
                testTargets.append(name)
            } else {
                sourceTargets.append(name)
            }
        }
        XCTAssertFalse(sourceTargets.isEmpty)
        XCTAssertEqual(
            try directoryNames(at: root.appendingPathComponent("Sources")),
            sourceTargets.sorted())
        XCTAssertEqual(
            try directoryNames(at: root.appendingPathComponent("Tests")),
            testTargets.sorted())
        for name in testTargets {
            XCTAssertTrue(name.hasSuffix("Tests"), name)
        }
        for name in sourceTargets where name.hasSuffix("Tests") {
            XCTFail("\(name): reusable test equipment is a <Domain>TestKit")
        }
    }

    private func directoryNames(at root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.map(\.lastPathComponent).sorted()
    }
}
