import XCTest
import LyteClientTestKit
import Foundation
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (F-5, the client half of roaming/reconnect — the host
// session-busy/takeover half is Host territory). Pinned behaviors:
//
//   • the detection ladder in virtual time: FROZEN alone is a blip
//     (no roaming action); silence past the scan threshold begins the
//     QUIET re-browse; evidence returning cancels everything and the
//     ladders reset;
//   • host-moved vs host-silent: the same identity (pkh — sha256 of
//     the Noise static, the advertisement's TXT record and the pinned
//     store's key) at a NEW address dials immediately; at the SAME
//     address only past the redial threshold (the network works, the
//     session is dark); foreign identities never trigger anything;
//   • the give-up posture: there isn't one — fruitless scans back off
//     1 s doubling to the 15 s ceiling, dial retries 2 s doubling to
//     30 s, deadlines always in the future (never spin hot), forever;
//   • client-side path change: the migration grace (HS-12's mechanism
//     gets first refusal), dissolved by evidence, escalating to the
//     scan ladder over a frozen path with the same-address threshold
//     waived (our own address moved);
//   • the manual Reconnect verb resets every ladder and acts NOW
//     (probe dial + scan);
//   • the pairing store keys by host identity, not address — a pinned
//     host that moved is the same pinned host, preferences intact;
//   • the banner speaks ("looking for …", "found at … — reconnecting")
//     and the path watcher's trigger rule (baseline never notifies,
//     any later signature change does);
//   • end to end through the REAL session core in virtual time: a
//     mid-transfer blackout at address A drives FROZEN at the
//     detector and the liveness close at 30 s, the policy scans,
//     sights the same pkh at address B, dials — and the fresh session
//     (same pinned static, new "address") re-offers the SAME transfer
//     id whose resume finishes sha-exact, reading only the gap.
//
// NOT here, deliberately (DEFERRED-PENDING-HOST — the wave-entry
// ledger): the live host-IP flip on pup, the Mac Wi-Fi hop, and the
// mid-bulk-transfer roam completing sha-exact at the glass; the
// host's session-busy/takeover story is the F-5 Host half.

final class RoamingClientGateTests: XCTestCase {

    private func makePolicy(
        address: String = "10.0.0.60", port: UInt16 = 41_161
    ) -> RoamingPolicy {
        RoamingPolicy(
            targetPublicKeyHash: "ab12", address: address, port: port)
    }

    private func sighting(
        _ address: String, pkh: String = "ab12", port: UInt16 = 41_161
    ) -> RoamingSighting {
        RoamingSighting(publicKeyHash: pkh, address: address, port: port)
    }

    // MARK: Leg 1 — the silence threshold, and evidence cancelling

    func testSilenceThresholdBeginsQuietScanAndEvidenceCancels() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        XCTAssertEqual(policy.status, .attached)
        XCTAssertNil(policy.nextDeadline, "healthy session pends nothing")

        // FROZEN at t=1 s: the silence clock starts, nothing happens
        // yet — the pill's tier.
        XCTAssertEqual(policy.wentSilent(now: 1_000_000), [])
        XCTAssertEqual(policy.status, .silent)
        XCTAssertEqual(policy.nextDeadline, 4_000_000,
                       "the scan threshold is silence onset + 3 s")

        // Below the threshold: still nothing.
        XCTAssertEqual(policy.tick(now: 3_999_999), [])
        // At it: exactly one quiet scan begins.
        XCTAssertEqual(policy.tick(now: 4_000_000), [.beginScan])
        XCTAssertEqual(policy.status, .searching)

        // Evidence returns while the browse is in flight: the hunt
        // stands down, and the pass's late completion is ignored —
        // no dial can rise from a cancelled scan.
        XCTAssertEqual(policy.evidenceReturned(now: 4_500_000), [])
        XCTAssertEqual(policy.status, .attached)
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.9.9.9")], now: 5_000_000),
            [])
        XCTAssertEqual(policy.status, .attached)
        XCTAssertNil(policy.nextDeadline)
        print("F-5 gate (threshold): FROZEN+3 s → one scan; evidence "
            + "cancels; a cancelled scan's sighting is inert")
    }

    // MARK: Leg 2 — host moved: same pkh, NEW address, immediate dial

    func testSameIdentityAtNewAddressDialsImmediately() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = policy.wentSilent(now: 1_000_000)
        XCTAssertEqual(policy.tick(now: 4_000_000), [.beginScan])

        // A FOREIGN identity at a new address is somebody else's
        // host: no dial, the ladder just schedules the next pass.
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.9.9.9", pkh: "ffff")],
                now: 6_000_000),
            [])
        XCTAssertEqual(policy.status, .searching)

        // The next pass sights OUR identity at a NEW address: the
        // standing session is unreachable by construction — dial now,
        // well before the 8 s same-address threshold.
        XCTAssertEqual(policy.tick(now: 7_000_000), [.beginScan])
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.9.9.9")], now: 7_500_000),
            [.dial(address: "10.9.9.9", port: 41_161, discovered: true)])
        XCTAssertEqual(
            policy.status,
            .reconnecting(address: "10.9.9.9", discovered: true))

        // Establishment at B resets everything; B is the new baseline.
        _ = policy.sessionEstablished(
            address: "10.9.9.9", port: 41_161, now: 8_000_000)
        XCTAssertEqual(policy.status, .attached)
        XCTAssertEqual(policy.lastKnownAddress, "10.9.9.9")
        print("F-5 gate (host moved): same pkh at a new address → "
            + "immediate dial; foreign pkh inert; new baseline adopted")
    }

    // MARK: Leg 3 — same address: the redial threshold, and the
    // dead-session shortcut

    func testSameAddressSightingWaitsOutRedialThreshold() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = policy.wentSilent(now: 1_000_000)
        XCTAssertEqual(policy.tick(now: 4_000_000), [.beginScan])

        // The host is visible at the SAME address at 5 s of silence:
        // the network path works, evidence may still return — hold.
        XCTAssertEqual(
            policy.scanCompleted(
                sightings: [sighting("10.0.0.60")], now: 6_000_000),
            [])
        XCTAssertEqual(policy.status, .searching)
        // The remembered sighting graduates at silence onset + 8 s.
        XCTAssertEqual(
            policy.tick(now: 9_000_000),
            [.dial(address: "10.0.0.60", port: 41_161, discovered: true)])

        // The dead-session variant: once the liveness verdict landed
        // there is nothing left to save — a same-address sighting
        // dials at once.
        var closed = makePolicy()
        _ = closed.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        let onClose = closed.sessionClosed(now: 60_000_000)
        XCTAssertTrue(onClose.contains(.beginScan))
        XCTAssertTrue(onClose.contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)),
            "a dead session probes the last-known address immediately")
        _ = closed.dialFailed(now: 61_000_000)
        XCTAssertEqual(
            closed.scanCompleted(
                sightings: [sighting("10.0.0.60")], now: 62_000_000),
            [.dial(address: "10.0.0.60", port: 41_161, discovered: true)])
        print("F-5 gate (same address): standing session holds 8 s "
            + "before the redial; a closed one dials at sight")
    }

    // MARK: Leg 4 — backoff arithmetic: capped ladders, never hot

    func testBackoffLaddersCapAndNeverSpinHot() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        let actions = policy.sessionClosed(now: 10_000_000)
        XCTAssertTrue(actions.contains(.beginScan))
        XCTAssertTrue(actions.contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))

        // Fruitless scans: the gap doubles 1 → 2 → 4 → 8 → 15 (cap).
        var now: UInt64 = 11_000_000
        var expectedGap: Int64 = 1_000_000
        for _ in 0..<6 {
            XCTAssertEqual(
                policy.scanCompleted(sightings: [], now: now), [])
            let deadline = policy.nextDeadline
            XCTAssertNotNil(deadline)
            XCTAssertGreaterThan(deadline!, now,
                                 "deadlines live in the future — never hot")
            // The scan deadline is now + the current gap (the dial
            // ladder may pend sooner; find the scan by advancing).
            now = now &+ UInt64(expectedGap)
            let due = policy.tick(now: now)
            XCTAssertTrue(due.contains(.beginScan),
                          "the next pass comes due after the gap")
            expectedGap = min(expectedGap * 2, 15_000_000)
            // Answer any probe dial the tick fired so the dial ladder
            // stays out of the scan ladder's way.
            if due.contains(where: {
                if case .dial = $0 { return true }; return false
            }) {
                _ = policy.dialFailed(now: now)
            }
        }

        // Dial retries: 2 → 4 → 8 → 16 → 30 (cap) between attempts.
        var dialPolicy = makePolicy()
        _ = dialPolicy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = dialPolicy.sessionClosed(now: 100_000_000)   // probe fires
        var at: UInt64 = 100_000_000
        var expectedRetry: Int64 = 2_000_000
        for _ in 0..<5 {
            _ = dialPolicy.dialFailed(now: at)
            // One microsecond early: nothing.
            let early = dialPolicy.tick(
                now: at &+ UInt64(expectedRetry) &- 1)
            XCTAssertFalse(early.contains(where: {
                if case .dial = $0 { return true }; return false
            }), "no dial before the retry gap")
            at = at &+ UInt64(expectedRetry)
            let due = dialPolicy.tick(now: at)
            XCTAssertTrue(due.contains(
                .dial(address: "10.0.0.60", port: 41_161,
                      discovered: false)))
            expectedRetry = min(expectedRetry * 2, 30_000_000)
        }
        print("F-5 gate (backoff): scan gap 1→15 s, dial retry "
            + "2→30 s, every deadline strictly future")
    }

    // MARK: Leg 5 — client-side path change: grace, heal, escalate

    func testPathChangeGraceHealsOrEscalatesWithWaiver() {
        // Healed: the path change never froze the session — the grace
        // dissolves and the waiver stands down.
        var healed = makePolicy()
        _ = healed.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        XCTAssertEqual(healed.pathChanged(now: 1_000_000), [])
        XCTAssertEqual(healed.nextDeadline, 4_000_000,
                       "the migration grace is 3 s")
        XCTAssertEqual(healed.tick(now: 4_000_000), [])
        XCTAssertEqual(healed.status, .attached)
        XCTAssertNil(healed.nextDeadline)

        // Escalated: the path froze and stayed frozen through the
        // grace — scanning begins AT grace expiry (not the 3 s
        // silence threshold), and the same-address redial threshold
        // is waived: our own address moved, a fresh handshake is the
        // mechanism when migration didn't carry.
        var moved = makePolicy()
        _ = moved.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        XCTAssertEqual(moved.pathChanged(now: 1_000_000), [])
        XCTAssertEqual(moved.wentSilent(now: 1_500_000), [])
        XCTAssertEqual(moved.tick(now: 4_000_000), [.beginScan])
        XCTAssertEqual(
            moved.scanCompleted(
                sightings: [sighting("10.0.0.60")], now: 5_000_000),
            [.dial(address: "10.0.0.60", port: 41_161, discovered: true)],
            "the waiver dials the same address at sight")

        // Already-silent variant: a path change over a frozen session
        // escalates immediately — no grace to grant.
        var dark = makePolicy()
        _ = dark.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = dark.wentSilent(now: 1_000_000)
        XCTAssertEqual(dark.pathChanged(now: 2_000_000), [.beginScan])
        print("F-5 gate (path change): grace heals silently, "
            + "escalates over a frozen path, waives the same-address hold")
    }

    // MARK: Leg 6 — the manual Reconnect verb

    func testManualReconnectResetsLaddersAndActsNow() {
        var policy = makePolicy()
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: 0)
        _ = policy.sessionClosed(now: 10_000_000)
        // Grow both ladders.
        _ = policy.dialFailed(now: 11_000_000)
        _ = policy.dialFailed(now: 15_000_000)
        _ = policy.scanCompleted(sightings: [], now: 16_000_000)
        _ = policy.scanCompleted(sightings: [], now: 18_000_000)

        // The human reaches for Reconnect: everything fires NOW —
        // no waiting out a 30 s retry gap.
        let actions = policy.manualReconnect(now: 20_000_000)
        XCTAssertTrue(actions.contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))
        XCTAssertEqual(
            policy.status,
            .reconnecting(address: "10.0.0.60", discovered: false))
        // And the ladders are back at their floors: the NEXT failure
        // retries after the 2 s floor, not the grown gap.
        _ = policy.dialFailed(now: 21_000_000)
        XCTAssertTrue(policy.tick(now: 23_000_000).contains(
            .dial(address: "10.0.0.60", port: 41_161, discovered: false)))
        print("F-5 gate (manual): Reconnect acts immediately and "
            + "resets both ladders to their floors")
    }

    // MARK: Leg 7 — the pairing store keys by identity, not address

    func testPinnedHostStoreKeysByIdentityNotAddress() throws {
        let keys = NoiseKeyPair.generate()
        let pkh = LyteDiscovery.publicKeyHash(
            ofStaticPublicKey: keys.publicKey)

        var store = PinnedHostStore()
        XCTAssertTrue(store.pin(
            staticPublicKey: keys.publicKey, name: "pup",
            address: "10.0.0.60", port: 41_161,
            pairedAt: "2026-07-28T00:00:00Z"),
            "first pin is fresh")
        store.setStartHostAudioMuted(publicKeyHash: pkh, muted: false)
        store.setShareClipboard(publicKeyHash: pkh, share: true)

        // The host MOVED: re-pinning the same key at a new address is
        // a dial-hint refresh, never a new trust event — and the
        // per-host preferences survive verbatim.
        XCTAssertFalse(store.pin(
            staticPublicKey: keys.publicKey, name: "pup",
            address: "172.16.4.9", port: 41_161,
            pairedAt: "2026-07-28T01:00:00Z"),
            "same key = same host, not a fresh pin")
        XCTAssertEqual(store.hosts.count, 1,
                       "one identity, one entry — the address is a hint")
        let moved = try XCTUnwrap(store.host(publicKeyHash: pkh))
        XCTAssertEqual(moved.address, "172.16.4.9")
        XCTAssertEqual(moved.startHostAudioMuted, false,
                       "the start-audible opt-out survived the move")
        XCTAssertEqual(moved.shareClipboard, true,
                       "the clipboard consent survived the move")
        // Recognition is the identity lookup — the new address and
        // the stable NAME both resolve; the STALE address resolves to
        // nothing (it is a hint, not an identity, and it moved).
        XCTAssertNotNil(store.host(address: "172.16.4.9"))
        XCTAssertEqual(store.host(address: "pup")?.address, "172.16.4.9",
                       "the name still finds the host, wherever it lives")
        XCTAssertNil(store.host(address: "10.0.0.60"),
                     "the old address is nobody now")
        print("F-5 gate (pairing): identity-keyed store — a moved "
            + "host is the same host, preferences intact")
    }

    // MARK: Leg 8 — the banner's words, and the path trigger rule

    func testStatusLinesAndPathTriggerRule() {
        XCTAssertNil(RoamingStatusLine.line(for: .attached, hostName: "pup"))
        XCTAssertNil(RoamingStatusLine.line(for: .silent, hostName: "pup"),
                     "the FROZEN pill owns the blip tier")
        XCTAssertEqual(
            RoamingStatusLine.line(for: .searching, hostName: "pup"),
            "Connection lost — looking for pup…")
        XCTAssertEqual(
            RoamingStatusLine.line(
                for: .reconnecting(address: "10.9.9.9", discovered: true),
                hostName: "pup"),
            "pup found at 10.9.9.9 — reconnecting…")
        XCTAssertEqual(
            RoamingStatusLine.line(
                for: .reconnecting(address: "10.0.0.60", discovered: false),
                hostName: "pup"),
            "Reconnecting to pup at 10.0.0.60…")

        // The path watcher's trigger rule: the baseline observation
        // never notifies (the session was dialed on that path); any
        // later signature change does; sameness never does. Interface
        // order is canonicalized.
        typealias Sig = NetworkPathWatcher.Signature
        let wifi = Sig(isSatisfied: true, interfaceNames: ["en0"])
        let wifiReordered = Sig(isSatisfied: true, interfaceNames: ["en0"])
        let hotel = Sig(isSatisfied: true, interfaceNames: ["en1", "en0"])
        let hotelSorted = Sig(isSatisfied: true, interfaceNames: ["en0", "en1"])
        let dead = Sig(isSatisfied: false, interfaceNames: [])
        XCTAssertFalse(NetworkPathWatcher.shouldNotify(
            previous: nil, current: wifi))
        XCTAssertFalse(NetworkPathWatcher.shouldNotify(
            previous: wifi, current: wifiReordered))
        XCTAssertTrue(NetworkPathWatcher.shouldNotify(
            previous: wifi, current: hotel))
        XCTAssertTrue(NetworkPathWatcher.shouldNotify(
            previous: wifi, current: dead))
        XCTAssertEqual(hotel, hotelSorted,
                       "interface names are order-canonical")
        print("F-5 gate (surface): banner lines pinned; path trigger "
            + "= baseline silent, change loud")
    }

    // MARK: - The roam-capable host stand-in (the F-4 shape, with the
    // ONE F-5 difference: the Noise static is INJECTED — the same
    // identity must answer at "address B" that answered at "A")

    private final class RoamHostStandIn: NoiseHandshakeIO {
        let staticKeys: NoiseKeyPair
        let connectionId: ConnectionId
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var bulkSeq: UInt16 = 0
        var ctrlArq: ArqEndpoint<HostClock>
        var bulkArq: ArqEndpoint<HostClock>
        var negotiator: CapabilityNegotiator
        private var handshakeOutbox: [[UInt8]] = []

        var agreed: Capabilities?
        var bulkReceived: [BulkMessage] = []

        init(staticKeys: NoiseKeyPair, localCapabilities: Capabilities,
             seed: UInt64) {
            self.staticKeys = staticKeys
            var rng = SplitMix64(seed: seed)
            connectionId = ConnectionId.random(using: &rng)
            var config = ArqConfig()
            config.maxDatagramPayloadByteCount =
                WireBudget.maxConnectionIdTaggedPlaintextByteCount
            ctrlArq = ArqEndpoint(channel: .ctrl, config: config)
            bulkArq = ArqEndpoint(channel: .bulkTransfer, config: config)
            negotiator = CapabilityNegotiator(
                role: .host, local: localCapabilities)
        }

        func sendToHost(_ datagram: [UInt8]) throws {
            guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
                  envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake1
            else { return }
            var responder = try NoiseSession(
                role: .responder, staticKeys: staticKeys)
            _ = try responder.readMessage1(payload.dropFirst())
            let message2 = try responder.writeMessage2()
            transport = try responder.makeTransport()
            try ctrlArq.send(
                message: try XCTUnwrap(negotiator.start()).encode(),
                now: HostTimestamp(microseconds: 0)
            )
            let carriage = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: ctrlSeq),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0,
                extensions: [connectionId.wireExtension]
            )
            ctrlSeq &+= 1
            handshakeOutbox.append(try carriage.encode(
                payload: [CtrlMessageType.noiseHandshake2] + message2))
        }

        func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
            handshakeOutbox.isEmpty ? nil : handshakeOutbox.removeFirst()
        }

        private func sealed(
            channel: ChannelId, body: [UInt8], hostMicros: UInt64
        ) throws -> [UInt8] {
            let seq: UInt16
            if channel == .bulkTransfer {
                seq = bulkSeq; bulkSeq &+= 1
            } else {
                seq = ctrlSeq; ctrlSeq &+= 1
            }
            let envelope = Envelope(
                channel: channel,
                seq: ChannelSeq(rawValue: seq),
                frame: FrameNumber(rawValue: 0),
                timestamp: hostMicros,
                fec: 0,
                extensions: [connectionId.wireExtension]
            )
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            return try envelope.encode(payload: payload)
        }

        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                return
            }
            guard plaintext.first == CtrlMessageType.arqSegment
                    || plaintext.first == CtrlMessageType.arqAck
            else { return dispatchCtrlPlain(plaintext) }
            switch envelope.channel {
            case .bulkTransfer:
                for event in bulkArq.ingest(
                    payload: plaintext,
                    now: HostTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let message) = event {
                        bulkReceived.append(try BulkMessage.decode(message))
                    }
                }
            case .ctrl:
                for event in ctrlArq.ingest(
                    payload: plaintext,
                    now: HostTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let message) = event {
                        dispatchCtrlPlain(message)
                    }
                }
            default:
                break
            }
        }

        private func dispatchCtrlPlain(_ message: [UInt8]) {
            guard message.first == CtrlMessageType.capabilityDeclaration,
                  let declaration =
                    try? CapabilityDeclaration.decode(message)
            else { return }
            if case .agreed(let intersection) =
                try? negotiator.receive(declaration) {
                agreed = intersection
            }
        }

        func injectBulk(_ message: [UInt8], nowMicros: UInt64) throws {
            try bulkArq.send(
                message: message,
                now: HostTimestamp(microseconds: nowMicros))
        }

        func advance(nowMicros: UInt64) throws -> [[UInt8]] {
            guard transport != nil else { return [] }
            var out: [[UInt8]] = []
            let (ctrlPayloads, _) = ctrlArq.poll(
                now: HostTimestamp(microseconds: nowMicros))
            for body in ctrlPayloads {
                out.append(try sealed(
                    channel: .ctrl, body: body, hostMicros: nowMicros))
            }
            let (bulkPayloads, _) = bulkArq.poll(
                now: HostTimestamp(microseconds: nowMicros))
            for body in bulkPayloads {
                out.append(try sealed(
                    channel: .bulkTransfer, body: body,
                    hostMicros: nowMicros))
            }
            return out
        }
    }

    // MARK: - The client harness (real core, virtual clock, direct
    // pipes — plus the F-5 blackout: the clock advances, the wire
    // carries NOTHING either way)

    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private final class RoamHarness: @unchecked Sendable {
        let host: RoamHostStandIn
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        private var outbound: [[UInt8]] = []
        private var forwarded = 0
        let clock: VirtualClock

        var events: [LyteUdpSessionEvent] = []

        init(host: RoamHostStandIn, hostAddress: String,
             clock: VirtualClock,
             clientKeys: NoiseKeyPair) throws {
            self.host = host
            self.clock = clock
            let crypto = try NoiseTransportCrypto(
                hostAddress: hostAddress, hostPort: 41_161,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: clientKeys,
                attempts: 3, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            let clockRef = clock
            let sender = TransportSender(crypto: crypto, transmit: {
                [weak self] datagram in
                self?.outbound.append(datagram)
                return true
            })
            self.core = LyteUdpSessionCore(
                demux: demux,
                sender: sender,
                config: LyteUdpSessionCoreConfig(),
                now: { ClientTimestamp(microseconds: clockRef.value) },
                videoSink: HeadlessVideoSink(),
                onEvent: { [weak self] event in
                    self?.events.append(event)
                })
        }

        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: tMicros)
            if case .accepted = outcome {
                core.handleDatagram(outcome, arrivalMicroseconds: tMicros)
            }
        }

        /// Direct-pipe beats 2 ms apart until both ends quiesce.
        func settle(t: inout UInt64) throws {
            var idle = 0
            while idle < 3 {
                t += 2_000
                clock.value = t
                let before = (forwarded, host.bulkReceived.count,
                              events.count)
                core.tick(now: ClientTimestamp(microseconds: t))
                while forwarded < outbound.count {
                    try host.absorb(outbound[forwarded], nowMicros: t)
                    forwarded += 1
                }
                for datagram in try host.advance(nowMicros: t) {
                    absorb(datagram, tMicros: t)
                }
                core.tick(now: ClientTimestamp(microseconds: t))
                while forwarded < outbound.count {
                    try host.absorb(outbound[forwarded], nowMicros: t)
                    forwarded += 1
                }
                idle = (forwarded, host.bulkReceived.count,
                        events.count) == before ? idle + 1 : 0
            }
        }

        /// The F-5 blackout: the core lives through `duration` of
        /// total wire silence — 100 ms machine beats, nothing
        /// forwarded either way (retransmissions pile up unheard).
        func blackout(t: inout UInt64, duration: UInt64) {
            let end = t + duration
            while t < end {
                t += 100_000
                clock.value = t
                core.tick(now: ClientTimestamp(microseconds: t))
            }
        }
    }

    // MARK: - The scripted receiving end (a REAL BulkReceiveEngine,
    // the F-4 harness verbatim)

    private final class ScriptedReceiver {
        var engine: BulkReceiveEngine
        var store: [UInt64: [UInt8]] = [:]
        var outbox: [BulkMessage] = []
        var offer: BulkOffer?

        init(window: Int, resumeBook: [BulkResumeState] = []) {
            engine = BulkReceiveEngine(
                config: BulkTransferConfig(receiveWindowChunks: window),
                resumeBook: resumeBook)
        }

        func absorb(_ message: BulkMessage) throws {
            try pump(engine.ingest(message))
        }

        func pump(_ actions: [BulkReceiveEngine.Action]) throws {
            for action in actions {
                switch action {
                case .offered(let incoming, _):
                    offer = incoming
                    try pump(engine.accept())
                case .emit(let message):
                    outbox.append(message)
                case .store(let index, let data):
                    store[index] = data
                    try pump(engine.chunkStored(index: index))
                case .verify:
                    try pump(engine.verificationResult(
                        digest: assembledDigest()))
                case .completed, .aborted, .violated:
                    break
                }
            }
        }

        func assembledDigest() -> [UInt8] {
            guard let offer else { return [] }
            var assembled: [UInt8] = []
            for index in 0..<offer.chunkCount {
                assembled += store[index] ?? []
            }
            return Sha256.digest(assembled)
        }
    }

    private final class RecordingReader: BulkChunkReading, @unchecked Sendable {
        private let payload: [UInt8]
        private let lock = NSLock()
        private var recordedOffsets: [UInt64] = []

        init(payload: [UInt8]) { self.payload = payload }

        var readOffsets: [UInt64] {
            lock.lock(); defer { lock.unlock() }
            return recordedOffsets
        }

        func read(
            offset: UInt64, byteCount: Int,
            completion: @escaping @Sendable (Result<[UInt8], Error>) -> Void
        ) {
            lock.lock()
            recordedOffsets.append(offset)
            lock.unlock()
            let start = Int(offset)
            guard start + byteCount <= payload.count else {
                completion(.failure(BulkChunkReadError.shortRead(
                    offset: offset, wanted: byteCount,
                    got: max(0, payload.count - start))))
                return
            }
            completion(.success(Array(payload[start..<start + byteCount])))
        }

        func close() {}
    }

    private final class PrepareCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        func bump() { lock.lock(); stored += 1; lock.unlock() }
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private final class ReaderBook: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [RecordingReader] = []
        func note(_ reader: RecordingReader) {
            lock.lock(); made.append(reader); lock.unlock()
        }
        var all: [RecordingReader] {
            lock.lock(); defer { lock.unlock() }
            return made
        }
    }

    /// Bridges the stand-in's recorded chan-8 messages into the real
    /// receive engine and its answers back through the harness —
    /// `cap` bounds how many sender messages the receiver ever SEES
    /// (in-order carriage: the blackout leaves it a prefix).
    private func pumpBulk(
        harness: RoamHarness, receiver: ScriptedReceiver,
        coordinator: BulkSendCoordinator,
        seen: inout Int, cap: Int? = nil, t: inout UInt64
    ) throws {
        var progressed = true
        while progressed {
            progressed = false
            try harness.settle(t: &t)
            while seen < harness.host.bulkReceived.count {
                let message = harness.host.bulkReceived[seen]
                seen += 1
                progressed = true
                if let cap, seen > cap { continue }   // dark
                try receiver.absorb(message)
            }
            while !receiver.outbox.isEmpty {
                try harness.host.injectBulk(
                    receiver.outbox.removeFirst().encode(), nowMicros: t)
                progressed = true
            }
            // The coordinator's reactions (credit-gated reads → more
            // chunk sends) queue on the core — the NEXT pass's settle
            // carries them, so an ingest IS progress.
            var ingested = 0
            for event in harness.events {
                if case .bulkMessageReceived(let message) = event {
                    coordinator.ingest(message)
                    ingested += 1
                }
            }
            if ingested > 0 { progressed = true }
            harness.events.removeAll {
                if case .bulkMessageReceived = $0 { return true }
                return false
            }
        }
    }

    // MARK: Leg 9 — end to end: blackout at A, liveness close,
    // rediscovery at B, same-id re-offer, sha-exact resume

    func testGateEndToEndRoamResumesBulkTransferAtNewAddress() throws {
        var rng = SplitMix64(seed: 0xF5_09)
        let payload = (0..<32_768).map { _ in
            UInt8(truncatingIfNeeded: rng.next())
        }
        let hostKeys = NoiseKeyPair.generate()
        let clientKeys = NoiseKeyPair.generate()
        let pkh = LyteDiscovery.publicKeyHash(
            ofStaticPublicKey: hostKeys.publicKey)

        // The coordinator with synchronous seams (the F-4 rig): one
        // 32 KiB fixture in 4 KiB chunks.
        let readers = ReaderBook()
        let prepared = PrepareCounter()
        let coordinator = BulkSendCoordinator(
            chunkByteCount: 4_096,
            prepare: { url, transferId, chunk in
                prepared.bump()
                return try BulkOffer(
                    transferId: transferId,
                    totalByteCount: UInt64(payload.count),
                    chunkByteCount: chunk,
                    sha256: Sha256.digest(payload),
                    name: url.lastPathComponent)
            },
            makeReader: { _ in
                let reader = RecordingReader(payload: payload)
                readers.note(reader)
                return reader
            },
            runInBackground: { work in work() },
            mintId: { 0xF5_00_0001 })

        // SESSION 1 — "address A". The full client core over the
        // direct pipe; capability agreement; the drop begins.
        let clock = VirtualClock()
        var t: UInt64 = 1_000
        clock.value = t
        let host1 = RoamHostStandIn(
            staticKeys: hostKeys,
            localCapabilities: .wireDefault.declaringBulkTransfer(),
            seed: 0xF5_11)
        let harness1 = try RoamHarness(
            host: host1, hostAddress: "10.0.0.60",
            clock: clock, clientKeys: clientKeys)
        try harness1.core.open(now: ClientTimestamp(microseconds: t))
        try harness1.settle(t: &t)
        XCTAssertEqual(host1.agreed?.bulkTransfer, true)
        XCTAssertTrue(harness1.core.bulkTransferNegotiated)

        var policy = RoamingPolicy(
            targetPublicKeyHash: pkh, address: "10.0.0.60", port: 41_161)
        _ = policy.sessionEstablished(
            address: "10.0.0.60", port: 41_161, now: t)

        let core1 = harness1.core!
        coordinator.sessionReady(negotiated: true, send: { bytes in
            try? core1.sendBulkMessage(bytes)
        })
        XCTAssertEqual(
            coordinator.drop(urls: [URL(fileURLWithPath: "/tmp/roam.bin")]),
            .accepted(count: 1))

        // The receiver sees the offer and exactly TWO chunks, then
        // the world goes dark (the host is being carried to a hotel).
        let receiver1 = ScriptedReceiver(window: 4)
        var seen1 = 0
        try pumpBulk(
            harness: harness1, receiver: receiver1,
            coordinator: coordinator, seen: &seen1, cap: 3, t: &t)
        XCTAssertEqual(receiver1.store.count, 2,
                       "the blackout let exactly two chunks land")
        let firstOffer = try XCTUnwrap(receiver1.offer)
        let persisted = try XCTUnwrap(receiver1.engine.resumeState)
        XCTAssertEqual(persisted.possession.contiguousCount, 2)

        // THE BLACKOUT, through the REAL core in virtual time: the
        // 2.5 s detector freezes the session (the policy's silence
        // clock starts), 3 s later the quiet scan begins (nothing to
        // sight yet), and the 30 s liveness verdict closes it.
        harness1.events.removeAll()
        harness1.blackout(t: &t, duration: 3_000_000)
        XCTAssertTrue(harness1.events.contains {
            if case .stateChanged(.frozen) = $0 { return true }
            return false
        }, "2.5 s of wire silence derives FROZEN")
        XCTAssertEqual(policy.wentSilent(now: t), [])
        let scanDeadline = try XCTUnwrap(policy.nextDeadline)
        harness1.blackout(t: &t, duration: 4_000_000)
        XCTAssertGreaterThanOrEqual(t, scanDeadline)
        XCTAssertEqual(policy.tick(now: t), [.beginScan])
        XCTAssertEqual(policy.status, .searching)
        XCTAssertEqual(
            policy.scanCompleted(sightings: [], now: t), [],
            "the host hasn't re-advertised yet — keep looking")

        harness1.blackout(t: &t, duration: 26_000_000)
        let closed = harness1.events.contains {
            if case .closed(.livenessTimeout) = $0 { return true }
            return false
        }
        XCTAssertTrue(closed, "30 s of nothing draws the liveness close")
        coordinator.sessionEnded()
        XCTAssertEqual(coordinator.snapshot().phase, .awaitingReconnect)
        var onClose = policy.sessionClosed(now: t)
        // The probe dial at the last-known address draws silence —
        // the host isn't there anymore.
        if onClose.contains(where: {
            if case .dial = $0 { return true }; return false
        }) {
            onClose = policy.dialFailed(now: t + 1_500_000)
        }
        _ = onClose

        // REDISCOVERY: the same identity appears at address B — the
        // policy dials it at once.
        let sightingB = RoamingSighting(
            publicKeyHash: pkh, address: "10.9.9.9", port: 41_161)
        let redial = policy.scanCompleted(
            sightings: [sightingB], now: t + 2_000_000)
        XCTAssertEqual(
            redial,
            [.dial(address: "10.9.9.9", port: 41_161, discovered: true)])

        // SESSION 2 — "address B": the SAME pinned static answers the
        // fresh 1-RTT (same pairing, no re-PIN), a brand-new core and
        // wire world.
        t += 2_000_000
        clock.value = t
        let host2 = RoamHostStandIn(
            staticKeys: hostKeys,
            localCapabilities: .wireDefault.declaringBulkTransfer(),
            seed: 0xF5_12)
        let harness2 = try RoamHarness(
            host: host2, hostAddress: "10.9.9.9",
            clock: clock, clientKeys: clientKeys)
        try harness2.core.open(now: ClientTimestamp(microseconds: t))
        try harness2.settle(t: &t)
        XCTAssertTrue(harness2.core.bulkTransferNegotiated)
        _ = policy.sessionEstablished(
            address: "10.9.9.9", port: 41_161, now: t)
        XCTAssertEqual(policy.status, .attached)
        XCTAssertEqual(policy.lastKnownAddress, "10.9.9.9")

        // The re-attach re-offers the SAME id (the F-4 resume path —
        // roaming rides it unchanged), and the possession-seeded
        // receiver resumes from the gap.
        let core2 = harness2.core!
        coordinator.sessionReady(negotiated: true, send: { bytes in
            try? core2.sendBulkMessage(bytes)
        })
        let receiver2 = ScriptedReceiver(
            window: 4, resumeBook: [persisted])
        for index in 0..<persisted.possession.contiguousCount {
            receiver2.store[index] = Array(
                payload[Int(index) * 4_096..<(Int(index) + 1) * 4_096])
        }
        var seen2 = 0
        try pumpBulk(
            harness: harness2, receiver: receiver2,
            coordinator: coordinator, seen: &seen2, t: &t)

        guard case .offer(let secondOffer) = try XCTUnwrap(
            host2.bulkReceived.first) else {
            return XCTFail("the reconnect's first bulk word must be "
                + "the re-offer")
        }
        XCTAssertEqual(secondOffer.transferId, firstOffer.transferId,
                       "the SAME transfer id — the resume identity")
        XCTAssertEqual(prepared.count, 1,
                       "no re-hash — the prepared offer re-offered verbatim")
        XCTAssertEqual(receiver2.assembledDigest(), secondOffer.sha256,
                       "the roamed transfer finished sha-exact")
        let reader2 = try XCTUnwrap(readers.all.last)
        XCTAssertEqual(reader2.readOffsets.map { $0 / 4_096 }.sorted(),
                       [2, 3, 4, 5, 6, 7],
                       "only the GAP was read after the roam")
        XCTAssertTrue(coordinator.snapshot().isIdle)
        print("F-5 gate (end to end): blackout at A → FROZEN → "
            + "liveness close → sighting at B → dial → same-id "
            + "re-offer → sha-exact resume, chunks 2…7 only")
    }
}
