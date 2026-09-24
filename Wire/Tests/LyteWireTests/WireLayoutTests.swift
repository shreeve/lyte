import Foundation
import XCTest
import LyteWireTestKit

// The Wire domain grammar, stated as a rule rather than a directory
// inventory: LyteWire's own domains are the vocabulary, and every other
// Swift target files its sources under those domains (tests and test
// equipment may add `Simulation`). A domain is a leaf of Swift sources,
// except Crypto, whose subdomains are LyteWire's Crypto subdomains.

final class WireLayoutTests: XCTestCase {

    private let packageRoot = URL(fileURLWithPath: WireVectors.directory)
        .deletingLastPathComponent()

    func testEverySwiftTargetUsesLyteWiresDomainGrammar() throws {
        let wire = packageRoot.appendingPathComponent("Sources/LyteWire")
        let domains = try childDirectories(of: wire)
        let cryptoDomains = try childDirectories(
            of: wire.appendingPathComponent("Crypto")
        )
        XCTAssertFalse(domains.isEmpty)
        try verify("Sources/LyteWire", allowed: domains, crypto: cryptoDomains)
        for path in [
            "Sources/LyteWireTestKit", "Sources/LyteWireVectorGen",
            "Tests/LyteWireTests",
        ] {
            try verify(path, allowed: domains.union(["Simulation"]),
                       crypto: cryptoDomains)
        }
        XCTAssertEqual(try childDirectories(
            of: packageRoot.appendingPathComponent("Sources/LyteWireVectorGenTool")
        ), [], "the CLI stays flat")
    }

    private func verify(
        _ path: String, allowed: Set<String>, crypto: Set<String>
    ) throws {
        let root = packageRoot.appendingPathComponent(path)
        let domains = try childDirectories(of: root)
        XCTAssertTrue(domains.isSubset(of: allowed),
                      "\(path): \(domains.subtracting(allowed).sorted()) are not Wire domains")
        for domain in domains {
            let url = root.appendingPathComponent(domain)
            guard domain == "Crypto" else {
                try verifyLeaf(url, "\(path)/\(domain)")
                continue
            }
            let nested = try childDirectories(of: url)
            XCTAssertTrue(nested.isSubset(of: crypto),
                          "\(path)/Crypto: \(nested.subtracting(crypto).sorted()) are not Crypto subdomains")
            XCTAssertEqual(try swiftFiles(at: url), [],
                           "\(path)/Crypto holds only subdomains")
            for leaf in nested {
                try verifyLeaf(url.appendingPathComponent(leaf),
                               "\(path)/Crypto/\(leaf)")
            }
        }
    }

    private func verifyLeaf(_ url: URL, _ path: String) throws {
        XCTAssertEqual(try childDirectories(of: url), [], "\(path) is a leaf")
        XCTAssertFalse(try swiftFiles(at: url).isEmpty, "\(path) holds Swift source")
    }

    private func childDirectories(of url: URL) throws -> Set<String> {
        try Set(FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ).compactMap { child in
            try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                ? child.lastPathComponent : nil
        })
    }

    private func swiftFiles(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.map(\.lastPathComponent)
    }
}
