import LyteTestKit

enum ClientTestPaths {
    static let repositoryRoot = RepositorySourceTree().repositoryRoot.path

    static let videoCorpus =
        repositoryRoot + "/Wire/Vectors/video-corpus-v1"
}
