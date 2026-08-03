import Foundation
import XCTest

final class WireLayoutTests: XCTestCase {
    private struct TargetLayout {
        let path: String
        let domains: Set<String>
        let mediaDomains: Set<String>
    }

    func testEverySwiftTargetUsesTheWireDomainGrammar() throws {
        let layouts = [
            TargetLayout(
                path: "Sources/LyteWire",
                domains: ["Base", "Bulk", "Clipboard", "Control", "Crypto"],
                mediaDomains: ["Audio", "FEC", "Video"]
            ),
            TargetLayout(
                path: "Sources/LyteWireTestKit",
                domains: [
                    "Base", "Bulk", "Clipboard", "Control", "Crypto",
                    "Simulation",
                ],
                mediaDomains: ["FEC", "Video"]
            ),
            TargetLayout(
                path: "Sources/lyte-wire-vectorgen",
                domains: [
                    "Base", "Bulk", "Clipboard", "Command", "Control",
                    "Crypto",
                ],
                mediaDomains: ["FEC", "Video"]
            ),
            TargetLayout(
                path: "Tests/LyteWireTests",
                domains: [
                    "Base", "Bulk", "Clipboard", "Control", "Crypto",
                    "Simulation", "Support",
                ],
                mediaDomains: ["Audio", "FEC", "Video"]
            ),
        ]

        for layout in layouts {
            try verify(layout)
        }
    }

    private func verify(_ layout: TargetLayout) throws {
        let root = URL(fileURLWithPath: WireTestPaths.packageRoot)
            .appendingPathComponent(layout.path)
        var expectedRootDomains = layout.domains
        if !layout.mediaDomains.isEmpty {
            expectedRootDomains.insert("Media")
        }

        XCTAssertEqual(
            try childDirectories(of: root),
            expectedRootDomains,
            "\(layout.path) must use only the canonical Wire domains"
        )
        XCTAssertEqual(
            try swiftFiles(at: root),
            [],
            "\(layout.path) must not keep Swift files at its target root"
        )

        for domain in layout.domains.sorted() {
            try verifyLeaf(
                root.appendingPathComponent(domain),
                relativePath: "\(layout.path)/\(domain)"
            )
        }

        guard !layout.mediaDomains.isEmpty else { return }
        let media = root.appendingPathComponent("Media")
        XCTAssertEqual(
            try childDirectories(of: media),
            layout.mediaDomains,
            "\(layout.path)/Media must use only canonical media domains"
        )
        XCTAssertEqual(
            try swiftFiles(at: media),
            [],
            "\(layout.path)/Media must not keep Swift files at its root"
        )
        for domain in layout.mediaDomains.sorted() {
            try verifyLeaf(
                media.appendingPathComponent(domain),
                relativePath: "\(layout.path)/Media/\(domain)"
            )
        }
    }

    private func verifyLeaf(_ url: URL, relativePath: String) throws {
        XCTAssertEqual(
            try childDirectories(of: url),
            [],
            "\(relativePath) must remain a leaf domain"
        )
        XCTAssertFalse(
            try swiftFiles(at: url).isEmpty,
            "\(relativePath) must contain Swift source"
        )
    }

    private func childDirectories(of url: URL) throws -> Set<String> {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        return try Set(
            FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys)
            ).compactMap { child in
                let values = try child.resourceValues(forKeys: keys)
                return values.isDirectory == true
                    ? child.lastPathComponent
                    : nil
            }
        )
    }

    private func swiftFiles(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
            .map(\.lastPathComponent)
            .sorted()
    }
}
