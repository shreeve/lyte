import Foundation
import XCTest

final class WireLayoutTests: XCTestCase {
    private struct TargetLayout {
        let path: String
        let rootFiles: Set<String>
        let domains: Set<String>
        let nestedDomains: [String: Set<String>]
    }

    func testEverySwiftTargetUsesTheWireDomainGrammar() throws {
        let layouts = [
            TargetLayout(
                path: "Sources/LyteWire",
                rootFiles: [
                    "ChannelId.swift", "Envelope.swift", "Vocabulary.swift",
                    "WireBudget.swift", "WireBytes.swift", "WireError.swift",
                    "WireExtension.swift", "WireVersion.swift",
                ],
                domains: [
                    "Arq", "Audio", "Bulk", "Capabilities", "Clipboard",
                    "Control", "Crypto", "Fec", "Session", "Telemetry",
                    "Video",
                ],
                nestedDomains: ["Crypto": ["Noise", "Pairing", "Retry"]]
            ),
            TargetLayout(
                path: "Sources/LyteWireTestKit",
                rootFiles: ["EnvelopeVectors.swift", "SplitMix64.swift"],
                domains: [
                    "Arq", "Bulk", "Capabilities", "Clipboard", "Control",
                    "Crypto", "Fec", "Session", "Simulation", "Telemetry",
                    "Video",
                ],
                nestedDomains: ["Crypto": ["Noise", "Pairing", "Retry"]]
            ),
            TargetLayout(
                path: "Sources/LyteWireVectorGen",
                rootFiles: ["EnvelopeVectorGen.swift", "main.swift"],
                domains: [
                    "Arq", "Bulk", "Capabilities", "Clipboard", "Control",
                    "Crypto", "Fec", "Session", "Telemetry", "Video",
                ],
                nestedDomains: ["Crypto": ["Noise", "Pairing", "Retry"]]
            ),
            TargetLayout(
                path: "Tests/LyteWireTests",
                rootFiles: [
                    "EnvelopeTests.swift", "NoFoundationLintTests.swift",
                    "RoundTripPropertyTests.swift", "VectorFileTests.swift",
                    "VocabularyTests.swift", "WireLayoutTests.swift",
                    "WireTestPaths.swift",
                ],
                domains: [
                    "Arq", "Audio", "Bulk", "Capabilities", "Clipboard",
                    "Control", "Crypto", "Fec", "Session", "Simulation",
                    "Telemetry", "Video",
                ],
                nestedDomains: ["Crypto": ["Noise", "Pairing", "Retry"]]
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
        XCTAssertEqual(
            Set(try swiftFiles(at: root)),
            layout.rootFiles,
            "\(layout.path) must keep only named module-spine files at root"
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
