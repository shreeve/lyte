import Foundation
import LyteTestKit
import XCTest

final class SystemTestsLayoutTests: XCTestCase {
    private let sourceTree = RepositorySourceTree()

    private enum ProductRole {
        case client
        case host
    }

    func testCrossEndImportsLiveAtTheSystemBoundary() throws {
        XCTAssertEqual(
            try importers(
                of: .host,
                below: "SystemTests/Tests"
            ),
            [
                "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift",
                "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift",
            ]
        )
        XCTAssertEqual(
            try importers(
                of: .client,
                below: "SystemTests/Tests"
            ),
            [
                "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift",
                "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift",
            ]
        )
        XCTAssertEqual(
            try importers(
                of: .host,
                below: "Client/Tests"
            ),
            []
        )
        XCTAssertEqual(
            try importers(
                of: .client,
                below: "Host/Tests"
            ),
            []
        )

        let pairing = try source(
            at: "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift"
        )
        let pairingImports = importedModules(from: pairing)
        XCTAssertTrue(pairingImports.contains("HostWire"))
        XCTAssertTrue(pairingImports.contains("LyteTransport"))

        let nack = try source(
            at: "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift"
        )
        let nackImports = importedModules(from: nack)
        XCTAssertTrue(nackImports.contains("HostWire"))
        XCTAssertTrue(nackImports.contains("LyteTransport"))
    }

    func testAttributedAndQualifiedImportsCannotEvadeTheBoundary() {
        let source = [
            "@testable " + "import HostWire",
            "package " + "import HostWire",
            "@preconcurrency public " + "import LyteClientShell",
            "import " + "struct HostCore.Pacer",
            "import " + "let LyteClientShell.defaultValue",
        ].joined(separator: "\n")
        XCTAssertEqual(
            importedModules(from: source),
            ["HostWire", "HostWire", "LyteClientShell", "HostCore", "LyteClientShell"]
        )
    }

    func testSystemPackageHasExactlyOneCanonicalTestBoundary() throws {
        let root = sourceTree.repositoryRoot
        let systemRoot = root.appendingPathComponent("SystemTests")

        XCTAssertEqual(
            try childNames(of: systemRoot),
            ["Package.resolved", "Package.swift", "Tests"]
        )
        XCTAssertEqual(
            try directoryPaths(below: systemRoot),
            ["Tests", "Tests/LyteClientHostTests"],
            "new SystemTests directories need an explicit architectural home"
        )

        for package in ["Client", "Common", "Host", "Wire"] {
            let manifest = try source(at: "\(package)/Package.swift")
            XCTAssertFalse(
                manifest.contains("../SystemTests"),
                "\(package) must not depend on the system-test package"
            )
            XCTAssertFalse(
                manifest.contains("LyteSystemTestKit"),
                "LyteSystemTestKit does not exist until reusable equipment earns it"
            )
        }

        let clientManifest = try source(at: "Client/Package.swift")
        XCTAssertFalse(
            clientManifest.contains("../Host"),
            "Client must not depend on the Host package"
        )
        XCTAssertFalse(
            clientManifest.contains("package: \"Host\""),
            "Client targets must not import Host products"
        )
        XCTAssertEqual(
            clientManifest.components(separatedBy: "\"LyteClientTestKit\"").count - 1,
            4,
            "the TestKit product/target may be consumed only by LyteTransportTests"
        )
        XCTAssertEqual(
            try importers(
                ofModule: "LyteClientTestKit",
                below: "Client/Sources"
            ),
            [],
            "shipping Client sources must not import test equipment"
        )
    }

    private func importers(
        of role: ProductRole,
        below relativeRoot: String
    ) throws -> [String] {
        try importers(below: relativeRoot) {
            belongsToRole($0, role: role)
        }
    }

    private func importers(
        ofModule module: String,
        below relativeRoot: String
    ) throws -> [String] {
        try importers(below: relativeRoot) { $0 == module }
    }

    private func importers(
        below relativeRoot: String,
        matching predicate: (String) -> Bool
    ) throws -> [String] {
        let root = sourceTree.repositoryRoot.appendingPathComponent(relativeRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(relativeRoot)")
            return []
        }

        var result: [String] = []
        for case let file as URL in enumerator
        where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if importedModules(from: source).contains(where: predicate) {
                result.append(sourceTree.relativePath(for: file))
            }
        }
        return result.sorted()
    }

    private func importedModules(from source: String) -> [String] {
        let importAccess: Set<String> = [
            "fileprivate", "internal", "package", "private", "public",
        ]
        let importKinds: Set<String> = [
            "class", "enum", "func", "let", "macro", "protocol", "struct",
            "typealias", "var",
        ]

        return source.split(separator: "\n").compactMap { line in
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let importIndex = tokens.firstIndex(of: "import"),
                  tokens[..<importIndex].allSatisfy({
                      $0.hasPrefix("@") || importAccess.contains($0)
                  })
            else {
                return nil
            }

            var moduleIndex = importIndex + 1
            guard moduleIndex < tokens.endIndex else { return nil }
            if importKinds.contains(tokens[moduleIndex]) {
                moduleIndex += 1
            }
            guard moduleIndex < tokens.endIndex else { return nil }
            return String(tokens[moduleIndex].split(separator: ".", maxSplits: 1)[0])
        }
    }

    private func belongsToRole(_ module: String, role: ProductRole) -> Bool {
        switch role {
        case .host:
            return ["HostCore", "HostEye", "HostWire"].contains(module)
                || module.hasPrefix("LyteHost")
        case .client:
            return ["LyteCorpus", "LyteHelperProtocol", "LyteTransport", "LyteUI"]
                .contains(module)
                || module.hasPrefix("LyteClient")
        }
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: sourceTree.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func childNames(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()
    }

    private func directoryPaths(below root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("cannot enumerate \(root.path)")
            return []
        }

        var result: [String] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                let relative = item.path.dropFirst(root.path.count + 1)
                result.append(String(relative))
            }
        }
        return result.sorted()
    }
}
