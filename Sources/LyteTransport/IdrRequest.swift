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
// in session-v1.json) — this file keeps only the client policy: coalesce
// fecImpossible verdicts into rate-limited requests, ARQ-exempt
// fire-and-forget (a lost request is superseded by the next emission
// while frames keep dying — the real retry loop under loss).

import Foundation
import LyteWire

/// Turns fecImpossible verdicts into rate-limited IDR requests. The rule:
/// at most one request per `minIntervalMicroseconds` (~100 ms — one IDR
/// heals everything, so a burst of dead frames needs one request, and the
/// interval comfortably covers host IDR turnaround at 60 fps). A verdict
/// inside the window is absorbed into the pending count; it flushes on the
/// first verdict past the window or on `flushIfDue` — the feedback
/// cadence tick (25–50 ms, always shorter than the window) drives that,
/// bounding coalesced-request latency to one cadence.
public final class IdrRequester: @unchecked Sendable {
    /// Emit-side counters, snapshotted for the CLI.
    public struct Stats: Sendable {
        public var verdicts: UInt64 = 0
        public var requestsSent: UInt64 = 0
    }

    private let minIntervalMicroseconds: UInt64
    private let emit: @Sendable (IdrRequest) -> Void
    private let lock = NSLock()

    private var nextRequestSeq: UInt32 = 0
    private var lastSentAt: ClientTimestamp?
    private var pendingCount: UInt64 = 0
    private var pendingNewestFrame: FrameNumber?
    private var stats = Stats()

    /// - Parameter emit: sends one encoded request (TransportSender via
    ///   CTRL in production, a capture closure in tests).
    public init(
        minIntervalMilliseconds: Int = 100,
        emit: @escaping @Sendable (IdrRequest) -> Void
    ) {
        self.minIntervalMicroseconds = UInt64(max(1, minIntervalMilliseconds)) * 1_000
        self.emit = emit
    }

    /// One fecImpossible verdict — LyteVideoPipeline's onFecImpossible
    /// hook calls this. Emits immediately when outside the rate window,
    /// otherwise coalesces.
    public func recordFecImpossible(frame: FrameNumber, now: ClientTimestamp) {
        lock.lock()
        stats.verdicts += 1
        pendingCount += 1
        pendingNewestFrame = frame
        let request = dueRequestLocked(now: now)
        lock.unlock()
        if let request { emit(request) }
    }

    /// Flushes a coalesced pending request once the rate window has
    /// passed; the feedback cadence timer calls this.
    public func flushIfDue(now: ClientTimestamp) {
        lock.lock()
        let request = dueRequestLocked(now: now)
        lock.unlock()
        if let request { emit(request) }
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    private func dueRequestLocked(now: ClientTimestamp) -> IdrRequest? {
        guard pendingCount > 0, let frame = pendingNewestFrame else { return nil }
        if let last = lastSentAt,
           now.microseconds(since: last) < Int64(minIntervalMicroseconds) {
            return nil
        }
        let request = IdrRequest(
            requestSeq: nextRequestSeq,
            frame: frame,
            coalescedCount: UInt8(min(pendingCount, 255))
        )
        nextRequestSeq &+= 1
        lastSentAt = now
        pendingCount = 0
        pendingNewestFrame = nil
        stats.requestsSent += 1
        return request
    }
}
