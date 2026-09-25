import Foundation
import HostSession
import HostWire
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit
import XCTest

/// A shipping HostWire.Session with only UDP IO and monotonic time replaced.
/// Both cross-end gates use this one host boundary; feature policy remains in
/// the real Session and its production services.
final class SystemHostSession: NoiseHandshakeIO {
    static let initialClientTuple = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_081,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    private final class Outbox {
        var datagrams: [VideoChannelDatagram] = []
    }

    let staticKeys = NoiseKeyPair.generate()
    private let outbox = Outbox()
    private let config: SessionConfig
    private var nowNS: UInt64 = 0
    private var nextFrameNumber: UInt32 = 0
    private var repairsTaken = 0
    private(set) var events: [SessionEvent] = []
    /// Where client datagrams arrive from; a gate moves it to roam.
    var clientTuple = SystemHostSession.initialClientTuple

    private var acceptor: HandshakeAcceptor
    /// Nil until the client's message 1 is answered.
    private(set) var session: Session!

    init(tweak: (inout SessionConfig) -> Void = { _ in }) {
        var config = SessionConfig(rateBitsPerSecond: 1_000_000_000)
        tweak(&config)
        self.config = config
        acceptor = HandshakeAcceptor(
            config: HandshakeAcceptor.Config(hostStatic: staticKeys))
    }

    /// The listening shell's routing: the answered session reads first;
    /// anything else is the acceptor's.
    private func route(_ datagram: [UInt8]) throws -> [SessionEvent] {
        var events = session?.receive(
            datagram, from: clientTuple,
            now: nowNS, hostMicroseconds: nowNS / 1_000
        ) ?? []
        if session == nil || events.contains(.initiationWhileUnconfirmed),
           case .authenticated(let handshake) = acceptor.accept(
               datagram[...], from: clientTuple, now: nowNS
           ).verdict {
            let answered = try Session.answer(
                handshake, config: config,
                now: nowNS, hostMicroseconds: nowNS / 1_000,
                rng: SplitMix64(seed: 0xC1_12),
                send: { [outbox] datagram in
                    outbox.datagrams.append(datagram)
                }
            )
            session = answered.session
            events += answered.events
        }
        return events
    }

    var nowMicroseconds: UInt64 {
        (nowNS &+ 999) / 1_000
    }

    func sendToHost(_ datagram: [UInt8]) throws {
        record(try route(datagram))
        session?.pump(now: nowNS)
    }

    func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
        serviceUntil(
            maxAdvanceNS: UInt64(timeoutMilliseconds) * 1_000_000
        ) { !outbox.datagrams.isEmpty }
        guard !outbox.datagrams.isEmpty else { return nil }
        return outbox.datagrams.removeFirst().bytes
    }

    @discardableResult
    func absorb(_ bytes: [UInt8], clientMicros: UInt64) throws
        -> [SessionEvent]
    {
        let arrivalNS = clientMicros * 1_000
        try advanceClock(to: arrivalNS)
        let received = try route(bytes)
        record(received)
        session.pump(now: nowNS)
        return received
    }

    /// Drives only due Session work at an externally chosen virtual instant.
    /// Pairing's SimNet owns this clock; no helper may silently run ahead.
    @discardableResult
    func advance(to hostMicros: UInt64) throws -> [SessionEvent] {
        try advanceClock(to: hostMicros * 1_000)
        let advanced = session.advance(
            now: nowNS,
            hostMicroseconds: nowNS / 1_000
        )
        record(advanced)
        session.pump(now: nowNS)
        return advanced
    }

    func takeReadyControlDatagrams() -> [[UInt8]] {
        session.pump(now: nowNS)
        return take { $0.pacerClass == .control }.map(\.bytes)
    }

    func takeControlDatagrams(
        maxAdvanceNS: UInt64
    ) -> [[UInt8]] {
        serviceFor(maxAdvanceNS: maxAdvanceNS)
        return takeReadyControlDatagrams()
    }

    func videoDatagrams(
        annexB: [UInt8], frameNumber: UInt32, hostMicros: UInt64
    ) throws -> [[UInt8]] {
        XCTAssertEqual(
            frameNumber, nextFrameNumber,
            "the shipping Session owns one ascending frame sequence"
        )
        guard frameNumber == nextFrameNumber else { return [] }
        nextFrameNumber &+= 1
        try advanceClock(to: hostMicros * 1_000)
        let count = try session.ingestVideoFrame(
            annexB,
            captureTimestampMicroseconds: hostMicros,
            isKeyframe: AnnexBCheck.containsIrap(annexB),
            now: nowNS
        )
        serviceUntil(maxAdvanceNS: 20_000_000) {
            self.outbox.datagrams.filter {
                $0.pacerClass == .freshVideo
                    && $0.frameNumber.rawValue == frameNumber
            }.count >= count
        }
        let datagrams = take {
            $0.pacerClass == .freshVideo
                && $0.frameNumber.rawValue == frameNumber
        }
        XCTAssertEqual(
            datagrams.count, count,
            "the Session did not release its complete video flight"
        )
        return datagrams.map(\.bytes)
    }

    func takeRepairDatagrams() -> [[UInt8]] {
        let expected = session.counters.repairDatagramsEnqueued
            - repairsTaken
        serviceUntil(maxAdvanceNS: 20_000_000) {
            self.outbox.datagrams.filter {
                $0.pacerClass == .videoTail
            }.count >= expected
        }
        let datagrams = take { $0.pacerClass == .videoTail }
        repairsTaken += datagrams.count
        return datagrams.map(\.bytes)
    }

    private func record(_ newEvents: [SessionEvent]) {
        events.append(contentsOf: newEvents)
    }

    private func advanceClock(to instantNS: UInt64) throws {
        guard instantNS >= nowNS else {
            throw NSError(
                domain: "LyteClientHostTests.hostClockRetreat",
                code: 1,
                userInfo: [
                    "hostNowNS": nowNS,
                    "requestedNS": instantNS,
                ]
            )
        }
        nowNS = instantNS
    }

    private func take(
        where selectedBy: (VideoChannelDatagram) -> Bool
    ) -> [VideoChannelDatagram] {
        var selected: [VideoChannelDatagram] = []
        var kept: [VideoChannelDatagram] = []
        for datagram in outbox.datagrams {
            if selectedBy(datagram) {
                selected.append(datagram)
            } else {
                kept.append(datagram)
            }
        }
        outbox.datagrams = kept
        return selected
    }

    private func serviceFor(maxAdvanceNS: UInt64) {
        let horizon = nowNS &+ maxAdvanceNS
        guard let session else { return }
        session.pump(now: nowNS)
        while let wake = session.nextWake(now: nowNS), wake <= horizon {
            nowNS = max(nowNS &+ 1, wake)
            record(session.advance(
                now: nowNS,
                hostMicroseconds: nowNS / 1_000
            ))
            session.pump(now: nowNS)
        }
    }

    private func serviceUntil(
        maxAdvanceNS: UInt64,
        _ done: () -> Bool
    ) {
        let horizon = nowNS &+ maxAdvanceNS
        guard let session else { return }
        session.pump(now: nowNS)
        while !done(),
              let wake = session.nextWake(now: nowNS),
              wake <= horizon {
            nowNS = max(nowNS &+ 1, wake)
            record(session.advance(
                now: nowNS,
                hostMicroseconds: nowNS / 1_000
            ))
            session.pump(now: nowNS)
        }
    }
}
