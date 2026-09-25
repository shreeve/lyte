import XCTest
import HostCore
import HostSession
import HostWire
import HostWireTestKit
import LyteWire
import LyteWireTestKit

// THE GATE (CL-15, the host half — the Wayland/portal clipboard leaf
// itself is Linux-only follow-up work; the ScriptedClipboardLeaf here
// drives the exact seam it will). Pinned behaviors:
//
//   • the 0x1A/0x1B codecs answer the SAME hand-built arrays
//     ClipboardCodecTests anchors in Wire/ (the cross-pin) and never
//     trap on hostile bytes;
//   • capability key 10 rides the W7 forward-compat spine exactly as
//     key 9 did — the declaration is the local set's bytes plus one
//     canonical `0A F5` entry, surviving intersection only on mutual
//     byte-equal declaration;
//   • in vivo: a negotiated client's 0x1A surfaces exactly once as
//     .clipboardSetReceived, the scripted leaf's echo of that very
//     apply is SUPPRESSED (the boomerang proof — nothing returns on
//     the wire), a genuine host copy reaches the client as a
//     byte-exact 0x1B, and an identical re-copy dedupes;
//   • the rule-3 gate holds: an unnegotiated 0x1A drops loud
//     (.clipboardNotNegotiated), announces are never volunteered to a
//     client that never declared the key, and a 0x1B arriving AT the
//     host drops as role confusion;
//   • an over-ceiling host copy is suppressed and counted, never sent
//     and never an error.

final class ClipboardGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_131,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: Leg 1 — the 0x1A/0x1B bytes, pinned (the Wire cross-pin)

    func testClipboardCodecsPinBytes() throws {
        // "hello" = 68 65 6C 6C 6F — the same hand-computed arrays as
        // Wire's ClipboardCodecTests.
        XCTAssertEqual(
            try ClipboardSet(text: "hello").encode(),
            [0x1A, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
        )
        XCTAssertEqual(
            try ClipboardAnnounce(text: "hello").encode(),
            [0x1B, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
        )
        XCTAssertEqual(
            try ClipboardSet.decode(
                [0x1A, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
            ).text, "hello"
        )
        XCTAssertEqual(
            try ClipboardAnnounce.decode(
                [0x1B, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
            ).text, "hello"
        )
        // Hostile bytes reject, never trap.
        XCTAssertThrowsError(try ClipboardSet.decode([]))
        XCTAssertThrowsError(try ClipboardSet.decode([0x1A]))
        XCTAssertThrowsError(try ClipboardSet.decode([0x1B, 0x61]))
        XCTAssertThrowsError(try ClipboardAnnounce.decode([0x1A, 0x61]))
        XCTAssertThrowsError(try ClipboardSet.decode([0x1A, 0xFF]))
        XCTAssertThrowsError(try ClipboardSet.decode(
            [0x1A] + [UInt8](repeating: 0x61,
                             count: ClipboardWire.maxTextByteCount + 1)
        ))
    }

    // MARK: Leg 2 — key 10 on the spine, mutual-only intersection

    func testCapabilityKeyTenRidesTheSpineAndIntersectsMutualOnly() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        XCTAssertEqual(base.first, 0xA8)
        var expected = base
        expected[0] = 0xA9
        expected += [0x0A, 0xF5]
        let declared = Capabilities.wireDefault.declaringClipboardText()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        XCTAssertTrue(declared.intersecting(declared).clipboardText)
        XCTAssertFalse(declared.intersecting(.wireDefault).clipboardText)
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).clipboardText
        )
    }

    // MARK: Leg 2b — the leaf's text-flavor policy (HS-19), pinned
    // everywhere: the Linux leaf itself compiles only on Linux, but
    // the flavor it reads and the flavors it offers are pure policy.

    func testTextMimeReadPreferenceOrder() {
        // Explicit UTF-8 wins over everything else offered.
        XCTAssertEqual(
            ClipboardTextMime.pickForRead(fromOffered:
                ["image/png", "text/plain", "text/plain;charset=utf-8",
                 "UTF8_STRING"]),
            "text/plain;charset=utf-8"
        )
        // Matching is case-insensitive, and the OWNER's spelling is
        // what gets read back (the request echoes their advertisement).
        XCTAssertEqual(
            ClipboardTextMime.pickForRead(fromOffered:
                ["TEXT/PLAIN;CHARSET=UTF-8"]),
            "TEXT/PLAIN;CHARSET=UTF-8"
        )
        // The X11-era UTF-8 target outranks bare text/plain.
        XCTAssertEqual(
            ClipboardTextMime.pickForRead(fromOffered:
                ["text/plain", "UTF8_STRING"]),
            "UTF8_STRING"
        )
        XCTAssertEqual(
            ClipboardTextMime.pickForRead(fromOffered: ["text/plain"]),
            "text/plain"
        )
    }

    func testTextMimeRefusesNonTextAndOffersFaithfulFirst() {
        // No v1 flavor offered (images, rich text, an empty
        // advertisement): nil — ignored weather, never an error.
        XCTAssertNil(ClipboardTextMime.pickForRead(fromOffered:
            ["image/png", "text/html", "application/x-qt-image"]))
        XCTAssertNil(ClipboardTextMime.pickForRead(fromOffered: []))
        // What an apply advertises: the faithful flavor leads, and
        // every offered flavor is one the leaf can serve as UTF-8.
        XCTAssertEqual(ClipboardTextMime.offered.first,
                       ClipboardTextMime.utf8)
        XCTAssertEqual(ClipboardTextMime.offered,
                       [ClipboardTextMime.utf8, "text/plain",
                        "UTF8_STRING"])
    }

    // MARK: The scripted leaf (the seam the portal leaf will drive)

    /// An in-memory OS clipboard: `apply` stores the text and fires
    /// the change signal — exactly the echo shape the portal's
    /// selection-changed signal will produce. `copy(_:)` is the human
    /// at the host's keyboard.
    private final class ScriptedClipboardLeaf: HostClipboardLeaf {
        var onLocalChange: ((String) -> Void)?
        var onLocalImageChange: (([UInt8]) -> Void)?
        private(set) var content = ""
        private(set) var applied: [String] = []
        private(set) var appliedImages: [[UInt8]] = []
        private(set) var started = false

        func apply(text: String) {
            applied.append(text)
            content = text
            onLocalChange?(text)
        }

        /// P-1's image half of the seam — this text-only gate never
        /// exercises it beyond conformance; the image gate has its
        /// own file.
        func apply(imageData: [UInt8]) {
            appliedImages.append(imageData)
            onLocalImageChange?(imageData)
        }

        /// A genuine host-side copy.
        func copy(_ text: String) {
            content = text
            onLocalChange?(text)
        }

        func start() throws { started = true }
        func stop() { started = false }
    }

    // MARK: The negotiated loopback client

    /// Handshake + capability exchange, direct pipe. The host always
    /// declares key 10 (its clipboard leaf is "enabled" in this gate);
    /// the client's declaration is the leg's variable.
    private func establish(
        clientCapabilities: Capabilities
    ) throws -> (host: HostSessionHarness, client: SealedCtrlPeer<ClientClock>) {
        let host = HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62,
                capabilities: .wireDefault.declaringClipboardText()
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0x1A1B)
        )
        let client = try host.connectClient(declaring: clientCapabilities)
        XCTAssertEqual(host.session.phase, .established)
        return (host, client)
    }

    // MARK: Leg 3 — the negotiated round trip + the boomerang proof

    func testGateSetAppliesEchoSuppressesAndGenuineCopyAnnounces() throws {
        let (host, clientValue) = try establish(
            clientCapabilities: .wireDefault.declaringClipboardText()
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try host.settle(&client, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.clipboardText, true,
                       "mutual key-10 declaration must survive intersection")
        XCTAssertEqual(session.agreedCapabilities?.clipboardText, true)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // The shell wiring this gate proves: the scripted leaf stands
        // in for the portal — every leaf change signal (echo or
        // genuine) is buffered like a real shell's queue, then judged
        // through noteHostClipboardChanged between exchange passes.
        let leaf = ScriptedClipboardLeaf()
        var leafChanges: [String] = []
        leaf.onLocalChange = { leafChanges.append($0) }
        var suppressions: [ClipboardSuppressReason] = []
        var announcedBytes: [Int] = []
        func drainLeafChanges(at micros: UInt64) {
            while !leafChanges.isEmpty {
                let text = leafChanges.removeFirst()
                for event in session.noteHostClipboardChanged(
                    text, now: micros * 1_000, hostMicroseconds: micros
                ) {
                    switch event {
                    case .clipboardAnnounceSuppressed(let reason):
                        suppressions.append(reason)
                    case .clipboardAnnounceSent(let byteCount):
                        announcedBytes.append(byteCount)
                    default:
                        XCTFail("unexpected event \(event)")
                    }
                }
            }
        }

        // The client copies on the Mac: one 0x1A rides the ordered
        // stream; the session surfaces it exactly once; the leaf
        // applies it; the leaf's OWN change signal for that apply is
        // suppressed — and NOTHING returns on the wire.
        try client.arq.send(
            message: try ClipboardSet(text: "copied on the mac").encode(),
            now: ClientTimestamp(microseconds: t)
        )
        var sets: [String] = []
        try host.settle(&client, t: &t) {
            if case .clipboardSetReceived(let text) = $0 {
                sets.append(text)
                leaf.apply(text: text)
            }
        }
        XCTAssertEqual(sets, ["copied on the mac"],
                       "exactly one set, exactly once")
        XCTAssertEqual(leaf.applied, ["copied on the mac"])
        drainLeafChanges(at: t)
        XCTAssertEqual(suppressions, [.loopEcho],
                       "the apply's echo must suppress — the boomerang proof")
        try host.settle(&client, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.clipboardAnnounce),
                       [], "a set must not boomerang as an announce")
        XCTAssertEqual(session.counters.clipboardSetsReceived, 1)
        XCTAssertEqual(session.counters.clipboardAnnouncesSuppressed, 1)
        XCTAssertEqual(session.counters.clipboardAnnouncesSent, 0)

        // A genuine host copy: one byte-exact 0x1B reaches the client.
        leaf.copy("copied on the host")
        drainLeafChanges(at: t)
        try host.settle(&client, t: &t)
        XCTAssertEqual(
            client.take(type: CtrlMessageType.clipboardAnnounce),
            [try ClipboardAnnounce(text: "copied on the host").encode()]
        )
        XCTAssertEqual(session.counters.clipboardAnnouncesSent, 1)
        XCTAssertEqual(announcedBytes, ["copied on the host".utf8.count])

        // Copying the identical text again dedupes — nothing new to say.
        leaf.copy("copied on the host")
        drainLeafChanges(at: t)
        try host.settle(&client, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.clipboardAnnounce), [])
        XCTAssertEqual(suppressions, [.loopEcho, .duplicate])
        XCTAssertEqual(session.counters.clipboardAnnouncesSent, 1)
    }

    // MARK: Leg 4 — the rule-3 gate against the unnegotiated

    func testGateUnnegotiatedSetRefusedLoudAndAnnounceStaysSilent() throws {
        // A v1 client: declares, but never key 10.
        let (host, clientValue) = try establish(
            clientCapabilities: .wireDefault
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try host.settle(&client, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.clipboardText, false)
        XCTAssertNotEqual(session.agreedCapabilities?.clipboardText, true)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // It sets anyway (hostile or buggy): dropped loud, no event,
        // no counter movement.
        try client.arq.send(
            message: try ClipboardSet(text: "sneaky").encode(),
            now: ClientTimestamp(microseconds: t)
        )
        var sets = 0
        var refusals = 0
        try host.settle(&client, t: &t) {
            if case .clipboardSetReceived = $0 { sets += 1 }
            if case .dropped(.clipboardNotNegotiated) = $0 { refusals += 1 }
        }
        XCTAssertEqual(sets, 0)
        XCTAssertEqual(refusals, 1)
        XCTAssertEqual(session.counters.clipboardSetsReceived, 0)

        // The announce side of the same gate: the session refuses to
        // narrate the host clipboard to a client that never asked for
        // the key — silently (the noteAudioRoutingApplied rule).
        XCTAssertEqual(
            session.noteHostClipboardChanged(
                "host secret", now: t * 1_000, hostMicroseconds: t
            ), []
        )
        try host.settle(&client, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.clipboardAnnounce), [])
        XCTAssertEqual(session.counters.clipboardAnnouncesSent, 0)

        // A 0x1B arriving AT the host (role confusion) drops loud.
        try client.arq.send(
            message: try ClipboardAnnounce(text: "confused").encode(),
            now: ClientTimestamp(microseconds: t)
        )
        var confused = 0
        try host.settle(&client, t: &t) {
            if case .dropped(.unexpectedCtrlType(0x1B)) = $0 { confused += 1 }
        }
        XCTAssertEqual(confused, 1)
    }

    // MARK: Leg 5 — the ceiling is weather, not an error

    func testGateOverCeilingHostCopySuppressedNeverSent() throws {
        let (host, clientValue) = try establish(
            clientCapabilities: .wireDefault.declaringClipboardText()
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)
        XCTAssertEqual(session.agreedCapabilities?.clipboardText, true)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        let huge = String(
            repeating: "a", count: ClipboardWire.maxTextByteCount + 1
        )
        let events = session.noteHostClipboardChanged(
            huge, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [.clipboardAnnounceSuppressed(.overBudget)])
        try host.settle(&client, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.clipboardAnnounce), [])
        XCTAssertEqual(session.counters.clipboardAnnouncesSuppressed, 1)
        XCTAssertEqual(session.counters.clipboardAnnouncesSent, 0)

        // An empty leaf report says nothing (v1 does not sync clearing).
        XCTAssertEqual(
            session.noteHostClipboardChanged(
                "", now: t * 1_000, hostMicroseconds: t
            ), []
        )

        // The exact ceiling still goes through — legal to the byte.
        let atCeiling = String(
            repeating: "b", count: ClipboardWire.maxTextByteCount
        )
        let sent = session.noteHostClipboardChanged(
            atCeiling, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(
            sent, [.clipboardAnnounceSent(
                byteCount: ClipboardWire.maxTextByteCount)]
        )
        try host.settle(&client, t: &t)
        XCTAssertEqual(
            client.take(type: CtrlMessageType.clipboardAnnounce),
            [try ClipboardAnnounce(text: atCeiling).encode()]
        )
    }
}
