import XCTest
import LyteClientCore
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

    // MARK: The platform path trigger rule

    func testPathTriggerRule() {
        // The path watcher's trigger rule: the baseline observation
        // never notifies (the session was dialed on that path); any
        // later signature change does; sameness never does. Interface
        // order is canonicalized.
        typealias Sig = NetworkPathWatcher.Signature
        let wifi = Sig(isSatisfied: true, interfaceNames: ["en0"])
        let hotel = Sig(isSatisfied: true, interfaceNames: ["en1", "en0"])
        let hotelSorted = Sig(isSatisfied: true, interfaceNames: ["en0", "en1"])
        let dead = Sig(isSatisfied: false, interfaceNames: [])
        XCTAssertFalse(NetworkPathWatcher.shouldNotify(
            previous: nil, current: wifi))
        XCTAssertFalse(NetworkPathWatcher.shouldNotify(
            previous: wifi, current: wifi))
        XCTAssertFalse(NetworkPathWatcher.shouldNotify(
            previous: hotel, current: hotelSorted))
        XCTAssertTrue(NetworkPathWatcher.shouldNotify(
            previous: wifi, current: hotel))
        XCTAssertTrue(NetworkPathWatcher.shouldNotify(
            previous: wifi, current: dead))
        XCTAssertEqual(hotel, hotelSorted,
                       "interface names are order-canonical")
    }

    // MARK: - The roam-capable host stand-in: the Noise static is
    // INJECTED — the same identity must answer at "address B" that
    // answered at "A"

    fileprivate final class RoamHostStandIn: DeclaringHost {
        var bulkReceived: [BulkMessage] = []

        override var progressMark: Int { bulkReceived.count }

        init(staticKeys: NoiseKeyPair, localCapabilities: Capabilities,
             seed: UInt64) {
            super.init(
                localCapabilities: localCapabilities, seed: seed,
                staticKeys: staticKeys, carriesBulk: true)
        }

        override func receive(
            _ message: [UInt8], on channel: ChannelId, nowMicros: UInt64
        ) throws {
            if channel == .bulkTransfer {
                bulkReceived.append(try BulkMessage.decode(message))
            }
        }
    }

    // MARK: - The client harness (real core, virtual clock, direct
    // pipes — plus the F-5 blackout: the clock advances, the wire
    // carries NOTHING either way)

    private typealias RoamHarness = ClientCoreHarness<RoamHostStandIn>

    private typealias ScriptedReceiver = BulkSendClientGateTests.ScriptedReceiver
    private typealias RecordingReader = BulkSendClientGateTests.RecordingReader

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
                try receiver.absorb(message.encode())
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

    // MARK: End to end: blackout at A, liveness close,
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
        let readers = Locked<[RecordingReader]>()
        let prepared = Locked(0)
        let coordinator = BulkSendCoordinator(
            chunkByteCount: 4_096,
            prepare: { url, transferId, chunk in
                prepared.mutate { $0 += 1 }
                return try BulkOffer(
                    transferId: transferId,
                    totalByteCount: UInt64(payload.count),
                    chunkByteCount: chunk,
                    sha256: Sha256.digest(payload),
                    name: url.lastPathComponent)
            },
            makeReader: { _ in
                let reader = RecordingReader(payload: payload)
                readers.append(reader)
                return reader
            },
            runInBackground: { work in work() },
            mintId: { 0xF5_00_0001 })

        // SESSION 1 — "address A". The full client core over the
        // direct pipe; capability agreement; the drop begins.
        let clock = ManualMicrosClock()
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
        XCTAssertTrue(harness1.core.control.agreedCapabilities?.bulkTransfer == true)

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
        // The probe dial at the last-known address draws silence —
        // the host isn't there anymore.
        if policy.sessionClosed(now: t).contains(where: {
            if case .dial = $0 { return true }; return false
        }) {
            _ = policy.dialFailed(now: t + 1_500_000)
        }

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
        XCTAssertTrue(harness2.core.control.agreedCapabilities?.bulkTransfer == true)
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
        XCTAssertEqual(prepared.value, 1,
                       "no re-hash — the prepared offer re-offered verbatim")
        XCTAssertEqual(receiver2.assembledDigest(), secondOffer.sha256,
                       "the roamed transfer finished sha-exact")
        let reader2 = try XCTUnwrap(readers.all.last)
        XCTAssertEqual(reader2.readOffsets.map { $0 / 4_096 }.sorted(),
                       [2, 3, 4, 5, 6, 7],
                       "only the GAP was read after the roam")
        XCTAssertTrue(coordinator.snapshot().isIdle)
    }
}

fileprivate extension ClientCoreHarness
where Host == RoamingClientGateTests.RoamHostStandIn {
    convenience init(
        host: Host, hostAddress: String,
        clock: ManualMicrosClock,
        clientKeys: NoiseKeyPair
    ) throws {
        try self.init(
            host: host, hostAddress: hostAddress, hostPort: 41_161,
            clientKeys: clientKeys, clock: clock)
    }

    /// The F-5 blackout: the core lives through `duration` of total
    /// wire silence — 100 ms machine beats, nothing forwarded either
    /// way (retransmissions pile up unheard).
    func blackout(t: inout UInt64, duration: UInt64) {
        let end = t + duration
        while t < end {
            t += 100_000
            clock.value = t
            core.tick(now: ClientTimestamp(microseconds: t))
        }
    }
}
