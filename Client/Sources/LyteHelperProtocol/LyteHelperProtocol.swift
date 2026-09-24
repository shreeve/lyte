import Foundation

/// XPC contract between Lyte.app and the privileged helper daemon.
/// The helper holds awdl0 down while any stream is active (AWDL's channel
/// hopping stalls the Wi-Fi radio in bursts) and restores it when streams
/// end, the client vanishes, or the daemon is stopped.
@objc public protocol LyteHelperCommands {
    /// A stream started — hold AWDL down (refcounted across streams).
    func streamBegan()
    /// A stream ended — release one hold; last one out restores AWDL.
    func streamEnded()
    /// Liveness/version probe: `version` plus this build's code hash
    /// (LyteHelperSecurity's HelperCodeIdentity).
    func version(reply: @escaping @Sendable (String) -> Void)
}

public enum LyteHelper {
    public static let machServiceName = "dev.shreeve.lyte.helper"
    public static let plistName = "dev.shreeve.lyte.helper.plist"
    /// The XPC contract's version; bump it when the calls change.
    public static let version = "2"
}
