// LyteIO owns operating-system adapters shared by both ends. Adapters expose
// mechanism only: timing policy remains in sans-IO cores with injected stamps.

import Dispatch
import LyteCore

/// The process-wide monotonic clock used by client and host shells.
///
/// Values share `DispatchTime.uptimeNanoseconds`' domain on every supported
/// platform. They are suitable for elapsed-time math and wire timestamps, but
/// have no relationship to wall-clock time.
public enum SystemMonotonicClock: Sendable {
    public static var nowNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public static var nowMicroseconds: UInt64 {
        nowNanoseconds / 1_000
    }

    public static var nowSeconds: Double {
        Double(nowNanoseconds) / 1_000_000_000
    }
}
