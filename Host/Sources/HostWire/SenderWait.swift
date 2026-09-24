// SenderWait: how long the host's sender thread may block between service
// passes. It wakes early for anything that brings work — an enqueue
// signal, an inbound datagram, a full socket draining — so the bound only
// has to honor the session's own timers.

public enum SenderWait {
    /// The longest wait with no earlier timer; a backstop, not a cadence.
    public static let maxWaitNS: Int64 = 100_000_000
    /// Retry spacing after ENOBUFS, which is not a socket-buffer condition
    /// POLLOUT could wait for.
    public static let noBufferBackoffNS: Int64 = 200_000

    /// The wait before the next pass: until the session's next timer
    /// (`nextWakeNS`, nil = none), zero when it is already due, and
    /// never longer than the backstop or, after ENOBUFS, the back-off.
    public static func timeoutNS(
        nowNS: UInt64, nextWakeNS: UInt64?, noBufferBackoff: Bool
    ) -> Int64 {
        var timeout = maxWaitNS
        if let nextWakeNS {
            timeout = nextWakeNS > nowNS
                ? min(Int64(clamping: nextWakeNS - nowNS), timeout) : 0
        }
        if noBufferBackoff {
            timeout = min(timeout, noBufferBackoffNS)
        }
        return timeout
    }
}
