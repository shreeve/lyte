import Foundation
import XCTest

final class WireLayoutTests: XCTestCase {
    private struct TargetLayout {
        let path: String
        let domains: Set<String>
        let nestedDomains: [String: Set<String>]
    }

    private static let crypto: [String: Set<String>] = [
        "Crypto": ["Noise", "Pairing", "Retry"],
    ]

    /// Each Swift target groups its sources under the canonical Wire
    /// domains (and Crypto's three subdomains); which files sit at a
    /// target's root is the code's business, not this test's.
    func testEverySwiftTargetUsesTheWireDomainGrammar() throws {
        let layouts = [
            TargetLayout(
                path: "Sources/LyteWire",
                domains: [
                    "Arq", "Audio", "Bulk", "Capabilities", "Clipboard",
                    "Control", "Crypto", "Fec", "Session", "Telemetry",
                    "Video",
                ],
                nestedDomains: Self.crypto
            ),
            TargetLayout(
                path: "Sources/LyteWireTestKit",
                domains: [
                    "Arq", "Bulk", "Capabilities", "Clipboard", "Control",
                    "Crypto", "Fec", "Session", "Simulation", "Telemetry",
                    "Video",
                ],
                nestedDomains: Self.crypto
            ),
            TargetLayout(
                path: "Sources/LyteWireVectorGen",
                domains: [
                    "Arq", "Bulk", "Capabilities", "Clipboard", "Control",
                    "Crypto", "Fec", "Session", "Telemetry", "Video",
                ],
                nestedDomains: Self.crypto
            ),
            TargetLayout(
                path: "Sources/LyteWireVectorGenTool",
                domains: [],
                nestedDomains: [:]
            ),
            TargetLayout(
                path: "Tests/LyteWireTests",
                domains: [
                    "Arq", "Audio", "Bulk", "Capabilities", "Clipboard",
                    "Control", "Crypto", "Fec", "Session", "Simulation",
                    "Telemetry", "Video",
                ],
                nestedDomains: Self.crypto
            ),
        ]

        for layout in layouts {
            try verify(layout)
        }
    }

    private func verify(_ layout: TargetLayout) throws {
        let root = URL(fileURLWithPath: WireTestPaths.packageRoot)
            .appendingPathComponent(layout.path)

        XCTAssertEqual(
            try childDirectories(of: root),
            layout.domains,
            "\(layout.path) must use only the canonical Wire domains"
        )

        for domain in layout.domains.sorted() {
            let domainURL = root.appendingPathComponent(domain)
            if let nested = layout.nestedDomains[domain] {
                XCTAssertEqual(
                    try childDirectories(of: domainURL),
                    nested,
                    "\(layout.path)/\(domain) has a non-canonical subdomain"
                )
                XCTAssertEqual(
                    try swiftFiles(at: domainURL),
                    [],
                    "\(layout.path)/\(domain) must contain only named subdomains"
                )
                for leaf in nested.sorted() {
                    try verifyLeaf(
                        domainURL.appendingPathComponent(leaf),
                        relativePath: "\(layout.path)/\(domain)/\(leaf)"
                    )
                }
            } else {
                try verifyLeaf(
                    domainURL,
                    relativePath: "\(layout.path)/\(domain)"
                )
            }
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
