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

/// Enumerations, file contents and token streams of the checked-out tree,
/// read once per test process and shared by every ratchet. Scratch trees
/// built by tests are never cached.
private final class SourceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: [URL]] = [:]
    private var sources: [String: String] = [:]
    private var tokens: [String: [String]] = [:]

    func files(below path: String, _ load: () throws -> [URL]) rethrows -> [URL] {
        if let cached = lock.withLock({ files[path] }) { return cached }
        let loaded = try load()
        lock.withLock { files[path] = loaded }
        return loaded
    }

    func source(at path: String, _ load: () throws -> String) rethrows -> String {
        if let cached = lock.withLock({ sources[path] }) { return cached }
        let loaded = try load()
        lock.withLock { sources[path] = loaded }
        return loaded
    }

    func tokens(at path: String, _ load: () -> [String]) -> [String] {
        if let cached = lock.withLock({ tokens[path] }) { return cached }
        let loaded = load()
        lock.withLock { tokens[path] = loaded }
        return loaded
    }
}

public struct RepositorySourceTree {
    public let repositoryRoot: URL
    private let cache: SourceCache?

    private static let checkedOutRoot: URL = {
        if let override = ProcessInfo.processInfo.environment[
            "LYTE_REPOSITORY_ROOT"
        ] {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        let commonRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LyteTestKit
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Common
        return commonRoot.deletingLastPathComponent().standardizedFileURL
    }()

    private static let sharedCache = SourceCache()

    public init() {
        repositoryRoot = Self.checkedOutRoot
        cache = Self.sharedCache
    }

    public init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot.standardizedFileURL
        cache = self.repositoryRoot == Self.checkedOutRoot
            ? Self.sharedCache : nil
    }

    public var productionSourceRoots: [URL] {
        [
            repositoryRoot.appendingPathComponent("Common/Sources/LyteCore"),
            repositoryRoot.appendingPathComponent("Common/Sources/LyteIO"),
            repositoryRoot.appendingPathComponent("Client/Sources"),
            repositoryRoot.appendingPathComponent("Host/Sources"),
            repositoryRoot.appendingPathComponent("Wire/Sources"),
            repositoryRoot.appendingPathComponent("Browser/Sources"),
        ]
    }

    /// The UTF-8 contents of `file`, read once per process for the
    /// checked-out tree.
    public func source(of file: URL) throws -> String {
        let path = file.standardizedFileURL.path
        let load = { try String(contentsOf: file, encoding: .utf8) }
        guard let cache else { return try load() }
        return try cache.source(at: path, load)
    }

    /// `SwiftSourceScanner.tokens` of `file` (comments and strings removed),
    /// computed once per process for the checked-out tree.
    public func tokens(of file: URL) throws -> [String] {
        let source = try source(of: file)
        guard let cache else { return SwiftSourceScanner.tokens(in: source) }
        return cache.tokens(at: file.standardizedFileURL.path) {
            SwiftSourceScanner.tokens(in: source)
        }
    }

    public func productionSwiftFiles() throws -> [URL] {
        var allFiles: [URL] = []

        for root in productionSourceRoots {
            var rootFiles: [URL] = []
            for file in try swiftFiles(below: relativePath(for: root)) {
                // Umbrella roots hold several targets; TestKit targets are
                // test equipment, but a nested production directory merely
                // named *TestKit stays visible (pinned in tests).
                let relative = file.path.dropFirst(root.path.count + 1)
                if root.lastPathComponent == "Sources",
                   relative.split(separator: "/").first?.hasSuffix("TestKit")
                       == true {
                    continue
                }
                rootFiles.append(file)
            }
            allFiles.append(contentsOf: rootFiles)
        }

        return allFiles.sorted { $0.path < $1.path }
    }

    /// Enumerates one required Swift source boundary and fails closed when
    /// the boundary is missing, unreadable, or empty.
    public func swiftFiles(below relativeRoot: String) throws -> [URL] {
        let root = repositoryRoot.appendingPathComponent(relativeRoot)
        guard let cache else { return try enumerateSwiftFiles(root, relativeRoot) }
        return try cache.files(below: root.standardizedFileURL.path) {
            try enumerateSwiftFiles(root, relativeRoot)
        }
    }

    private func enumerateSwiftFiles(
        _ root: URL, _ relativeRoot: String
    ) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw RepositorySourceTreeError.missingDirectory(relativeRoot)
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
            throw RepositorySourceTreeError.unreadableDirectory(relativeRoot)
        }

        var files: [URL] = []
        for case let file as URL in enumerator
        where file.pathExtension == "swift" {
            files.append(file.standardizedFileURL)
        }
        if enumerationError != nil {
            throw RepositorySourceTreeError.unreadableDirectory(relativeRoot)
        }
        guard !files.isEmpty else {
            throw RepositorySourceTreeError.emptySwiftDirectory(relativeRoot)
        }
        return files.sorted { $0.path < $1.path }
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
