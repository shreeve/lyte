import Foundation
import LyteCore
import LyteTestKit
import XCTest

final class COpusDeclarationRatchetTests: XCTestCase {
    func testCOpusIsOnePinnedSourceLeafWithoutAmbientLinkage() throws {
        let tree = RepositorySourceTree()
        let manifestPaths = [
            "Client/Package.swift", "Common/Package.swift", "Host/Package.swift",
            "SystemTests/Package.swift", "Wire/Package.swift",
        ]
        let targetDeclaration = try NSRegularExpression(
            pattern: #"\.target\s*\(\s*name:\s*"COpus""#
        )
        let systemDeclaration = try NSRegularExpression(
            pattern: #"\.systemLibrary\s*\(\s*name:\s*"COpus""#
        )
        var declarations: [String] = []
        var manifestText = ""

        for path in manifestPaths {
            let source = try String(
                contentsOf: tree.repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            manifestText += source
            let range = NSRange(source.startIndex..., in: source)
            if targetDeclaration.firstMatch(in: source, range: range) != nil {
                declarations.append(path)
            }
        }
        XCTAssertEqual(declarations, ["Common/Package.swift"])
        let manifestRange = NSRange(manifestText.startIndex..., in: manifestText)
        XCTAssertNil(systemDeclaration.firstMatch(
            in: manifestText, range: manifestRange
        ))

        let commonManifest = try String(
            contentsOf: tree.repositoryRoot.appendingPathComponent(
                "Common/Package.swift"
            ),
            encoding: .utf8
        )
        for required in [
            #"path: "Sources/COpus""#,
            #""Upstream/opus-1.6.1/celt""#,
            #""Upstream/opus-1.6.1/silk""#,
            #""Upstream/opus-1.6.1/src""#,
            #"publicHeadersPath: "include""#,
            #".define("OPUS_BUILD")"#,
            #".define("USE_ALLOCA")"#,
            #".define("DISABLE_DEBUG_FLOAT")"#,
            #".define("PACKAGE_VERSION", to: "\"1.6.1\"")"#,
        ] {
            XCTAssertTrue(
                commonManifest.contains(required),
                "COpus compile contract changed: \(required)"
            )
        }

        for forbiddenPattern in [
            #"\.systemLibrary\s*\(\s*name\s*:\s*"COpus""#,
            #"\bpkgConfig\s*:\s*"opus""#,
            #"\.linkedLibrary\s*\(\s*"opus"(?:\s*,|\s*\))"#,
            #"\.brew\s*\(\s*\[\s*"opus"\s*\]\s*\)"#,
            #"\.apt\s*\(\s*\[\s*"libopus-dev"\s*\]\s*\)"#,
            #"["']-l(?:[^"']*)?opus["']"#,
        ] {
            let regex = try NSRegularExpression(pattern: forbiddenPattern)
            XCTAssertNil(regex.firstMatch(
                in: manifestText,
                range: NSRange(manifestText.startIndex..., in: manifestText)
            ), "ambient Opus coupling returned: \(forbiddenPattern)")
        }

        let provenance = try String(
            contentsOf: tree.repositoryRoot.appendingPathComponent(
                "Common/Sources/COpus/UPSTREAM.md"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(provenance.contains("Opus 1.6.1"))
        XCTAssertTrue(provenance.contains(
            "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
        ))
        let verifier = tree.repositoryRoot.appendingPathComponent(
            "Scripts/verify-opus-upstream.sh"
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: verifier.path))
        let verifierSource = try String(contentsOf: verifier, encoding: .utf8)
        XCTAssertTrue(verifierSource.contains(
            "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
        ))

        let license = try Data(contentsOf: tree.repositoryRoot.appendingPathComponent(
            "Common/Sources/COpus/Upstream/opus-1.6.1/COPYING"
        ))
        XCTAssertEqual(
            hex(Sha256.digest(license)),
            "01e1167d54a096d123cf6dfbbeb19587278845c6481d2d66d545669846079551"
        )
    }

    func testVendoredOpusSnapshotIsExact() throws {
        let tree = RepositorySourceTree()
        let cOpus = tree.repositoryRoot.appendingPathComponent(
            "Common/Sources/COpus"
        )
        let roots = [
            cOpus.appendingPathComponent("Upstream/opus-1.6.1"),
            cOpus.appendingPathComponent("include/opus"),
        ]
        var files: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else {
                return XCTFail("cannot enumerate \(root.path)")
            }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true { files.append(file) }
            }
        }
        files.sort { relative($0, to: cOpus) < relative($1, to: cOpus) }
        XCTAssertEqual(files.count, 240)

        let compiledSources = files.filter {
            $0.pathExtension == "c"
                && relative($0, to: cOpus).hasPrefix("Upstream/opus-1.6.1/")
        }
        XCTAssertEqual(compiledSources.count, 137)

        var digest = Sha256()
        for file in files {
            digest.update(Array(relative(file, to: cOpus).utf8))
            digest.update([0])
            digest.update(try Data(contentsOf: file))
            digest.update([0])
        }
        XCTAssertEqual(
            hex(digest.finalized()),
            "10e358f2ada650e159574c3811504a55af1c67c6a184524858c24481a6d5e4e6"
        )
    }

    func testNoHandwrittenCOpusModuleMapExists() throws {
        let tree = RepositorySourceTree()
        let sourceRoots = ["Client/Sources", "Common/Sources", "Host/Sources", "Wire/Sources"]
        var violations: [String] = []
        for sourceRoot in sourceRoots {
            let root = tree.repositoryRoot.appendingPathComponent(sourceRoot)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                return XCTFail("cannot enumerate \(sourceRoot)")
            }
            for case let file as URL in enumerator
            where file.lastPathComponent == "module.modulemap"
                || file.pathExtension == "modulemap" {
                let source = try String(contentsOf: file, encoding: .utf8)
                if source.contains("module COpus")
                    || source.range(
                        of: #"\blink\s+["']opus["']"#,
                        options: .regularExpression
                    ) != nil {
                    violations.append(tree.relativePath(for: file))
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "COpus regained a handwritten module map:\n"
                + violations.joined(separator: "\n")
        )
    }

    private func relative(_ file: URL, to root: URL) -> String {
        String(file.path.dropFirst(root.path.count + 1))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
