// AdvertisementSchedule: when the host's mDNS record must be filed with
// the Avahi daemon again, and when to try. The record lives as long as
// the daemon's entry group, and the listening service now outlives many
// of those: avahi-daemon restarts (a package upgrade, a network
// reconfiguration), and a name collision on the LAN withdraws the group.
// Sans-IO: the shell reports what the daemon said and asks what is due.

/// Avahi's EntryGroup states (avahi-common/defs.h), and what each means
/// for a record the host filed.
public enum AvahiEntryGroupState: Int32, Sendable {
    case uncommitted = 0
    case registering = 1
    case established = 2
    case collision = 3
    case failure = 4

    public enum Reaction: Equatable, Sendable {
        /// The record stands (or is on its way).
        case keep
        /// The group was reset (the daemon's own host-name collision
        /// clears every group) or failed: file it again.
        case refile
        /// Another host holds the service name: file it again under the
        /// daemon's alternative name.
        case refileRenamed
    }

    public var reaction: Reaction {
        switch self {
        case .registering, .established: .keep
        case .uncommitted, .failure: .refile
        case .collision: .refileRenamed
        }
    }
}

public struct AdvertisementSchedule: Sendable {
    public static let firstRetryNS: UInt64 = 1_000_000_000
    public static let maxRetryNS: UInt64 = 60_000_000_000

    /// When the next filing is due; nil while a filed record stands.
    public private(set) var dueAtNS: UInt64?
    private var delayNS = firstRetryNS

    /// Due at once: nothing is filed yet.
    public init() { dueAtNS = 0 }

    public func isDue(nowNS: UInt64) -> Bool {
        dueAtNS.map { nowNS >= $0 } ?? false
    }

    /// The daemon accepted the record (it may still be registering).
    public mutating func filed() {
        dueAtNS = nil
    }

    /// The daemon reports the record on the air: the back-off resets.
    public mutating func established() {
        delayNS = Self.firstRetryNS
    }

    /// A filing failed, or a filed record was lost (the daemon went away,
    /// the group was reset, failed or collided): try again after the
    /// current back-off, which doubles up to `maxRetryNS` until a record
    /// is established again — a flapping daemon is not hammered.
    public mutating func retry(nowNS: UInt64) {
        dueAtNS = nowNS + delayNS
        delayNS = min(delayNS * 2, Self.maxRetryNS)
    }
}
