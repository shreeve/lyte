// Repository-aware test equipment shared by Common's cross-tree ratchets.
// It deliberately fails closed: a missing source root, an unreadable tree,
// or a root without Swift production files is a test failure, never a skip.

import Foundation

public enum RepositorySourceTreeError: Error, CustomStringConvertible {
    case missingDirectory(String)
    case unreadableDirectory(String)
    case emptySwiftDirectory(String)

    public var description: String {
        switch self {
        case .missingDirectory(let path):
            return "required production source directory is missing: \(path)"
        case .unreadableDirectory(let path):
            return "required production source directory is unreadable: \(path)"
        case .emptySwiftDirectory(let path):
            return "required production source directory contains no Swift files: \(path)"
        }
    }
}

public struct RepositorySourceTree {
    public let repositoryRoot: URL

    public init() {
        if let override = ProcessInfo.processInfo.environment[
            "LYTE_REPOSITORY_ROOT"
        ] {
            repositoryRoot = URL(fileURLWithPath: override).standardizedFileURL
            return
        }
        let commonRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LyteTestKit
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Common
        repositoryRoot = commonRoot.deletingLastPathComponent()
    }

    public init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot.standardizedFileURL
    }

    public var productionSourceRoots: [URL] {
        [
            repositoryRoot.appendingPathComponent("Common/Sources/LyteCore"),
            repositoryRoot.appendingPathComponent("Common/Sources/LyteIO"),
            repositoryRoot.appendingPathComponent("Client/Sources"),
            repositoryRoot.appendingPathComponent("Host/Sources"),
            repositoryRoot.appendingPathComponent("Wire/Sources"),
        ]
    }

    public func productionSwiftFiles() throws -> [URL] {
        let fileManager = FileManager.default
        var allFiles: [URL] = []

        for root in productionSourceRoots {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw RepositorySourceTreeError.missingDirectory(
                    relativePath(for: root)
                )
            }
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw RepositorySourceTreeError.unreadableDirectory(
                    relativePath(for: root)
                )
            }

            var rootFiles: [URL] = []
            for case let file as URL in enumerator
            where file.pathExtension == "swift" {
                rootFiles.append(file.standardizedFileURL)
            }
            if enumerationError != nil {
                throw RepositorySourceTreeError.unreadableDirectory(
                    relativePath(for: root)
                )
            }
            guard !rootFiles.isEmpty else {
                throw RepositorySourceTreeError.emptySwiftDirectory(
                    relativePath(for: root)
                )
            }
            allFiles.append(contentsOf: rootFiles)
        }

        return allFiles.sorted { $0.path < $1.path }
    }

    public func violations(
        containing tokens: [String],
        excludingRelativePaths: Set<String> = [],
        excludingPathPrefixes: [String] = []
    ) throws -> [String] {
        var violations: [String] = []

        for file in try productionSwiftFiles() {
            let relativePath = relativePath(for: file)
            if excludingRelativePaths.contains(relativePath)
                || excludingPathPrefixes.contains(where: relativePath.hasPrefix)
            {
                continue
            }

            let source = try String(contentsOf: file, encoding: .utf8)
            for token in tokens where source.contains(token) {
                violations.append("\(relativePath): \(token)")
            }
        }

        return violations.sorted()
    }

    public func relativePath(for file: URL) -> String {
        let rootPath = repositoryRoot.standardizedFileURL.path + "/"
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            return filePath
        }
        return String(filePath.dropFirst(rootPath.count))
    }
}
