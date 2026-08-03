import Foundation

enum WireTestPaths {
    static let packageRoot: String = {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while candidate.path != "/" {
            let manifest = candidate.appendingPathComponent("Package.swift")
            let vectors = candidate.appendingPathComponent("Vectors")
            let vectorReadme = vectors.appendingPathComponent("README.md")
            let wireSources = candidate
                .appendingPathComponent("Sources")
                .appendingPathComponent("LyteWire")
            var vectorsIsDirectory = ObjCBool(false)
            var wireSourcesIsDirectory = ObjCBool(false)

            if fileManager.fileExists(atPath: manifest.path),
                fileManager.fileExists(atPath: vectorReadme.path),
                fileManager.fileExists(
                    atPath: vectors.path,
                    isDirectory: &vectorsIsDirectory
                ),
                vectorsIsDirectory.boolValue,
                fileManager.fileExists(
                    atPath: wireSources.path,
                    isDirectory: &wireSourcesIsDirectory
                ),
                wireSourcesIsDirectory.boolValue
            {
                return candidate.path
            }

            candidate.deleteLastPathComponent()
        }

        fatalError("could not locate Wire package root from \(#filePath)")
    }()
}
