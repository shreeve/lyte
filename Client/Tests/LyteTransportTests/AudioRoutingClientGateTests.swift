import XCTest
import LyteClientTestKit
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// Host audio routing (key 9) through the real core against a scripted host
// in virtual time: the host's starting 0x19 is the confirmed posture, a
// requested flip round-trips 0x18 → 0x19, a failed flip reports the old
// posture, and the session-start preference sends exactly one 0x18 when it
// differs from the host's default (a fresh config asks for hostMuted; an
// explicit "start audible" suppresses the ask). Against a host without key
// 9 the ask is refused before a byte leaves, a hostile 0x19 drops loud,
// and a role-confused 0x18 drops loud.

final class AudioRoutingClientGateTests: XCTestCase {

    // MARK: - The scripted host

    /// A key-9-capable host stand-in: Noise responder, host-clock ARQ,
    /// capability negotiator (declaration = first reliable word), and
    /// HS-18's routing rules — the starting 0x19 at agreement, one
    /// 0x19 per applied flip, a scriptable FAILED flip that re-reports
    /// the old posture. No video/beacons: this gate is about the
    /// ordered CTRL stream.
    fileprivate final class RoutingHostStandIn: ScriptedHost {
        var peer: SealedCtrlPeer<HostClock>
        var handshakeOutbox: [[UInt8]] = []
        let localCapabilities: Capabilities

        /// The host's shell posture (--host-audio seeds it live).
        var posture: HostAudioRoutingMode = .hostAudible
        /// Scripted failure: a 0x18 is "attempted", the flip fails,
        /// and the 0x19 answer reports the OLD posture (HS-18's rule).
        var flipFails = false

        // Evidence.
        var agreed: Capabilities?
        var requestsReceived: [[UInt8]] = []
        var receivedReliableTypes: [UInt8] = []
        var statusesSent: [HostAudioRoutingMode] = []

        var progressMark: Int { receivedReliableTypes.count }

        init(localCapabilities: Capabilities) {
            var rng = SplitMix64(seed: 0xC1_13)
            peer = SealedCtrlPeer(
                connectionId: ConnectionId.random(using: &rng))
            peer.openChannels = [.ctrl]
            self.localCapabilities = localCapabilities
        }

        /// HS-11's rule, load-bearing here: the host's declaration is
        /// the FIRST reliable word at establishment — BEFORE any client
        /// message can be consumed. Queuing it lazily would let the
        /// agreement's 0x19 jump ahead of it on the ordered stream, and
        /// the client would (rightly) drop that loud.
        func didEstablish() throws {
            try declare(localCapabilities)
        }

        /// One client datagram: unseal → the ARQ ingest → HS-18's
        /// dispatch. Feedback/echoes/IDRs are not this gate's business.
        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            guard case .reliable(_, _, let events) =
                try peer.absorb(bytes, nowMicros: nowMicros)
            else { return }
            for case .message(_, let message) in events {
                receivedReliableTypes.append(message.first ?? 0)
                try dispatchReliable(message, nowMicros: nowMicros)
            }
        }

        private func dispatchReliable(
            _ message: [UInt8], nowMicros: UInt64
        ) throws {
            switch message.first {
            case CtrlMessageType.capabilityDeclaration:
                guard let declaration =
                    try? CapabilityDeclaration.decode(message)
                else { return XCTFail("malformed client declaration") }
                if case .agreed(let intersection) =
                    try peer.negotiator!.receive(declaration) {
                    agreed = intersection
                    // HS-18: the starting posture rides a 0x19 at
                    // capability agreement — negotiated sessions only.
                    if intersection.hostAudioRouting {
                        statusesSent.append(posture)
                        try injectReliable(
                            AudioRoutingStatus(mode: posture).encode(),
                            nowMicros: nowMicros)
                    }
                }
            case CtrlMessageType.audioRoutingRequest:
                requestsReceived.append(message)
                guard agreed?.hostAudioRouting == true else {
                    return   // the host's rule-3 drop, silent here
                }
                let request = try AudioRoutingRequest.decode(message)
                if !flipFails { posture = request.mode }
                // Applied (or failed — old posture) → one 0x19.
                statusesSent.append(posture)
                try injectReliable(
                    AudioRoutingStatus(mode: posture).encode(),
                    nowMicros: nowMicros)
            default:
                break
            }
        }
    }

    // MARK: - The client harness

    /// The REAL production core minus the socket, on a virtual clock,
    /// piped directly to the stand-in (this gate needs determinism,
    /// not impairment — CL-8's gate owns the storm legs).
    private typealias Harness = ClientCoreHarness<RoutingHostStandIn>

    // MARK: The negotiated flip, end to end

    func testGateNegotiatedFlipRoundTripAndFailedFlipReportsOldPosture() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        // The NEUTRAL posture, explicit since CL-18 flipped the
        // config default to hostMuted: this leg is about the flip
        // round-trip, so the session-start ask stays out of the way.
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // Mutual key-9 declaration survived intersection, both views.
        XCTAssertEqual(host.agreed?.hostAudioRouting, true,
                       "the host must see key 9 in the client's 0x0F")
        XCTAssertEqual(
            harness.core.agreedCapabilities?.hostAudioRouting, true)
        XCTAssertTrue(harness.core.hostAudioRoutingNegotiated)

        // The starting 0x19 (the host's default) is the confirmed
        // posture — no ask left (no desired posture configured).
        XCTAssertEqual(harness.postureEvents, [.hostAudible])
        XCTAssertEqual(harness.core.control.hostAudioRoutingPosture, .hostAudible)
        XCTAssertEqual(host.requestsReceived, [],
                       "no desired posture → no session-start 0x18")

        // The flip: ask hostMuted → the host consumes exactly
        // [0x18, 0x02] → answers 0x19 → posture + callback.
        try harness.core.requestHostAudioRouting(
            .hostMuted, now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.requestsReceived, [[0x18, 0x02]],
                       "the ask must ride the ordered stream byte-exact")
        XCTAssertEqual(harness.postureEvents, [.hostAudible, .hostMuted])
        XCTAssertEqual(harness.core.control.hostAudioRoutingPosture, .hostMuted)

        // The FAILED flip: the host attempts, fails, and re-reports
        // the OLD posture — the client renders truth (the UI toggle
        // snaps back), never the ask.
        host.flipFails = true
        try harness.core.requestHostAudioRouting(
            .hostAudible, now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.requestsReceived.count, 2)
        XCTAssertEqual(harness.postureEvents,
                       [.hostAudible, .hostMuted, .hostMuted],
                       "a failed flip answers with the old posture")
        XCTAssertEqual(harness.core.control.hostAudioRoutingPosture, .hostMuted)

        let counters = harness.core.snapshotCounters()
        XCTAssertEqual(counters.audioRoutingRequestsSent, 2)
        XCTAssertEqual(counters.audioRoutingStatusesReceived, 3)
        XCTAssertEqual(counters.audioRoutingDropsLoud, 0)
        XCTAssertEqual(counters.unknownReliableTypes, 0)
        XCTAssertEqual(counters.malformedReliableMessages, 0)

    }

    func testGateStreamOffNeedsKeyFourteenAndRoundTripsWhenAgreed() throws {
        // Leg A: a key-9-only host (today's build) — the routing
        // dialect works, but streamOff (key 14, mute-at-source) is
        // refused TYPED, before a byte leaves: 0x04 against a legacy
        // decoder would be a protocol break, so it never travels.
        let legacy = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let h1 = try Harness(host: legacy, coreConfig: config)
        var t: UInt64 = 1_000
        h1.clock.value = t
        try h1.core.open(now: ClientTimestamp(microseconds: t))
        try h1.settle(t: &t)
        XCTAssertTrue(h1.core.hostAudioRoutingNegotiated)
        XCTAssertEqual(h1.core.agreedCapabilities?.audioStreamOff, false)
        XCTAssertThrowsError(try h1.core.requestHostAudioRouting(
            .streamOff, now: ClientTimestamp(microseconds: t))
        ) { error in
            XCTAssertEqual(
                error as? AudioRoutingAskError, .streamOffNotNegotiated)
        }
        try h1.settle(t: &t)
        XCTAssertEqual(legacy.requestsReceived, [],
                       "no [0x18 0x04] may ever reach a key-9-only host")

        // Leg B: a key-9+14 host — streamOff round-trips byte-exact
        // ([0x18 0x04] → 0x19) and the posture lands.
        let modern = RoutingHostStandIn(
            localCapabilities: .wireDefault
                .declaringHostAudioRouting().declaringAudioStreamOff())
        let h2 = try Harness(host: modern, coreConfig: config)
        var t2: UInt64 = 1_000
        h2.clock.value = t2
        try h2.core.open(now: ClientTimestamp(microseconds: t2))
        try h2.settle(t: &t2)
        XCTAssertEqual(h2.core.agreedCapabilities?.audioStreamOff, true)
        try h2.core.requestHostAudioRouting(
            .streamOff, now: ClientTimestamp(microseconds: t2))
        try h2.settle(t: &t2)
        XCTAssertEqual(modern.requestsReceived, [[0x18, 0x04]],
                       "streamOff must ride byte-exact as 0x04")
        XCTAssertEqual(h2.core.control.hostAudioRoutingPosture, .streamOff)

    }

    // MARK: The session-start posture parameter

    func testGateSessionStartPostureAsksExactlyOnceWhenDiffering() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = .hostMuted
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // The host's default (audible) differed from the desire
        // (muted): exactly ONE 0x18 left right after the starting
        // 0x19, the host applied it, and the confirmed posture is the
        // desire — the whole negotiation, no shell involvement.
        XCTAssertEqual(host.requestsReceived, [[0x18, 0x02]],
                       "exactly one session-start ask")
        XCTAssertEqual(harness.postureEvents, [.hostAudible, .hostMuted])
        XCTAssertEqual(harness.core.control.hostAudioRoutingPosture, .hostMuted)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingRequestsSent, 1)

        // Later statuses never re-trigger the start ask (the host
        // flips back on its own — say its shell did): posture follows,
        // no new 0x18.
        host.posture = .hostAudible
        try host.injectReliable(
            AudioRoutingStatus(mode: .hostAudible).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.core.control.hostAudioRoutingPosture, .hostAudible)
        XCTAssertEqual(host.requestsReceived.count, 1,
                       "the start ask fires at most once per session")
    }

    func testGateSessionStartPostureStaysQuietWhenMatching() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        host.posture = .hostMuted   // --host-audio muted on the shell
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = .hostMuted
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // Desire == the host's default: nothing to say.
        XCTAssertEqual(host.requestsReceived, [])
        XCTAssertEqual(harness.core.control.hostAudioRoutingPosture, .hostMuted)
        XCTAssertEqual(harness.postureEvents, [.hostMuted])
    }

    // MARK: The rule-3 gate against the unnegotiated

    func testGateUnnegotiatedAskSuppressedAndHostileStatusDropsLoud() throws {
        // A v1 host: declares, but never key 9 (an older host build).
        let host = RoutingHostStandIn(localCapabilities: .wireDefault)
        var config = LyteUdpSessionCoreConfig()
        // Even a configured desire must stay quiet without the key.
        config.desiredHostAudioRouting = .hostMuted
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // Intersection dropped key 9; the strip's button never exists.
        XCTAssertEqual(host.agreed?.hostAudioRouting, false)
        XCTAssertFalse(harness.core.hostAudioRoutingNegotiated)
        XCTAssertNil(harness.core.control.hostAudioRoutingPosture)
        XCTAssertEqual(harness.postureEvents, [])

        // The ask is refused BEFORE a byte leaves.
        XCTAssertThrowsError(try harness.core.requestHostAudioRouting(
            .hostMuted, now: ClientTimestamp(microseconds: t))
        ) { error in
            XCTAssertEqual(
                error as? AudioRoutingAskError, .notNegotiated)
        }
        try harness.settle(t: &t)
        XCTAssertEqual(host.requestsReceived, [])
        XCTAssertFalse(
            host.receivedReliableTypes
                .contains(CtrlMessageType.audioRoutingRequest),
            "no 0x18 may ever reach an unnegotiated host")

        // A hostile/buggy 0x19 from the no-key-9 host: dropped loud,
        // no posture, no event.
        try host.injectReliable(
            AudioRoutingStatus(mode: .hostMuted).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertNil(harness.core.control.hostAudioRoutingPosture)
        XCTAssertEqual(harness.postureEvents, [])
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingDropsLoud, 1)

        // Role confusion: a 0x18 arriving AT the client — same loud
        // drop (the host's mirror rule).
        try host.injectReliable(
            AudioRoutingRequest(mode: .hostMuted).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingDropsLoud, 2)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingRequestsSent, 0)

    }

    // MARK: The per-host default plumbing

    func testPinnedHostPreferenceSurvivesDecodeRepairAndRefusesUnknown() throws {
        // A pre-CL-13 file (no startHostAudioMuted key) decodes
        // unchanged: the preference reads nil, meaning "host default".
        let keyHex = String(repeating: "ab", count: 32)
        let legacy = Data("""
        {"hosts":{"deadbeef":{"name":"pup","address":"10.0.0.249",\
        "port":41000,"staticPublicKeyHex":"\(keyHex)",\
        "pairedAt":"2026-07-21T09:00:00Z"}}}
        """.utf8)
        let store = try JSONDecoder().decode(PinnedHostStore.self, from: legacy)
        XCTAssertNil(store.hosts["deadbeef"]?.startHostAudioMuted)

        // Round trip through the real save/load path, preference set.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl13-pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var live = PinnedHostStore()
        let staticKey = (0..<32).map { UInt8($0) }
        live.pin(staticPublicKey: staticKey, name: "pup",
                 address: "10.0.0.249", port: 41_000,
                 pairedAt: "2026-07-22T15:00:00Z")
        let pkh = try XCTUnwrap(live.hosts.keys.first)
        XCTAssertTrue(live.setStartHostAudioMuted(
            publicKeyHash: pkh, muted: true))
        try live.save(to: url)
        let reloaded = PinnedHostStore.load(from: url)
        XCTAssertEqual(
            reloaded.host(publicKeyHash: pkh)?.startHostAudioMuted, true)

        // A re-pair refreshes dial hints WITHOUT resetting preferences.
        var repaired = reloaded
        repaired.pin(staticPublicKey: staticKey, name: "pup",
                     address: "10.0.0.77", port: 41_121,
                     pairedAt: "2026-07-23T09:00:00Z")
        XCTAssertEqual(repaired.hosts[pkh]?.address, "10.0.0.77")
        XCTAssertEqual(repaired.hosts[pkh]?.startHostAudioMuted, true,
                       "a re-pair is a trust event, not a settings reset")

        // The setter refuses hashes it has never pinned.
        XCTAssertFalse(repaired.setStartHostAudioMuted(
            publicKeyHash: "0000", muted: true))
    }

    // MARK: CL-18: the flipped default posture

    func testGateFreshConfigStartsHostMutedByDefault() throws {
        // The flip itself, pinned at the source: a FRESH config —
        // nothing set anywhere — desires hostMuted.
        XCTAssertEqual(
            LyteUdpSessionCoreConfig().desiredHostAudioRouting, .hostMuted)

        // And in vivo: a new session against a key-9 host whose own
        // default is audible sends exactly one [0x18 0x02] — the
        // Sunshine/Moonlight posture with zero configuration. (The
        // no-key-9 case stays pinned by leg 5: the ask only ever
        // fires on the host's first 0x19, which such a host never
        // owes — unnegotiated hosts keep playing, unchanged.)
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        let harness = try Harness(host: host)   // the DEFAULT config
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        XCTAssertEqual(host.requestsReceived, [[0x18, 0x02]],
                       "an unconfigured session asks for hostMuted now")
        XCTAssertEqual(harness.postureEvents, [.hostAudible, .hostMuted])
        XCTAssertEqual(harness.core.control.hostAudioRoutingPosture, .hostMuted)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingRequestsSent, 1)

    }

    func testGateStoredAudibleOptOutWorksBothDirections() throws {
        // The stored "start audible" opt-out (explicit false) against
        // an AUDIBLE host: postures already match — zero 0x18.
        let audibleHost = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = PinnedHost(
            name: "pup", address: "10.0.0.249", port: 41_000,
            staticPublicKeyHex: String(repeating: "ab", count: 32),
            pairedAt: "2026-07-27T09:00:00Z",
            startHostAudioMuted: false
        ).sessionStartHostAudioRouting
        XCTAssertEqual(config.desiredHostAudioRouting, .hostAudible)

        let quiet = try Harness(host: audibleHost, coreConfig: config)
        var t: UInt64 = 1_000
        quiet.clock.value = t
        try quiet.core.open(now: ClientTimestamp(microseconds: t))
        try quiet.settle(t: &t)
        XCTAssertEqual(audibleHost.requestsReceived, [],
                       "the audible opt-out suppresses the default ask")
        XCTAssertEqual(quiet.core.control.hostAudioRoutingPosture, .hostAudible)

        // The SAME opt-out against a host whose shell default is
        // muted (--host-audio muted): the preference still means
        // something in both directions — one [0x18 0x01] leaves.
        let mutedHost = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        mutedHost.posture = .hostMuted
        let asking = try Harness(host: mutedHost, coreConfig: config)
        var t2: UInt64 = 1_000
        asking.clock.value = t2
        try asking.core.open(now: ClientTimestamp(microseconds: t2))
        try asking.settle(t: &t2)
        XCTAssertEqual(mutedHost.requestsReceived, [[0x18, 0x01]],
                       "the opt-out ASKS for audible against a muted host")
        XCTAssertEqual(asking.core.control.hostAudioRoutingPosture, .hostAudible)

    }

    func testPinnedHostPostureMappingAndMigration() throws {
        let keyHex = String(repeating: "ab", count: 32)
        func pinned(_ startMuted: Bool?) -> PinnedHost {
            PinnedHost(name: "pup", address: "10.0.0.249", port: 41_000,
                       staticPublicKeyHex: keyHex,
                       pairedAt: "2026-07-27T09:00:00Z",
                       startHostAudioMuted: startMuted)
        }
        // The tri-state, read the one sanctioned way: unset takes the
        // flipped default (muted), a stored true KEEPS its CL-13
        // meaning (muted), and only the explicit false — a value no
        // CL-13 setter ever wrote, so no existing file carries it —
        // is the new "start audible" opt-out. That construction IS
        // the migration: nothing stored changes meaning.
        XCTAssertEqual(pinned(nil).sessionStartHostAudioRouting, .hostMuted)
        XCTAssertEqual(pinned(true).sessionStartHostAudioRouting, .hostMuted)
        XCTAssertEqual(pinned(false).sessionStartHostAudioRouting, .hostAudible)

        // A pre-CL-13 file (no key at all) reads as the flipped
        // default through the same accessor.
        let legacy = Data("""
        {"hosts":{"deadbeef":{"name":"pup","address":"10.0.0.249",\
        "port":41000,"staticPublicKeyHex":"\(keyHex)",\
        "pairedAt":"2026-07-21T09:00:00Z"}}}
        """.utf8)
        let store = try JSONDecoder().decode(PinnedHostStore.self, from: legacy)
        XCTAssertEqual(
            store.hosts["deadbeef"]?.sessionStartHostAudioRouting, .hostMuted)

        // The setter now writes BOTH directions explicitly (the UI's
        // uncheck is an opt-out, not a reset), and the explicit false
        // survives the real save/load path.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl18-pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var live = PinnedHostStore()
        let staticKey = (0..<32).map { UInt8($0) }
        live.pin(staticPublicKey: staticKey, name: "pup",
                 address: "10.0.0.249", port: 41_000,
                 pairedAt: "2026-07-27T09:00:00Z")
        let pkh = try XCTUnwrap(live.hosts.keys.first)
        XCTAssertTrue(live.setStartHostAudioMuted(
            publicKeyHash: pkh, muted: false))
        try live.save(to: url)
        let reloaded = PinnedHostStore.load(from: url)
        XCTAssertEqual(
            reloaded.host(publicKeyHash: pkh)?.startHostAudioMuted, false)
        XCTAssertEqual(
            reloaded.host(publicKeyHash: pkh)?.sessionStartHostAudioRouting,
            .hostAudible)

        // And back to muted, explicitly.
        var flipped = reloaded
        XCTAssertTrue(flipped.setStartHostAudioMuted(
            publicKeyHash: pkh, muted: true))
        XCTAssertEqual(
            flipped.host(publicKeyHash: pkh)?.sessionStartHostAudioRouting,
            .hostMuted)

    }

    // MARK: The tripwire's 0x25 (key 15), in vivo

    /// One sealed chan-1 datagram — the audio evidence the blackout
    /// detector tightens on (payload content is irrelevant to the
    /// evidence rule; the depacketizer's own counters absorb it).
    private func sealedAudio(
        host: RoutingHostStandIn, seq: UInt16, hostMicros: UInt64
    ) throws -> [UInt8] {
        let envelope = Envelope(
            channel: .audio,
            seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: UInt32(seq)),
            timestamp: hostMicros,
            fec: 0
        )
        let header = try envelope.encode(payload: [])
        let payload = try host.transport!.seal(
            plaintext: [0x00][...], aad: header[...], envelope: envelope
        )
        return try envelope.encode(payload: payload)
    }

    func testGateAnnouncedQuietRelaxesDetectorAndAudioRetightens() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting()
                .declaringAudioQuietPosture())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // Key 15 survived intersection, both views.
        XCTAssertEqual(host.agreed?.audioQuietPosture, true,
                       "the host must see key 15 in the client's 0x0F")
        XCTAssertEqual(
            harness.core.agreedCapabilities?.audioQuietPosture, true)

        // Audio evidence tightens the detector (the existing rule).
        XCTAssertFalse(harness.core.control.detectorTightened)
        harness.absorb(
            try sealedAudio(host: host, seq: 0, hostMicros: t), tMicros: t)
        XCTAssertTrue(harness.core.control.detectorTightened,
                      "chan-1 evidence must tighten to 350 ms")

        // The gate closes: 0x25 quiet relaxes the detector — gated
        // silence is contract, not a dark path.
        try host.injectReliable(
            AudioTrackState(state: .quiet).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertFalse(harness.core.control.detectorTightened,
                       "announced quiet must relax the blackout detector")
        XCTAssertEqual(
            harness.core.snapshotCounters().audioTrackStatesReceived, 1)

        // A still-quiet check-in repeats harmlessly (idempotent).
        try host.injectReliable(
            AudioTrackState(state: .quiet).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertFalse(harness.core.control.detectorTightened)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioTrackStatesReceived, 2)

        // Wake: 0x25 active, then the pre-roll's first packet — the
        // audio evidence re-tightens through the existing rule.
        try host.injectReliable(
            AudioTrackState(state: .active).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioTrackStatesReceived, 3)
        harness.absorb(
            try sealedAudio(host: host, seq: 1, hostMicros: t), tMicros: t)
        XCTAssertTrue(harness.core.control.detectorTightened,
                      "the wake burst's evidence must re-tighten")

        XCTAssertEqual(
            harness.core.snapshotCounters().malformedReliableMessages, 0)
    }

    func testGateUnnegotiatedTrackStateDropsLoud() throws {
        // A key-9-only host (no key 15) injecting 0x25 anyway: the
        // client drops it before any contract switches — the rule-3
        // gate, tripwire verse.
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.agreedCapabilities?.audioQuietPosture, false)

        harness.absorb(
            try sealedAudio(host: host, seq: 0, hostMicros: t), tMicros: t)
        XCTAssertTrue(harness.core.control.detectorTightened)

        try host.injectReliable(
            AudioTrackState(state: .quiet).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertTrue(harness.core.control.detectorTightened,
                      "an unnegotiated 0x25 must not relax anything")
        XCTAssertEqual(
            harness.core.snapshotCounters().audioTrackStatesReceived, 0)
        XCTAssertTrue(harness.events.contains {
            if case .protocolNote(let note) = $0 {
                return note.contains("0x25 without negotiated key 15")
            }
            return false
        }, "the drop must be loud")
    }

    // MARK: The video posture's 0x26 (key 16), in vivo
    // (shares this file's scripted-host harness with the audio track;
    // the posture announcements are one family).

    func testGateVideoPostureAnnouncementsLandAndUnnegotiatedDrops() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting()
                .declaringVideoQuietPosture())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.agreedCapabilities?.videoQuietPosture, true)
        XCTAssertNil(harness.core.control.announcedVideoPosture,
                     "no announcement yet — the always-on contract")

        // A ladder step lands: quiet at 30 s.
        try host.injectReliable(
            VideoPostureState(posture: .quiet, keepaliveSeconds: 30).encode(),
            nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().videoPostureStatesReceived, 1)
        XCTAssertEqual(
            harness.core.control.announcedVideoPosture,
            VideoPostureState(posture: .quiet, keepaliveSeconds: 30))

        // The wake back to active.
        try host.injectReliable(
            VideoPostureState(posture: .active, keepaliveSeconds: 1).encode(),
            nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().videoPostureStatesReceived, 2)
        XCTAssertEqual(harness.core.control.announcedVideoPosture?.posture, .active)
        XCTAssertEqual(
            harness.core.snapshotCounters().malformedReliableMessages, 0)

        // The rule-3 gate: a key-9-only host injecting 0x26 anyway.
        let legacyHost = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        let legacy = try Harness(host: legacyHost, coreConfig: config)
        var t2: UInt64 = 1_000
        legacy.clock.value = t2
        try legacy.core.open(now: ClientTimestamp(microseconds: t2))
        try legacy.settle(t: &t2)
        try legacyHost.injectReliable(
            VideoPostureState(posture: .quiet, keepaliveSeconds: 30).encode(),
            nowMicros: t2)
        try legacy.settle(t: &t2)
        XCTAssertEqual(
            legacy.core.snapshotCounters().videoPostureStatesReceived, 0)
        XCTAssertNil(legacy.core.control.announcedVideoPosture)
        XCTAssertTrue(legacy.events.contains {
            if case .protocolNote(let note) = $0 {
                return note.contains("0x26 without negotiated key 16")
            }
            return false
        }, "the drop must be loud")
    }
}

fileprivate extension ClientCoreHarness
where Host == AudioRoutingClientGateTests.RoutingHostStandIn {
    convenience init(
        host: Host,
        coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
    ) throws {
        try self.init(host: host, hostPort: 41_121, coreConfig: coreConfig)
    }

    var postureEvents: [HostAudioRoutingMode] {
        events.compactMap {
            if case .hostAudioRoutingStatus(let mode) = $0 { return mode }
            return nil
        }
    }
}
