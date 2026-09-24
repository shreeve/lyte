import XCTest
import Foundation
import LyteClientTestKit
import LyteTransport
import LyteWire

/// The REAL native client core on one guarded virtual clock, wired to a
/// `SystemHostSession`: the handshake runs through the production
/// `NoiseTransportCrypto`, host datagrams enter through the real
/// `ReceiveDemux`, and everything the client sends collects in `outbound`.
final class SystemClient: @unchecked Sendable {
    let host: SystemHostSession
    let crypto: NoiseTransportCrypto
    let demux: ReceiveDemux
    var core: LyteUdpSessionCore!
    let outbound = LockedBytePile()
    let clock = SystemClientClock()
    var samples: [DecodeUnit] = []
    var notes: [String] = []
    var recoveryDemands: [(VideoRecoveryCause, FrameNumber)] = []
    var recoveryTrace: [VideoRecoveryTraceEvent] = []

    init(
        host: SystemHostSession,
        coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
    ) throws {
        self.host = host
        let crypto = try NoiseTransportCrypto(
            hostAddress: "10.0.0.249", hostPort: 41_081,
            hostStaticPublicKey: host.staticKeys.publicKey,
            staticKeys: NoiseKeyPair.generate(),
            attempts: 3, attemptTimeoutMilliseconds: 200)
        try crypto.performHandshake(io: host)
        self.crypto = crypto
        self.demux = ReceiveDemux(crypto: crypto)
        let outbound = self.outbound
        let clock = self.clock
        let sender = TransportSender(crypto: crypto, transmit: {
            outbound.append($0)
            return true
        })
        self.core = LyteUdpSessionCore(
            demux: demux,
            sender: sender,
            config: coreConfig,
            now: { ClientTimestamp(microseconds: clock.value) },
            onVideoRecoveryDemand: { [weak self] cause, frame in
                self?.recoveryDemands.append((cause, frame))
            },
            onVideoRecoveryTrace: { [weak self] event in
                self?.recoveryTrace.append(event)
            },
            videoSink: HeadlessVideoSink(receive: {
                [weak self] _, unit in
                self?.samples.append(unit)
            }),
            onEvent: { [weak self] event in
                if case .protocolNote(let note) = event {
                    self?.notes.append(note)
                }
            })
    }

    func absorb(_ bytes: [UInt8], tMicros: UInt64) {
        let arrival = max(tMicros, host.nowMicroseconds)
        clock.advance(to: arrival)
        let outcome = demux.ingest(
            datagram: bytes[...], arrivalMicroseconds: arrival)
        switch outcome {
        case .accepted:
            core.handleDatagram(outcome, arrivalMicroseconds: arrival)
        case .unsealFailed:
            break
        default:
            XCTFail("host datagram refused: \(outcome)")
        }
    }

    /// Forwards everything the client sent to the host, in order.
    func pumpOutboundToHost(forwarded: inout Int) throws {
        while forwarded < outbound.count {
            try host.absorb(
                outbound.all[forwarded],
                clientMicros: clock.value
            )
            forwarded += 1
        }
    }

    /// Finish the real Session's startup control flight through the real
    /// client. The beacon echo returns through the same encrypted CTRL
    /// path and seeds the host's actual SRTT estimator.
    func settleStartup(forwarded: inout Int, at t: UInt64) throws {
        clock.advance(to: t)
        for datagram in host.takeControlDatagrams(
            maxAdvanceNS: 5_000_000
        ) {
            absorb(datagram, tMicros: t)
        }
        try pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertNotNil(
            host.session.srttMicroseconds,
            "the real startup beacon/echo must seed host SRTT"
        )
    }
}

final class SystemClientClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64 = 1_000
    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func advance(
        to next: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        lock.lock()
        guard next >= stored else {
            let previous = stored
            lock.unlock()
            XCTFail(
                "client clock retreated from \(previous) to \(next)",
                file: file,
                line: line
            )
            return
        }
        stored = next
        lock.unlock()
    }
}
