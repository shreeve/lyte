import Foundation

enum WireTestPaths {
    static let packageRoot: String = {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while candidate.path != "/" {
            let manifest = candidate.appendingPathComponent("Package.swift")
            let vectors = candidate.appendingPathComponent("Vectors")
            var vectorsIsDirectory = ObjCBool(false)

            if fileManager.fileExists(atPath: manifest.path),
                fileManager.fileExists(
                    atPath: vectors.path,
                    isDirectory: &vectorsIsDirectory
                ),
                vectorsIsDirectory.boolValue
            {
                return candidate.path
            }

            candidate.deleteLastPathComponent()
        }

        fatalError("could not locate Wire package root from \(#filePath)")
    }()
}
