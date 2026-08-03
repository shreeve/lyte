import LyteTestKit

public enum ClientTestPaths {
    public static let repositoryRoot = RepositorySourceTree().repositoryRoot.path

    public static let videoCorpus =
        repositoryRoot + "/Wire/Vectors/video-corpus-v1"
}
