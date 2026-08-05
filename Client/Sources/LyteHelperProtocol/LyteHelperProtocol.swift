import Foundation

/// XPC contract between Lyte.app and the privileged helper daemon.
/// The helper holds awdl0 down while any stream is active (AWDL radio
/// time-slicing costs ~50 ms of audio-buffer pressure — calibrated
/// 2026-07-15) and restores it when streams end or the client vanishes.
@objc public protocol LyteHelperCommands {
    /// A stream started — hold AWDL down (refcounted across streams).
    func streamBegan()
    /// A stream ended — release one hold; last one out restores AWDL.
    func streamEnded()
    /// Liveness/version probe.
    func version(reply: @escaping @Sendable (String) -> Void)
}

public enum LyteHelper {
    public static let machServiceName = "dev.shreeve.lyte.helper"
    public static let plistName = "dev.shreeve.lyte.helper.plist"
    public static let version = "2"
}
