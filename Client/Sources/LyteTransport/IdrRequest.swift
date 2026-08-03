// The coalescing IDR requester (CL-3) — the client-side policy over the
// IDR-request CTRL message, the on-wire closing of CL-2's fecImpossible
// seam. Build-plan ruling §4.7: at H0b the heal path for an unrecoverable
// frame is IDR-request, NOT NACK — the host's NACK responder is HS-17
// (H2), and until then the feedback report's NACK section stays empty
// while this message asks for the one thing the host can already do
// (HS-6's pacer has IDR-on-demand from day one).
//
// The CODEC (type 0x10, fixed 10 bytes) was pinned here by CL-3 and
// mirrored host-side by HS-7; the codec-unification slice reconciled both
// byte-identical copies into LyteWire.IdrRequest (with the vector entry
// in session-v1.json) — this file keeps only the client policy: one
// recovery episode begins with the first broken-reference verdict and
// ends only when a usable IRAP is accepted. The request is ARQ-exempt /
// fire-and-forget, so an outstanding episode retries at a deliberately
// slow fixed cadence.

import Foundation
import LyteWire

/// Turns every broken-reference pathway (fec-impossible, abandoned repair,
/// whole-frame loss) into one bounded recovery episode. The first demand
/// emits immediately. Further damage is covered by that outstanding demand
/// until the render pipeline accepts a usable IRAP; it never creates a
/// second request merely because another frame failed. Since 0x10 is
/// intentionally fire-and-forget, `flushIfDue` retries every 500 ms until
/// acceptance. That is 2× the 250 ms repair/stale horizon, at least ten
/// 25–50 ms feedback cadences, and thirty 60 fps frame opportunities:
/// ample response time without waiting forever on a lost request or IDR.
public final class IdrRequester: @unchecked Sendable {
    /// Emit-side counters, snapshotted for the CLI.
    public struct Stats: Sendable {
        public var verdicts: UInt64 = 0
        public var requestsSent: UInt64 = 0
        public var episodesStarted: UInt64 = 0
        public var episodesCompleted: UInt64 = 0
        public var retryRequests: UInt64 = 0
        public var recoveryOutstanding = false
    }

    private let retryIntervalMicroseconds: UInt64
    private let emit: @Sendable (IdrRequest) -> Void
    private let lock = NSLock()

    private var nextRequestSeq: UInt32 = 0
    private struct Episode {
        var newestDamagedFrame: FrameNumber
        var damageCount: UInt64
        var lastSentAt: ClientTimestamp
    }
    private var episode: Episode?
    private var stats = Stats()

    /// - Parameter emit: sends one encoded request (TransportSender via
    ///   CTRL in production, a capture closure in tests).
    public init(
        retryIntervalMilliseconds: Int = 500,
        emit: @escaping @Sendable (IdrRequest) -> Void
    ) {
        self.retryIntervalMicroseconds =
            UInt64(max(1, retryIntervalMilliseconds)) * 1_000
        self.emit = emit
    }

    /// One broken-reference verdict from any recovery pathway. The first
    /// starts an episode and emits immediately; later verdicts only update
    /// the episode's diagnostic count/newest frame.
    public func recordRecoveryDemand(
        frame: FrameNumber, now: ClientTimestamp
    ) {
        lock.lock()
        stats.verdicts += 1
        let request: IdrRequest?
        if var current = episode {
            current.newestDamagedFrame = frame
            current.damageCount &+= 1
            episode = current
            request = retryIfDueLocked(now: now)
        } else {
            episode = Episode(
                newestDamagedFrame: frame,
                damageCount: 1,
                lastSentAt: now)
            stats.episodesStarted += 1
            stats.recoveryOutstanding = true
            request = makeRequestLocked(frame: frame, damageCount: 1)
        }
        lock.unlock()
        if let request { emit(request) }
    }

    /// The feedback-cadence timer's retry wake. Quiet when no episode is
    /// outstanding or before its 500 ms retry boundary.
    public func flushIfDue(now: ClientTimestamp) {
        lock.lock()
        let request = retryIfDueLocked(now: now)
        lock.unlock()
        if let request { emit(request) }
    }

    /// Closes the outstanding episode only after the render path accepted
    /// an IRAP sample. Merely receiving shards, a refusal, or another clean
    /// inter frame cannot clear the demand.
    public func noteUsableIrapAccepted() {
        lock.lock()
        if episode != nil {
            episode = nil
            stats.episodesCompleted += 1
            stats.recoveryOutstanding = false
        }
        lock.unlock()
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    private func retryIfDueLocked(now: ClientTimestamp) -> IdrRequest? {
        guard var current = episode,
              now.microseconds(since: current.lastSentAt)
                  >= Int64(retryIntervalMicroseconds)
        else { return nil }
        current.lastSentAt = now
        episode = current
        stats.retryRequests += 1
        return makeRequestLocked(
            frame: current.newestDamagedFrame,
            damageCount: current.damageCount)
    }

    private func makeRequestLocked(
        frame: FrameNumber, damageCount: UInt64
    ) -> IdrRequest {
        let request = IdrRequest(
            requestSeq: nextRequestSeq,
            frame: frame,
            coalescedCount: UInt8(min(damageCount, 255))
        )
        nextRequestSeq &+= 1
        stats.requestsSent += 1
        return request
    }
}
