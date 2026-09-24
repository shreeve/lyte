// The shape every committed `Wire/Vectors/*.json` file shares: a format
// name, a format version, the wire major it pins, and named vectors.
// Loading, locating, and the identity checks live here once instead of
// in every loader and every vector-file test.

import Foundation
import LyteWire

public protocol FrozenVectorFile: Codable, Sendable {
    /// The `format` string the committed file must carry.
    static var expectedFormat: String { get }
    /// The file's name under `Wire/Vectors/`.
    static var fileName: String { get }
    var format: String { get }
    var formatVersion: Int { get }
    var wireVersion: Int { get }
    /// Each group of named vectors in the file. Every group must be
    /// non-empty and every name unique across the whole file.
    var vectorNameGroups: [[String]] { get }
}

/// Where the committed vector files live, found from this source file so
/// every package that builds LyteWireTestKit (Wire, Host, Client) reads
/// the same bytes.
public enum WireVectors {
    public static let directory: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LyteWireTestKit
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // Wire
        .appendingPathComponent("Vectors").path

    public static func path(_ fileName: String) -> String {
        directory + "/" + fileName
    }
}

extension FrozenVectorFile {
    public static func load(from path: String) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// The committed file, decoded.
    public static func loadCommitted() throws -> Self {
        try load(from: WireVectors.path(fileName))
    }

    /// Everything wrong with the file's identity; empty when it is the
    /// frozen v1 contract for this wire major.
    public var identityProblems: [String] {
        var problems: [String] = []
        if format != Self.expectedFormat {
            problems.append("format \(format), expected \(Self.expectedFormat)")
        }
        if formatVersion != 1 {
            problems.append("formatVersion \(formatVersion), expected 1")
        }
        if wireVersion != Int(WireVersion.major) {
            problems.append("wireVersion \(wireVersion), expected \(WireVersion.major)")
        }
        for (index, group) in vectorNameGroups.enumerated() where group.isEmpty {
            problems.append("vector group \(index) is empty")
        }
        let names = vectorNameGroups.flatMap { $0 }
        let duplicates = Dictionary(grouping: names, by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        if !duplicates.isEmpty {
            problems.append("duplicate vector names: \(duplicates)")
        }
        return problems
    }

    /// The canonical JSON the authoring tool writes: pretty-printed,
    /// sorted keys, trailing newline.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

/// The name vector files give a codec error: its Swift case name, without
/// any associated values.
public func vectorErrorName(_ error: some Error) -> String {
    String(String(describing: error).prefix { $0 != "(" })
}
