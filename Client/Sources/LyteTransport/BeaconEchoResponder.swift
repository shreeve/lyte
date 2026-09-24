// The beacon echo's thread-safe shell: LyteClientSession's
// ClientBeaconEchoBook (the exchange the browser shares) behind a lock,
// with stats, the closed-sample hook, and the emit seam.

import LyteIO
import Foundation
import LyteClientSession
import LyteWire

public final class BeaconEchoResponder: @unchecked Sendable {
    /// Echo-path counters, snapshotted for the CLI.
    public struct Stats: Sendable {
        public var beaconsReceived: UInt64 = 0
        public var echoesSent: UInt64 = 0
        public var malformedBeacons: UInt64 = 0
        public var clockSamples: UInt64 = 0
    }

    private let emit: @Sendable (BeaconEcho) -> Void
    private let now: @Sendable () -> ClientTimestamp
    private let onClockSample: (@Sendable (ClockSample) -> Void)?

    private let lock = NSLock()
    private var stats = Stats()
    private var book = ClientBeaconEchoBook()

    /// - Parameters:
    ///   - emit: sends one echo (TransportSender via CTRL in production,
    ///     a capture closure in tests).
    ///   - onClockSample: fires once per closed sample, outside the lock —
    ///     HostClockModel.ingest in production, which retains the window
    ///     every reader uses.
    public init(
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(microseconds: SystemMonotonicClock.nowMicroseconds)
        },
        onClockSample: (@Sendable (ClockSample) -> Void)? = nil,
        emit: @escaping @Sendable (BeaconEcho) -> Void
    ) {
        self.now = now
        self.onClockSample = onClockSample
        self.emit = emit
    }

    /// Feeds one CTRL payload. Non-beacon types pass through untouched
    /// (false); malformed beacons count and drop — hostile bytes never
    /// stop the echo path. `arrivalMicroseconds` becomes t2 and MUST be
    /// in the same domain as the injected `now` (t3 = now() at emit;
    /// t3 − t2 is the turnaround the host subtracts). The session passes
    /// its own `now()` read on the receive thread, within microseconds of
    /// true arrival.
    @discardableResult
    public func handleCtrlPayload(
        _ payload: [UInt8],
        arrivalMicroseconds: UInt64
    ) -> Bool {
        guard CtrlMessageType.peek(payload) == CtrlMessageType.clockBeacon else {
            return false
        }
        let beacon: ClockBeacon
        do {
            beacon = try ClockBeacon.decode(payload)
        } catch {
            lock.lock()
            stats.malformedBeacons += 1
            lock.unlock()
            return true   // it named itself a beacon; it was consumed here
        }

        let t2 = ClientTimestamp(microseconds: arrivalMicroseconds)
        let t3 = now()

        lock.lock()
        let (echo, closed) = book.answer(beacon, receivedAt: t2, sendingAt: t3)
        stats.beaconsReceived += 1
        stats.echoesSent += 1
        if closed != nil {
            stats.clockSamples += 1
        }
        lock.unlock()

        if let closed { onClockSample?(closed) }
        emit(echo)
        return true
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }
}
