import XCTest
import HostCore
import HostSession
import HostWire
import HostWireTestKit
import LyteCore
import LyteWire
import LyteWireTestKit

// THE GATE (P-1, clipboard v2 — the host half; the Mutter leaf's
// image flavors are Linux-only and this drives the exact seam they
// will). Pinned behaviors:
//
//   • the image gate is keys 10 ∧ 12 and NEVER key 11: a host that
//     accepts no files still syncs clipboard images, and file
//     messages on an images-only chan 8 stay ungated traffic
//     (dropped loud) — the consent tiers do not couple;
//   • in vivo, both directions: a client image lands byte-exact as
//     .clipboardImageReceived (marker → offer → chunks → digest
//     verdict over chan 8's own sealed ARQ stream), a host copy
//     lands byte-exact in the client's channel — and each side's
//     apply echo SUPPRESSES through the shared book (the boomerang
//     proof, cross-modal keys);
//   • the rule-3 gate holds: a 0x22 without keys 10∧12 in the
//     agreed set drops loud (.clipboardImagesNotNegotiated), and an
//     ungated noteHostClipboardImageChanged stays silent;
//   • a foreign mime draws abort(declined) — typed weather, and the
//     trailing offer is swallowed rather than leaking to the file
//     lane.

final class ClipboardImageGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_183,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    private func makePayload(count: Int, seed: UInt64) -> [UInt8] {
        var rng = SplitMix64(seed: seed)
        return rng.bytes(count)
    }

    // MARK: The client end (the REAL Wire ClipboardImageChannel — both
    // ends of this gate run the production lane logic)

    private struct ImageClient: PeerBackedClient {
        var peer: SealedCtrlPeer<ClientClock>
        var channel = ClipboardImageChannel()
        var book = ClipboardSyncBook()
        var imageRng = SplitMix64(seed: 0xC11)

        /// Bulk messages the channel did NOT claim (the file lane's).
        var receivedBulk: [BulkMessage] = []
        /// The channel's non-send events, in order.
        var imageEvents: [ClipboardImageEvent] = []

        var progressMark: Int {
            peer.received.count + receivedBulk.count + imageEvents.count
        }

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            guard case .reliable(let envelope, _, let events) =
                    try peer.absorb(bytes, nowMicros: nowMicros),
                  envelope.channel == .bulkTransfer
            else { return } // CTRL lands in `received`; beacons etc. aside
            for case .message(_, let bytes) in events {
                try consumeBulkStream(bytes, nowMicros: nowMicros)
            }
        }

        /// The client session core's routing, in miniature: marker →
        /// channel; claimed id → channel; the rest → the file lane.
        private mutating func consumeBulkStream(
            _ bytes: [UInt8], nowMicros: UInt64
        ) throws {
            if bytes.first == CtrlMessageType.clipboardImageCargo {
                let cargo = try ClipboardImageCargo.decode(bytes)
                try absorbChannelEvents(
                    channel.ingestCargo(cargo), nowMicros: nowMicros
                )
                return
            }
            let message = try BulkMessage.decode(bytes)
            if channel.claims(message) {
                let events = channel.ingest(
                    message, book: &book, hasher: { Sha256() }
                )
                try absorbChannelEvents(events, nowMicros: nowMicros)
                return
            }
            receivedBulk.append(message)
        }

        mutating func absorbChannelEvents(
            _ events: [ClipboardImageEvent], nowMicros: UInt64
        ) throws {
            for event in events {
                if case .send(let bytes) = event {
                    try peer.sendBulk(bytes, nowMicros: nowMicros)
                } else {
                    imageEvents.append(event)
                }
            }
        }

        /// A local image copy on the Mac, through the real channel.
        mutating func shareImage(
            _ data: [UInt8], nowMicros: UInt64
        ) throws {
            let events = channel.shareLocalImage(
                data, sha256: { Sha256.digest(data) },
                book: &book, rng: &imageRng
            )
            try absorbChannelEvents(events, nowMicros: nowMicros)
        }

        /// Raw chan-8 bytes (crafting hostile/foreign traffic).
        mutating func sendRaw(
            _ bytes: [UInt8], nowMicros: UInt64
        ) throws {
            try peer.sendBulk(bytes, nowMicros: nowMicros)
        }

        mutating func takeImageEvents() -> [ClipboardImageEvent] {
            defer { imageEvents.removeAll() }
            return imageEvents
        }
    }

    private func establish(
        hostCapabilities: Capabilities,
        clientCapabilities: Capabilities
    ) throws -> (host: HostSessionHarness, client: ImageClient) {
        let host = HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62,
                capabilities: hostCapabilities
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0x0122)
        )
        var client = ImageClient(peer: try host.connectClient(
            declaring: clientCapabilities,
            openChannels: [.ctrl, .bulkTransfer]
        ))
        client.peer.bulkArq = ArqEndpoint(channel: .bulkTransfer)
        XCTAssertEqual(host.session.phase, .established)
        return (host, client)
    }

    private var imagesTier: Capabilities {
        .wireDefault.declaringClipboardText().declaringClipboardImages()
    }

    // MARK: One generator, one stream

    /// The session's organs draw from one injected generator. Copies of a
    /// value-typed one replay each other: the first path-challenge token
    /// then equalled the first image-cargo id, which the client sees.
    func testChallengeTokensAndImageIdsNeverReplayOneStream() throws {
        let (host, clientValue) = try establish(
            hostCapabilities: imagesTier, clientCapabilities: imagesTier)
        var client = clientValue
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)

        let roamTuple = FourTuple(
            localAddress: "10.0.0.249", localPort: 41_183,
            remoteAddress: "10.0.0.77", remotePort: 62_000)
        var token: UInt64?
        for case .path(.sendChallenge(_, let challenge)) in host.session.receive(
            try client.peer.datagram(
                body: [0x00], timestamp: t,
                extensions: [host.session.connectionId.wireExtension]),
            from: roamTuple, now: t * 1_000, hostMicroseconds: t) {
            token = challenge.token
        }

        let sentBefore = host.sent.count
        _ = host.session.noteHostClipboardImageChanged(
            makePayload(count: 4_000, seed: 0x1D), now: t * 1_000,
            hostMicroseconds: t)
        host.session.pump(now: t * 1_000)
        var transferId: UInt64?
        for datagram in host.sent[sentBefore...]
        where datagram.pacerClass == .bulk {
            guard case .reliable(_, _, let events) = try client.peer.absorb(
                datagram.bytes, nowMicros: t)
            else { continue }
            for case .message(_, let bytes) in events
            where bytes.first == CtrlMessageType.clipboardImageCargo {
                transferId = try ClipboardImageCargo.decode(bytes).transferId
            }
        }
        XCTAssertNotNil(token)
        XCTAssertNotNil(transferId)
        XCTAssertNotEqual(token, transferId)
    }

    // MARK: Leg 1 — the gate is 10 ∧ 12, never 11

    func testImageGateNegotiatesWithoutFileConsent() throws {
        // Neither end accepts files (no key 11) — images still agree.
        let (host, clientValue) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        var agreed: Capabilities?
        try host.settle(&client, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.clipboardImagesAgreed, true,
                       "images must agree with NO key 11 anywhere")
        XCTAssertEqual(agreed?.bulkTransfer, false)
        XCTAssertEqual(session.agreedCapabilities?.clipboardImagesAgreed, true)
        XCTAssertNotEqual(session.agreedCapabilities?.bulkTransfer, true)

        // A text-only client degrades v2 to v1 — text agreed, images
        // not, and the host's image mouth stays silent.
        let (host2, client2Value) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: .wireDefault.declaringClipboardText()
        )
        var client2 = client2Value
        let session2 = host2.session
        var t2: UInt64 = 1_000
        try host2.settle(&client2, t: &t2)
        XCTAssertEqual(session2.agreedCapabilities?.clipboardText, true)
        XCTAssertNotEqual(session2.agreedCapabilities?.clipboardImagesAgreed, true)
        XCTAssertEqual(
            session2.noteHostClipboardImageChanged(
                [1, 2, 3], now: t2 * 1_000, hostMicroseconds: t2
            ), [],
            "an ungated session never narrates the host clipboard"
        )
    }

    // MARK: Leg 2 — both directions in vivo + the boomerang proofs

    func testGateImageRoundTripsBothDirectionsAndEchoesSuppress() throws {
        let (host, clientValue) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)
        XCTAssertEqual(session.agreedCapabilities?.clipboardImagesAgreed, true)

        // Client → host: a 150 KiB "PNG" (3 chunks — the multi-chunk
        // geometry through the sealed stack).
        let clientImage = makePayload(count: 150_000, seed: 0xF00D)
        try client.shareImage(clientImage, nowMicros: t)
        var applied: [(data: [UInt8], mime: String)] = []
        try host.settle(&client, t: &t) {
            if case .clipboardImageReceived(let data, let mime) = $0 {
                applied.append((data, mime))
            }
        }
        XCTAssertEqual(applied.count, 1, "exactly one apply, exactly once")
        XCTAssertEqual(applied.first?.data, clientImage,
                       "byte-exact through seal/unseal + ARQ + chunks")
        XCTAssertEqual(applied.first?.mime, "image/png")
        let clientEvents = client.takeImageEvents()
        XCTAssertTrue(clientEvents.contains { event in
            if case .shareCompleted = event { return true }
            return false
        }, "the digest verdict must round-trip to the sender")
        XCTAssertEqual(session.clipboardImageCounters.imagesApplied, 1)

        // The boomerang proof, host side: the leaf applies and its
        // change signal comes back — suppressed through the SHARED
        // book, nothing returns on the wire.
        let echo = session.noteHostClipboardImageChanged(
            clientImage, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(echo, [.clipboardImageSuppressed(.loopEcho)])
        try host.settle(&client, t: &t)
        XCTAssertTrue(client.takeImageEvents().isEmpty,
                      "an apply echo must not boomerang as a share")

        // Host → client: a genuine host copy lands in the client's
        // channel byte-exact, and the host hears the verdict.
        let hostImage = makePayload(count: 70_000, seed: 0xBEEF)
        var hostEvents: [SessionEvent] = []
        hostEvents += session.noteHostClipboardImageChanged(
            hostImage, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertTrue(hostEvents.contains(
            .clipboardImageShareStarted(byteCount: hostImage.count)
        ))
        try host.settle(&client, t: &t) {
            hostEvents.append($0)
        }
        let clientApplies = client.takeImageEvents().compactMap {
            if case .applyImage(let data, let mime) = $0 {
                return (data, mime)
            }
            return nil
        } as [(data: [UInt8], mime: String)]
        XCTAssertEqual(clientApplies.count, 1)
        XCTAssertEqual(clientApplies.first?.data, hostImage)
        XCTAssertTrue(hostEvents.contains(
            .clipboardImageShareCompleted(byteCount: hostImage.count)
        ))
        XCTAssertEqual(session.clipboardImageCounters.sharesCompleted, 1)

        // The boomerang proof, client side: the NSPasteboard echo of
        // that apply judges suppressEcho through the client's book.
        XCTAssertEqual(
            client.book.admitLocalChange(
                bytes: ClipboardImageWire.bookKey(
                    sha256: Sha256.digest(hostImage)
                )
            ),
            .suppressEcho
        )

        // And both reliable sublayers drain to quiet.
        try host.settle(&client, t: &t)
        XCTAssertTrue(session.arqIsQuiescent)
    }

    // MARK: Leg 2b — a refused host copy is never hashed

    func testHostCopyIsJudgedByTheDigestFreeGatesBeforeAnyHash() throws {
        let (host, clientValue) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)
        let noHash: () -> [UInt8] = {
            XCTFail("a refused image must never be hashed")
            return []
        }

        // Empty and over-ceiling copies settle without a digest.
        XCTAssertEqual(
            session.prejudgeHostClipboardImage(byteCount: 0, now: t * 1_000),
            [.clipboardImageSuppressed(.emptyImage)])
        let over = ClipboardImageWire.maxImageByteCount + 1
        XCTAssertEqual(
            session.prejudgeHostClipboardImage(byteCount: over, now: t * 1_000),
            [.clipboardImageSuppressed(.overBudget(over))])

        // A fitting copy leaves only the digest-keyed book: hash, then
        // judge again under the lock.
        let image = makePayload(count: 70_000, seed: 0xD16E)
        XCTAssertNil(session.prejudgeHostClipboardImage(
            byteCount: image.count, now: t * 1_000))
        var hashes = 0
        let started = session.noteHostClipboardImageChanged(
            image, sha256: { hashes += 1; return Sha256.digest(image) },
            now: t * 1_000, hostMicroseconds: t)
        XCTAssertEqual(hashes, 1)
        XCTAssertTrue(started.contains(
            .clipboardImageShareStarted(byteCount: image.count)))

        // While that share is in flight the lane is busy: the next copy
        // is refused before its digest, in both entry points.
        let next = makePayload(count: 1_000, seed: 0xB5)
        XCTAssertEqual(
            session.prejudgeHostClipboardImage(
                byteCount: next.count, now: t * 1_000),
            [.clipboardImageSuppressed(.sendBusy)])
        XCTAssertEqual(
            session.noteHostClipboardImageChanged(
                next, sha256: noHash, now: t * 1_000, hostMicroseconds: t),
            [.clipboardImageSuppressed(.sendBusy)])

        // A session whose image gate is shut says nothing at all.
        let (textOnly, textClientValue) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: .wireDefault.declaringClipboardText()
        )
        var textClient = textClientValue
        var t2: UInt64 = 1_000
        try textOnly.settle(&textClient, t: &t2)
        XCTAssertEqual(
            textOnly.session.prejudgeHostClipboardImage(
                byteCount: image.count, now: t2 * 1_000),
            [])
    }

    // MARK: Leg 3 — rule 3: ungated 0x22 drops loud; the lanes'
    // gates stay independent

    func testGateUngatedCargoDropsLoudAndLanesStayIndependent() throws {
        // A files-only pair: chan 8 is OPEN (key 11 agreed) but the
        // image dialect is not — the marker itself must draw the
        // typed drop, never reach the file machinery.
        let (host, clientValue) = try establish(
            hostCapabilities: .wireDefault.declaringClipboardText()
                .declaringBulkTransfer(),
            clientCapabilities: .wireDefault.declaringClipboardText()
                .declaringBulkTransfer()
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)
        XCTAssertEqual(session.agreedCapabilities?.bulkTransfer, true)
        XCTAssertNotEqual(session.agreedCapabilities?.clipboardImagesAgreed, true)

        let cargo = try ClipboardImageCargo(
            transferId: 0xD1, mime: "image/png"
        )
        try client.sendRaw(cargo.encode(), nowMicros: t)
        var refusals = 0
        try host.settle(&client, t: &t) {
            if case .dropped(.clipboardImagesNotNegotiated) = $0 {
                refusals += 1
            }
        }
        XCTAssertEqual(refusals, 1)

        // The mirror: an images-only pair (NO key 11) — a bare file
        // offer on the open chan 8 is still ungated traffic.
        let (host2, client2Value) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client2 = client2Value
        let session2 = host2.session
        var t2: UInt64 = 1_000
        try host2.settle(&client2, t: &t2)
        let fileOffer = try BulkOffer(
            transferId: 0xF11E, totalByteCount: 10,
            chunkByteCount: 4_096,
            sha256: [UInt8](repeating: 7, count: 32),
            name: "sneaky.bin"
        )
        try client2.sendRaw(
            BulkMessage.offer(fileOffer).encode(), nowMicros: t2
        )
        var fileRefusals = 0
        var surfaced = 0
        try host2.settle(&client2, t: &t2) {
            if case .dropped(.bulkNotNegotiated) = $0 { fileRefusals += 1 }
            if case .bulkMessageReceived = $0 { surfaced += 1 }
        }
        XCTAssertEqual(fileRefusals, 1)
        XCTAssertEqual(surfaced, 0)
        XCTAssertEqual(session2.counters.bulkMessagesReceived, 0)
    }

    // MARK: Leg 4 — a foreign mime is typed weather, and the
    // trailing offer never leaks

    func testGateForeignMimeDeclinedAndOfferSwallowed() throws {
        let (host, clientValue) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)

        // A v3 peer's better idea: JPEG XL cargo. The marker decodes
        // (future formats stay speakable) but v2 declines it, and the
        // offer already in flight behind it is swallowed.
        let payload = makePayload(count: 5_000, seed: 0x1DEA)
        let cargo = try ClipboardImageCargo(
            transferId: 0x1DEA, mime: "image/jxl"
        )
        let offer = try BulkOffer(
            transferId: 0x1DEA, totalByteCount: UInt64(payload.count),
            chunkByteCount: ClipboardImageWire.chunkByteCount,
            sha256: Sha256.digest(payload),
            name: "clipboard.jxl", mimeHint: "image/jxl"
        )
        try client.sendRaw(cargo.encode(), nowMicros: t)
        try client.sendRaw(
            BulkMessage.offer(offer).encode(), nowMicros: t
        )
        var refused: [ClipboardImageRefuseReason] = []
        var surfaced = 0
        try host.settle(&client, t: &t) {
            if case .clipboardImageRefused(let reason) = $0 {
                refused.append(reason)
            }
            if case .bulkMessageReceived = $0 { surfaced += 1 }
        }
        XCTAssertEqual(refused, [.unsupportedMime("image/jxl")])
        XCTAssertEqual(surfaced, 0,
                       "the trailing offer must never leak to the file lane")
        // The typed abort reached the client's raw lane (its channel
        // never claimed the crafted id).
        XCTAssertEqual(
            client.receivedBulk.compactMap { message -> BulkAbort? in
                if case .abort(let abort) = message { return abort }
                return nil
            }.map(\.reason),
            [.declined]
        )
        XCTAssertEqual(session.clipboardImageCounters.receivesRefused, 1)
    }
}

private extension Session {
    /// The host-clipboard report with the digest computed in place.
    func noteHostClipboardImageChanged(
        _ data: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        noteHostClipboardImageChanged(
            data, sha256: { Sha256.digest(data) },
            now: now, hostMicroseconds: hostMicroseconds
        )
    }
}
