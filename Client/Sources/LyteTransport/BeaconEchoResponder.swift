// The beacon echo's thread-safe shell: LyteClientSession's
// ClientBeaconEchoBook (the exchange the browser shares) behind a lock,
// with stats, the closed-sample hook, and the emit seam.

import LyteIO
import LyteClientSession
import LyteWire
import Synchronization

public final class BeaconEchoResponder: Sendable {
    public struct Stats: Sendable {
        public var beaconsReceived: UInt64 = 0
        public var echoesSent: UInt64 = 0
        public var malformedBeacons: UInt64 = 0
        public var clockSamples: UInt64 = 0
        /// Mirrors refused as forged or implausible (see the book).
        public var mirrorsRefused: UInt64 = 0
    }

    private struct State {
        var stats = Stats()
        var book = ClientBeaconEchoBook()
    }

    private let emit: @Sendable (BeaconEcho) -> Void
    private let now: @Sendable () -> ClientTimestamp
    private let onClockSample: (@Sendable (ClockSample) -> Void)?
    private let state = Mutex(State())

    /// - Parameters:
    ///   - emit: sends one echo.
    ///   - onClockSample: fires once per closed sample, outside the lock.
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

    /// Feeds one CTRL payload; non-beacons return false, malformed beacons
    /// count and drop. `arrivalMicroseconds` becomes t2 and must share the
    /// injected `now`'s domain (t3 − t2 is the turnaround the host
    /// subtracts).
    @discardableResult
    public func handleCtrlPayload(
        _ payload: [UInt8],
        arrivalMicroseconds: UInt64
    ) -> Bool {
        switch ClientExemptControl(payload: payload) {
        case .clockBeacon(let beacon):
            answer(beacon, arrivalMicroseconds: arrivalMicroseconds)
        case .malformed(type: CtrlMessageType.clockBeacon):
            noteMalformedBeacon()
        default:
            return false
        }
        return true
    }

    /// Echoes one decoded beacon, stamping t3 now.
    public func answer(_ beacon: ClockBeacon, arrivalMicroseconds: UInt64) {
        let t2 = ClientTimestamp(microseconds: arrivalMicroseconds)
        let t3 = now()

        let (echo, closed) = state.withLock {
            let answered = $0.book.answer(
                beacon, receivedAt: t2, sendingAt: t3)
            $0.stats.beaconsReceived += 1
            $0.stats.echoesSent += 1
            if answered.sample != nil { $0.stats.clockSamples += 1 }
            $0.stats.mirrorsRefused = $0.book.mirrorsRefused
            return answered
        }

        if let closed { onClockSample?(closed) }
        emit(echo)
    }

    /// A payload named itself a beacon and did not decode.
    public func noteMalformedBeacon() {
        state.withLock { $0.stats.malformedBeacons += 1 }
    }

    public func snapshotStats() -> Stats {
        state.withLock { $0.stats }
    }
}
