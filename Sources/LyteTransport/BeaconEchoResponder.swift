// The beacon echo (CL-3, master plan §4.6): the host maps its clock over
// the 1 Hz CTRL ClockBeacon; the client's whole job here is to echo it
// promptly and truthfully — t2 (clientReceive) is the datagram's arrival
// stamp, t3 (clientSend) is taken at echo emit — so the host can measure
// t4 on arrival and compute offset/RTT.
//
// The beacon optionally mirrors the host's view of the last echo it
// received (t3 echoed verbatim, t4 as measured). Combined with the t1/t2
// this responder remembered for that beaconSeq, the client can compute the
// same (offset, RTT) sample the host did — those raw samples are retained
// and exposed for CL-10's HostClockModel (min-filtered offset, regression
// skew). NO filtering happens here; CL-10 owns that. Retention is a small
// ring: at 1 Hz, 256 samples is minutes of history, plenty for a model
// that needs a ~30 s window.

import Foundation
import LyteWire

/// One raw clock observation, client-side computed from a beacon's
/// lastEcho mirror. Sign convention matches BeaconEcho.clockSample:
/// offset is client − host µs.
public struct ClockSample: Hashable, Sendable {
    /// The beaconSeq whose echo round-trip produced this sample.
    public var beaconSeq: UInt32
    public var offsetMicroseconds: Int64
    public var rttMicroseconds: Int64
    /// The exchange's client-time coordinate (its t2, the beacon's
    /// arrival) — the x-axis of CL-10's regression. The mirror that
    /// CLOSES the sample arrives a beacon later; the offset was true at
    /// the exchange, so the exchange's own instant is the honest abscissa.
    public var measuredAt: ClientTimestamp

    public init(beaconSeq: UInt32, offsetMicroseconds: Int64,
                rttMicroseconds: Int64, measuredAt: ClientTimestamp) {
        self.beaconSeq = beaconSeq
        self.offsetMicroseconds = offsetMicroseconds
        self.rttMicroseconds = rttMicroseconds
        self.measuredAt = measuredAt
    }
}

public final class BeaconEchoResponder: @unchecked Sendable {
    /// Echo-path counters, snapshotted for the CLI.
    public struct Stats: Sendable {
        public var beaconsReceived: UInt64 = 0
        public var echoesSent: UInt64 = 0
        public var malformedBeacons: UInt64 = 0
        public var clockSamples: UInt64 = 0
    }

    /// Raw samples retained for CL-10; minutes of 1 Hz history.
    public static let maxRetainedSamples = 256
    /// Echoed beacons whose mirror we still await; the host mirrors the
    /// *last* echo, so a handful covers reordering.
    private static let maxPendingEchoes = 16

    private let emit: @Sendable (BeaconEcho) -> Void
    private let now: @Sendable () -> ClientTimestamp
    private let onClockSample: (@Sendable (ClockSample) -> Void)?

    private let lock = NSLock()
    private var stats = Stats()
    private var samples: [ClockSample] = []
    // beaconSeq → (t1 hostSend, t2 clientReceive, t3 clientSend), in
    // insertion order for cheap eviction.
    private var pending: [(seq: UInt32, t1: HostTimestamp,
                           t2: ClientTimestamp, t3: ClientTimestamp)] = []

    /// - Parameters:
    ///   - emit: sends one echo (TransportSender via CTRL in production,
    ///     a capture closure in tests).
    ///   - onClockSample: fires once per closed sample, outside the lock —
    ///     CL-10's HostClockModel.ingest in production. The retained ring
    ///     stays regardless (the CLI's summary reads it).
    public init(
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(microseconds: DispatchTime.now().uptimeNanoseconds / 1000)
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
    /// in the same client-monotonic domain as `now` (t3 = now() at emit;
    /// t3 − t2 is the turnaround the host subtracts) — NOT the kernel
    /// SCM_TIMESTAMP wall-clock stamp. Take a monotonic stamp on the
    /// receive thread; it is within microseconds of true arrival.
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
        let echo = BeaconEcho(
            beaconSeq: beacon.beaconSeq,
            hostSend: beacon.hostSend,
            clientReceive: t2,
            clientSend: t3)

        lock.lock()
        stats.beaconsReceived += 1
        stats.echoesSent += 1
        pending.append((beacon.beaconSeq, beacon.hostSend, t2, t3))
        if pending.count > Self.maxPendingEchoes {
            pending.removeFirst(pending.count - Self.maxPendingEchoes)
        }
        // The mirror closes an earlier echo's loop: the host tells us the
        // t4 it measured, we still hold that exchange's t1/t2, and the
        // mirrored t3 must match what we sent (echoed verbatim).
        var closed: ClockSample?
        if let mirror = beacon.lastEcho,
           let match = pending.first(where: { $0.seq == mirror.beaconSeq }) {
            let outbound = Int64(bitPattern:
                match.t2.microseconds &- match.t1.microseconds)
            let inbound = Int64(bitPattern:
                mirror.clientSend.microseconds &- mirror.hostReceive.microseconds)
            let roundTrip = Int64(bitPattern:
                mirror.hostReceive.microseconds &- match.t1.microseconds)
            let turnaround = Int64(bitPattern:
                mirror.clientSend.microseconds &- match.t2.microseconds)
            let sample = ClockSample(
                beaconSeq: mirror.beaconSeq,
                offsetMicroseconds: (outbound &+ inbound) / 2,
                rttMicroseconds: roundTrip &- turnaround,
                measuredAt: match.t2)
            samples.append(sample)
            if samples.count > Self.maxRetainedSamples {
                samples.removeFirst(samples.count - Self.maxRetainedSamples)
            }
            stats.clockSamples += 1
            pending.removeAll { $0.seq == mirror.beaconSeq }
            closed = sample
        }
        lock.unlock()

        if let closed { onClockSample?(closed) }
        emit(echo)
        return true
    }

    /// The retained raw samples, oldest first — CL-10's HostClockModel
    /// input; unfiltered by design.
    public func snapshotClockSamples() -> [ClockSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }
}
