import Foundation
import LyteCore
import LyteTestKit
import XCTest

/// libopus enters the repository once: the pinned, vendored COpus source
/// leaf that Common declares, never a system library or ambient linkage.
final class COpusDeclarationRatchetTests: XCTestCase {
    private let tree = RepositorySourceTree()

    /// Every package manifest in the checkout.
    private func manifests() throws -> [(path: String, source: String)] {
        let root = tree.repositoryRoot
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .sorted()
            .compactMap { package in
                let path = "\(package)/Package.swift"
                let url = root.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path)
                else { return nil }
                return (path, try String(contentsOf: url, encoding: .utf8))
            }
    }

    func testCOpusIsOnePinnedSourceLeafWithoutAmbientLinkage() throws {
        let manifests = try manifests()
        XCTAssertGreaterThanOrEqual(manifests.count, 6, "every package is scanned")
        let targetDeclaration = try NSRegularExpression(
            pattern: #"\.target\s*\(\s*name:\s*"COpus""#)
        XCTAssertEqual(
            manifests.filter { Self.matches(targetDeclaration, $0.source) }
                .map(\.path),
            ["Common/Package.swift"])

        for forbiddenPattern in [
            #"\.systemLibrary\s*\(\s*name\s*:\s*"COpus""#,
            #"\bpkgConfig\s*:\s*"opus""#,
            #"\.linkedLibrary\s*\(\s*"opus"(?:\s*,|\s*\))"#,
            #"\.brew\s*\(\s*\[\s*"opus"\s*\]\s*\)"#,
            #"\.apt\s*\(\s*\[\s*"libopus-dev"\s*\]\s*\)"#,
            #"["']-l(?:[^"']*)?opus["']"#,
        ] {
            let regex = try NSRegularExpression(pattern: forbiddenPattern)
            for manifest in manifests where Self.matches(regex, manifest.source) {
                XCTFail("ambient Opus coupling in \(manifest.path): \(forbiddenPattern)")
            }
        }
    }

    /// The vendored tree is exactly the pinned upstream snapshot.
    func testVendoredOpusSnapshotIsExact() throws {
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
            Hex.string(digest.finalized()),
            "10e358f2ada650e159574c3811504a55af1c67c6a184524858c24481a6d5e4e6"
        )
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func relative(_ file: URL, to root: URL) -> String {
        RepositorySourceTree.relativePath(of: file, below: root)
    }
}
