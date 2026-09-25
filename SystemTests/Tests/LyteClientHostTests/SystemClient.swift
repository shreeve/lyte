import XCTest
import LyteClientTestKit
import LyteTransport
import LyteWire

/// The REAL native client core on one guarded virtual clock, dialed into a
/// `SystemHostSession`: the kit's core harness, whose host is the real
/// HostWire session.
typealias SystemClient = ClientCoreHarness<SystemHostSession>

extension SystemHostSession: CoreHarnessHost {
    func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
        try absorb(bytes, clientMicros: nowMicros)
    }
}

extension ClientCoreHarness where Host == SystemHostSession {
    convenience init(
        host: SystemHostSession,
        coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
    ) throws {
        try self.init(host: host, hostPort: 41_081, coreConfig: coreConfig)
    }

    var notes: [String] {
        events.compactMap {
            guard case .protocolNote(let note) = $0 else { return nil }
            return note
        }
    }

    /// One host datagram, arriving no earlier than the host sent it; the
    /// client clock moves to the arrival. Anything but acceptance or a
    /// superseded key fails the test.
    func deliver(_ bytes: [UInt8], at tMicros: UInt64) {
        let arrival = max(tMicros, host.nowMicroseconds)
        clock.advance(to: arrival)
        switch absorb(bytes, tMicros: arrival) {
        case .accepted, .unsealFailed:
            break
        case let outcome:
            XCTFail("host datagram refused: \(outcome)")
        }
    }

    /// Frame `number`, packetized by the host at `t`, delivered whole.
    func deliverFrame(_ annexB: [UInt8], number: UInt32, at t: UInt64) throws {
        for datagram in try host.videoDatagrams(
            annexB: annexB, frameNumber: number, hostMicros: t
        ) {
            deliver(datagram, at: t)
        }
    }

    /// Forwards everything the client sent to the host, in order.
    func pumpOutboundToHost(forwarded: inout Int) throws {
        while forwarded < outbound.count {
            try host.absorb(outbound[forwarded], clientMicros: clock.value)
            forwarded += 1
        }
    }

    /// Finish the real Session's startup control flight through the real
    /// client. The beacon echo returns through the same encrypted CTRL
    /// path and seeds the host's actual SRTT estimator.
    func settleStartup(forwarded: inout Int, at t: UInt64) throws {
        clock.advance(to: t)
        for datagram in host.takeControlDatagrams(maxAdvanceNS: 5_000_000) {
            deliver(datagram, at: t)
        }
        try pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertNotNil(
            host.session.srttMicroseconds,
            "the real startup beacon/echo must seed host SRTT")
    }
}

extension ManualMicrosClock {
    /// Moves forward to `next`; a retreat fails the test and holds.
    func advance(
        to next: UInt64, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            next, value, "client clock retreated", file: file, line: line)
        value = max(value, next)
    }
}
