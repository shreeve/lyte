// SenderWait: how long the host's sender thread may block between service
// passes. It wakes early for anything that brings work — an enqueue
// signal, an inbound datagram, a full socket draining — so the bound only
// has to honor the session's own timers.
//
// Invariant: the realtime sender never busy-loops. Work the shell is
// holding back (video behind a full or out-of-buffer socket, or behind
// kernel pressure) must not set the timeout — otherwise the pacer's
// refilled bucket reads "due now" on every pass and the wait collapses
// to zero while nothing can move.

public enum SenderWait {
    /// Why the shell is not releasing video this pass.
    public enum Hold: Equatable, Sendable {
        /// Nothing held: every pacer class may be released.
        case none
        /// EAGAIN: POLLOUT on the full socket is video's wake.
        case socketFull
        /// ENOBUFS: not a socket-buffer condition POLLOUT could wait
        /// for, so the next attempt comes after a fixed back-off.
        case noBuffer
        /// Kernel pressure keeps video in the pacer with the socket
        /// writable; nothing signals recovery, so it is re-sampled on a
        /// bounded cadence.
        case pressure
    }

    /// The longest wait with no earlier timer; a backstop, not a cadence.
    public static let maxWaitNS: Int64 = 100_000_000
    /// Retry spacing after ENOBUFS.
    public static let noBufferBackoffNS: Int64 = 200_000
    /// Re-sample spacing while kernel pressure holds due video (one
    /// pacer quantum).
    public static let pressureRecheckNS: Int64 = 1_000_000

    /// The wait before the next pass. `latencyWakeNS` is the session's
    /// next timer or latency-class release (`Session.nextWake(upThrough:
    /// .audio)`); `allWakeNS` also counts video (`Session.nextWake`).
    /// Nil = no such work. A due wake means no wait, except under
    /// ENOBUFS, where retrying sooner than the back-off cannot succeed.
    public static func timeoutNS(
        nowNS: UInt64, latencyWakeNS: UInt64?, allWakeNS: UInt64?, hold: Hold
    ) -> Int64 {
        switch hold {
        case .none:
            return until(allWakeNS, from: nowNS)
        case .socketFull:
            return until(latencyWakeNS, from: nowNS)
        case .noBuffer:
            return noBufferBackoffNS
        case .pressure:
            return min(
                until(latencyWakeNS, from: nowNS),
                max(until(allWakeNS, from: nowNS), pressureRecheckNS))
        }
    }

    /// Time until `wakeNS`: zero when due, the backstop when nil or far.
    static func until(_ wakeNS: UInt64?, from nowNS: UInt64) -> Int64 {
        guard let wakeNS else { return maxWaitNS }
        guard wakeNS > nowNS else { return 0 }
        return min(Int64(clamping: wakeNS - nowNS), maxWaitNS)
    }
}
