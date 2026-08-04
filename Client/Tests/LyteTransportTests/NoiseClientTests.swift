import XCTest
import Foundation
@testable import LyteTransport
import LyteWire

// The client Noise leg (CL-1 closed): NoiseTransportCrypto as IK
// initiator against an in-process LyteWire responder — the exact
// counterpart of the host's HS-7 gate, which drives a LyteWire initiator
// against HostWire.Session. Covers: the 1-RTT handshake over the promoted
// 0x05/0x06 carriage, sealed round trips both directions with
// envelope-header AAD and (chan, seq) ROC, tamper rejection, replay
// rejection, and the wrong-pinned-pubkey refusal.

final class NoiseClientTests: XCTestCase {

    func testHandshakeHashAloneOwnsEstablishedPosture() throws {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        let packageRoot = components.joined(separator: "/")
        let source = try String(
            contentsOfFile:
                packageRoot
                    + "/Sources/LyteTransport/NoiseTransportCrypto.swift",
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("private var established"))
        XCTAssertFalse(source.contains("established ="))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "handshakeHash != nil").count - 1,
            4
        )
    }

    /// The host's half, in-process: answers a carried message 1 from
    /// fresh responder state (the HS-7 rule) and exposes the transport it
    /// derives, so tests can seal/unseal as the host would.
    private final class InProcessHost: NoiseHandshakeIO {
        let hostStatic: NoiseKeyPair
        var transport: NoiseTransport?
        var message1Attempts = 0
        /// Simulates a lost message 2 for the first N attempts.
        var dropMessage2Count = 0
        private var outbox: [[UInt8]] = []

        init(hostStatic: NoiseKeyPair = .generate()) {
            self.hostStatic = hostStatic
        }

        func sendToHost(_ datagram: [UInt8]) throws {
            guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
                  envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake1
            else { return }
            message1Attempts += 1
            // Fresh responder per attempt; a message 1 this static cannot
            // open (wrong pinned key on the client) is dropped silently —
            // exactly what the real host does (the client times out).
            guard var responder = try? NoiseSession(
                role: .responder, staticKeys: hostStatic),
                (try? responder.readMessage1(payload.dropFirst())) != nil
            else { return }
            guard let message2 = try? responder.writeMessage2(),
                  let made = try? responder.makeTransport()
            else { return }
            transport = made
            if dropMessage2Count > 0 {
                dropMessage2Count -= 1
                return
            }
            let carriage = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: 0),
                frame: FrameNumber(rawValue: 0),
                timestamp: 42,
                fec: 0
            )
            outbox.append(try carriage.encode(
                payload: [CtrlMessageType.noiseHandshake2] + message2))
        }

        func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
            outbox.isEmpty ? nil : outbox.removeFirst()
        }
    }

    private func makeEstablishedPair() throws -> (NoiseTransportCrypto, InProcessHost) {
        let host = InProcessHost()
        let crypto = try NoiseTransportCrypto(
            hostAddress: "10.0.0.249", hostPort: 41_000,
            hostStaticPublicKey: host.hostStatic.publicKey,
            attempts: 3, attemptTimeoutMilliseconds: 200)
        try crypto.performHandshake(io: host)
        return (crypto, host)
    }

    /// One host→client sealed datagram through the client seam, as the
    /// demux would drive it: header bytes as AAD, then unseal.
    private func hostSeal(
        _ host: InProcessHost, plaintext: [UInt8],
        channel: ChannelId, seq: UInt16, frame: UInt32 = 0
    ) throws -> [UInt8] {
        let envelope = Envelope(
            channel: channel,
            seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: frame),
            timestamp: 1_000_000,
            fec: 0
        )
        let header = try envelope.encode(payload: [])
        let sealed = try host.transport!.seal(
            plaintext: plaintext[...], aad: header[...], envelope: envelope)
        return try envelope.encode(payload: sealed)
    }

    // MARK: Handshake

    func testHandshakeCompletesAndOpens() throws {
        let (crypto, host) = try makeEstablishedPair()
        XCTAssertNoThrow(try crypto.open())
        XCTAssertEqual(host.message1Attempts, 1, "1-RTT: one message 1")
        XCTAssertNotNil(crypto.handshakeMillisecondsSnapshot)
        XCTAssertTrue(crypto.modeDescription.contains("Noise IK"))
    }

    func testHandshakeRetriesAfterLostMessage2() throws {
        let host = InProcessHost()
        host.dropMessage2Count = 1
        let crypto = try NoiseTransportCrypto(
            hostAddress: "10.0.0.249", hostPort: 41_000,
            hostStaticPublicKey: host.hostStatic.publicKey,
            attempts: 3, attemptTimeoutMilliseconds: 60)
        try crypto.performHandshake(io: host)
        XCTAssertEqual(host.message1Attempts, 2,
                       "the client owns the retry timer")
        XCTAssertNoThrow(try crypto.open())
    }

    func testWrongPinnedPubkeyNeverEstablishes() throws {
        let host = InProcessHost()
        let crypto = try NoiseTransportCrypto(
            hostAddress: "10.0.0.249", hostPort: 41_000,
            hostStaticPublicKey: NoiseKeyPair.generate().publicKey, // not the host's
            attempts: 2, attemptTimeoutMilliseconds: 40)
        XCTAssertThrowsError(try crypto.performHandshake(io: host)) {
            guard case TransportCryptoError.handshakeFailed = $0 else {
                return XCTFail("expected handshakeFailed, got \($0)")
            }
        }
        XCTAssertEqual(host.message1Attempts, 2,
                       "the host saw message 1s it could not open")
        XCTAssertNil(host.transport,
                     "the responder never derived a transport")
        XCTAssertThrowsError(try crypto.open())
    }

    // MARK: Sealed round trips

    func testHostToClientSealedRoundTripThroughDemux() throws {
        let (crypto, host) = try makeEstablishedPair()
        let demux = ReceiveDemux(crypto: crypto)

        // Three shards, advancing (chan, seq) — the ROC discipline both
        // ends share, driven exactly as the receive path does.
        for seq in 0..<3 {
            let plaintext: [UInt8] = [0xAB, UInt8(seq), 0xCD]
            let datagram = try hostSeal(
                host, plaintext: plaintext,
                channel: .videoActive, seq: UInt16(seq), frame: UInt32(seq))
            guard case .accepted(let envelope, let payload) =
                demux.ingest(datagram: datagram[...], arrivalMicroseconds: 1)
            else {
                return XCTFail("seq \(seq) refused")
            }
            XCTAssertEqual(envelope.seq.rawValue, UInt16(seq))
            XCTAssertEqual(payload, plaintext)
        }
        XCTAssertEqual(demux.snapshotTotals().unsealFailures, 0)
    }

    func testClientToHostSealedRoundTripThroughSender() throws {
        let (crypto, host) = try makeEstablishedPair()
        let captured = LockedDatagrams()
        let sender = TransportSender(crypto: crypto,
                                     transmit: { captured.append($0); return true })
        let echoBody: [UInt8] = Array(0..<29)
        try sender.send(channel: .ctrl,
                        timestamp: ClientTimestamp(microseconds: 7),
                        plaintext: echoBody)

        let datagram = captured.all[0]
        let (envelope, payload) = try Envelope.decode(datagram[...])
        XCTAssertEqual(envelope.channel, .ctrl)
        XCTAssertNotEqual(Array(payload), echoBody,
                          "the wire payload must be ciphertext")
        XCTAssertEqual(payload.count, echoBody.count + 16, "16 B tag")

        let aad = datagram[datagram.startIndex..<payload.startIndex]
        let opened = try host.transport!.unseal(
            wirePayload: payload, aad: aad, envelope: envelope)
        XCTAssertEqual(opened, echoBody)
    }

    // MARK: Directional concurrency

    func testSealAndUnsealCriticalSectionsOverlap() throws {
        let host = InProcessHost()
        let probe = NoiseTransportOperationProbe(rendezvousDirections: true)
        let crypto = try NoiseTransportCrypto(
            hostAddress: "10.0.0.249", hostPort: 41_000,
            hostStaticPublicKey: host.hostStatic.publicKey,
            attempts: 3, attemptTimeoutMilliseconds: 200,
            operationProbe: probe)
        try crypto.performHandshake(io: host)

        let inboundDatagram = try hostSeal(
            host, plaintext: [0xA1, 0xA2],
            channel: .videoActive, seq: 0)
        let (inboundEnvelope, inboundPayload) =
            try Envelope.decode(inboundDatagram[...])
        let inboundAAD =
            inboundDatagram[inboundDatagram.startIndex..<inboundPayload.startIndex]

        let outboundEnvelope = Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 99, fec: 0)
        let outboundAAD = try outboundEnvelope.encode(payload: [])
        let results = LockedCryptoResults()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                results.sealed = try crypto.seal(
                    plaintext: [0xB1, 0xB2][...],
                    aad: outboundAAD[...], envelope: outboundEnvelope)
            } catch {
                results.appendError(error)
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                results.unsealed = try crypto.unseal(
                    wirePayload: inboundPayload, aad: inboundAAD,
                    envelope: inboundEnvelope)
            } catch {
                results.appendError(error)
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success,
            "opposite directions must not deadlock")
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertEqual(results.unsealed, [0xA1, 0xA2])
        XCTAssertTrue(probe.snapshot.directionalOverlap,
            "seal and unseal must occupy disjoint critical sections")
        let sealed = try XCTUnwrap(results.sealed)
        XCTAssertEqual(
            try host.transport!.unseal(
                wirePayload: sealed[...], aad: outboundAAD[...],
                envelope: outboundEnvelope),
            [0xB1, 0xB2])
    }

    func testSameDirectionOperationsRemainSerialized() throws {
        let host = InProcessHost()
        let probe = NoiseTransportOperationProbe(holdMilliseconds: 20)
        let crypto = try NoiseTransportCrypto(
            hostAddress: "10.0.0.249", hostPort: 41_000,
            hostStaticPublicKey: host.hostStatic.publicKey,
            attempts: 3, attemptTimeoutMilliseconds: 200,
            operationProbe: probe)
        try crypto.performHandshake(io: host)

        let envelopes = [
            Envelope(
                channel: .ctrl, seq: ChannelSeq(rawValue: 0),
                frame: FrameNumber(rawValue: 0), timestamp: 1, fec: 0),
            Envelope(
                channel: .feedback, seq: ChannelSeq(rawValue: 0),
                frame: FrameNumber(rawValue: 0), timestamp: 2, fec: 0),
        ]
        let headers = try envelopes.map { try $0.encode(payload: []) }
        let results = LockedCryptoResults()
        let group = DispatchGroup()
        for index in envelopes.indices {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let sealed = try crypto.seal(
                        plaintext: [UInt8(index)][...],
                        aad: headers[index][...],
                        envelope: envelopes[index])
                    results.appendSealed(sealed, at: index)
                } catch {
                    results.appendError(error)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success,
            "same-direction serialization must not deadlock")
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertEqual(probe.snapshot.maximumConcurrentSeals, 1,
            "the send nonce/tracker state must have one mutator")
        for index in envelopes.indices {
            let sealed = try XCTUnwrap(results.sealed(at: index))
            XCTAssertEqual(
                try host.transport!.unseal(
                    wirePayload: sealed[...], aad: headers[index][...],
                    envelope: envelopes[index]),
                [UInt8(index)])
        }

        let inboundDatagrams = try [
            hostSeal(
                host, plaintext: [0x31],
                channel: .audio, seq: 0),
            hostSeal(
                host, plaintext: [0x32],
                channel: .videoIdle, seq: 0),
        ]
        let inbound = try inboundDatagrams.map { datagram in
            let (envelope, payload) = try Envelope.decode(datagram[...])
            return (
                envelope,
                Array(payload),
                Array(datagram[datagram.startIndex..<payload.startIndex]))
        }
        for index in inbound.indices {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let plaintext = try crypto.unseal(
                        wirePayload: inbound[index].1[...],
                        aad: inbound[index].2[...],
                        envelope: inbound[index].0)
                    results.appendUnsealed(plaintext, at: index)
                } catch {
                    results.appendError(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success,
            "receive-state serialization must not deadlock")
        XCTAssertTrue(results.errors.isEmpty, "\(results.errors)")
        XCTAssertEqual(probe.snapshot.maximumConcurrentUnseals, 1,
            "the receive replay/tracker state must have one mutator")
        XCTAssertEqual(results.unsealed(at: 0), [0x31])
        XCTAssertEqual(results.unsealed(at: 1), [0x32])
    }

    // MARK: Hostile bytes

    func testTamperedPayloadAndHeaderReject() throws {
        let (crypto, host) = try makeEstablishedPair()
        let demux = ReceiveDemux(crypto: crypto)

        var flippedPayload = try hostSeal(
            host, plaintext: [1, 2, 3], channel: .videoActive, seq: 0)
        flippedPayload[flippedPayload.count - 1] ^= 0x01
        guard case .unsealFailed = demux.ingest(
            datagram: flippedPayload[...], arrivalMicroseconds: 1)
        else {
            return XCTFail("tampered ciphertext must reject")
        }

        // Header tamper (the AAD): flip a frame-number byte — the tag
        // binds the header, so the AEAD refuses even though the
        // ciphertext is untouched.
        var flippedHeader = try hostSeal(
            host, plaintext: [1, 2, 3], channel: .videoActive, seq: 1)
        flippedHeader[4] ^= 0x01
        guard case .unsealFailed = demux.ingest(
            datagram: flippedHeader[...], arrivalMicroseconds: 1)
        else {
            return XCTFail("tampered header must reject")
        }
        XCTAssertEqual(demux.snapshotTotals().unsealFailures, 2)
    }

    func testReplayedDatagramRejects() throws {
        let (crypto, host) = try makeEstablishedPair()
        let demux = ReceiveDemux(crypto: crypto)
        let datagram = try hostSeal(
            host, plaintext: [9, 9, 9], channel: .videoActive, seq: 5)
        guard case .accepted = demux.ingest(
            datagram: datagram[...], arrivalMicroseconds: 1)
        else {
            return XCTFail("first delivery must be accepted")
        }
        guard case .unsealFailed = demux.ingest(
            datagram: datagram[...], arrivalMicroseconds: 2)
        else {
            return XCTFail("the byte-identical resend must reject as replay")
        }
    }

    private final class LockedDatagrams: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[UInt8]] = []
        func append(_ d: [UInt8]) { lock.lock(); stored.append(d); lock.unlock() }
        var all: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private final class LockedCryptoResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storedSealed: [[UInt8]?] = [nil, nil]
        private var storedUnsealed: [UInt8]?
        private var storedUnsealedByIndex: [[UInt8]?] = [nil, nil]
        private var storedErrors: [String] = []

        var sealed: [UInt8]? {
            get { lock.lock(); defer { lock.unlock() }; return storedSealed[0] }
            set { lock.lock(); storedSealed[0] = newValue; lock.unlock() }
        }
        func appendSealed(_ value: [UInt8], at index: Int) {
            lock.lock()
            storedSealed[index] = value
            lock.unlock()
        }
        func sealed(at index: Int) -> [UInt8]? {
            lock.lock()
            defer { lock.unlock() }
            return storedSealed[index]
        }
        var unsealed: [UInt8]? {
            get { lock.lock(); defer { lock.unlock() }; return storedUnsealed }
            set { lock.lock(); storedUnsealed = newValue; lock.unlock() }
        }
        func appendUnsealed(_ value: [UInt8], at index: Int) {
            lock.lock()
            storedUnsealedByIndex[index] = value
            lock.unlock()
        }
        func unsealed(at index: Int) -> [UInt8]? {
            lock.lock()
            defer { lock.unlock() }
            return storedUnsealedByIndex[index]
        }
        var errors: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedErrors
        }
        func appendError(_ error: Error) {
            lock.lock()
            storedErrors.append(String(describing: error))
            lock.unlock()
        }
    }
}
