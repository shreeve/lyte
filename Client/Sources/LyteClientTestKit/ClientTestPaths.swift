import Foundation
import LyteTestKit

public enum ClientTestPaths {
    public static let repositoryRoot = RepositorySourceTree().repositoryRoot.path

    public static let videoCorpus =
        repositoryRoot + "/Wire/Vectors/video-corpus-v1"

    /// The corpus's first `count` access units, in stream order.
    public static func videoCorpusFrames(_ count: Int = .max) throws -> [[UInt8]] {
        try FileManager.default.contentsOfDirectory(atPath: videoCorpus)
            .filter { $0.hasPrefix("frame-0") && $0.hasSuffix(".annexb") }
            .sorted()
            .prefix(count)
            .map {
                [UInt8](try Data(contentsOf: URL(
                    fileURLWithPath: videoCorpus + "/" + $0)))
            }
    }
}
