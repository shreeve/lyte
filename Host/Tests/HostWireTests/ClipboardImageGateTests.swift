import XCTest
import HostCore
import HostWire
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
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            var word = rng.next()
            for _ in 0..<8 where bytes.count < count {
                bytes.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return bytes
    }

    // MARK: The client end (the BulkClient shape, grown the REAL
    // Wire ClipboardImageChannel — both ends of this gate run the
    // production lane logic)

    private struct ImageClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var bulkSeq: UInt16 = 0
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        var bulkArq = ArqEndpoint<ClientClock>(channel: .bulkTransfer)
        let staticKeys: NoiseKeyPair

        var channel = ClipboardImageChannel()
        var book = ClipboardSyncBook()
        var imageRng = SplitMix64(seed: 0xC11)

        var received: [[UInt8]] = []
        /// Bulk messages the channel did NOT claim (the file lane's).
        var receivedBulk: [BulkMessage] = []
        /// The channel's non-send events, in order.
        var imageEvents: [ClipboardImageEvent] = []

        init(hostStaticPublicKey: [UInt8]) throws {
            staticKeys = NoiseKeyPair.generate()
            noise = try NoiseSession(
                role: .initiator,
                staticKeys: staticKeys,
                remoteStaticPublicKey: hostStaticPublicKey
            )
        }

        mutating func message1Datagram(
            clientMicros: UInt64
        ) throws -> [UInt8] {
            let message1 = try noise.writeMessage1()
            return try datagram(
                channel: .ctrl,
                body: [CtrlMessageType.noiseHandshake1] + message1,
                sealed: false, clientMicros: clientMicros
            )
        }

        mutating func datagram(
            channel: ChannelId, body: [UInt8], sealed: Bool,
            clientMicros: UInt64
        ) throws -> [UInt8] {
            let seq: ChannelSeq
            switch channel {
            case .bulkTransfer:
                seq = ChannelSeq(rawValue: bulkSeq)
                bulkSeq &+= 1
            default:
                seq = ChannelSeq(rawValue: ctrlSeq)
                ctrlSeq &+= 1
            }
            let envelope = Envelope(
                channel: channel, seq: seq,
                frame: FrameNumber(rawValue: 0),
                timestamp: clientMicros, fec: 0
            )
            guard sealed else { return try envelope.encode(payload: body) }
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            return try envelope.encode(payload: payload)
        }

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            if transport == nil {
                XCTAssertEqual(envelope.channel, .ctrl)
                XCTAssertEqual(
                    payload.first, CtrlMessageType.noiseHandshake2
                )
                _ = try noise.readMessage2(payload.dropFirst())
                transport = try noise.makeTransport()
                return
            }
            guard envelope.channel == .ctrl
                || envelope.channel == .bulkTransfer
            else { return }
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                return // network duplicate; routine
            }
            if envelope.channel == .bulkTransfer {
                for event in bulkArq.ingest(
                    payload: plaintext,
                    now: ClientTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let bytes) = event {
                        try consumeBulkStream(bytes, nowMicros: nowMicros)
                    }
                }
                return
            }
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                for event in arq.ingest(
                    payload: plaintext,
                    now: ClientTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let bytes) = event {
                        received.append(bytes)
                    }
                }
            default:
                break // beacons etc. — not this gate's business
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
                    message, book: &book, sha256: Sha256.digest
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
                    try bulkArq.send(
                        message: bytes,
                        now: ClientTimestamp(microseconds: nowMicros)
                    )
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
                data, sha256: Sha256.digest(data),
                book: &book, rng: &imageRng
            )
            try absorbChannelEvents(events, nowMicros: nowMicros)
        }

        /// Raw chan-8 bytes (crafting hostile/foreign traffic).
        mutating func sendRaw(
            _ bytes: [UInt8], nowMicros: UInt64
        ) throws {
            try bulkArq.send(
                message: bytes,
                now: ClientTimestamp(microseconds: nowMicros)
            )
        }

        mutating func takeImageEvents() -> [ClipboardImageEvent] {
            defer { imageEvents.removeAll() }
            return imageEvents
        }

        mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            var out: [[UInt8]] = []
            let now = ClientTimestamp(microseconds: nowMicros)
            let (ctrlPayloads, _) = arq.poll(now: now)
            for payload in ctrlPayloads {
                out.append(try datagram(
                    channel: .ctrl, body: payload, sealed: true,
                    clientMicros: nowMicros
                ))
            }
            let (bulkPayloads, _) = bulkArq.poll(now: now)
            for payload in bulkPayloads {
                out.append(try datagram(
                    channel: .bulkTransfer, body: payload, sealed: true,
                    clientMicros: nowMicros
                ))
            }
            return out
        }
    }

    private final class DatagramBox {
        var datagrams: [VideoChannelDatagram] = []
    }

    private func establish(
        hostCapabilities: Capabilities,
        clientCapabilities: Capabilities
    ) throws -> (session: Session, client: ImageClient, box: DatagramBox) {
        let hostStatic = NoiseKeyPair.generate()
        let box = DatagramBox()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62,
                capabilities: hostCapabilities
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x0122),
            send: { box.datagrams.append($0) }
        )
        var client = try ImageClient(
            hostStaticPublicKey: hostStatic.publicKey)
        _ = session.receive(
            try client.message1Datagram(clientMicros: 500),
            from: Self.tupleA, now: 0, hostMicroseconds: 0
        )
        XCTAssertEqual(session.phase, .established)
        session.pump(now: 0)
        var negotiator = CapabilityNegotiator(
            role: .client, local: clientCapabilities
        )
        try client.arq.send(
            message: try negotiator.start().encode(),
            now: ClientTimestamp(microseconds: 1_000)
        )
        return (session, client, box)
    }

    /// Exchange passes 2 ms apart until both ends quiesce.
    private func settle(
        _ session: Session, _ client: inout ImageClient,
        _ box: DatagramBox, forwarded: inout Int, t: inout UInt64,
        onEvent: (SessionEvent) -> Void = { _ in }
    ) throws {
        var idle = 0
        while idle < 3 {
            t += 2_000
            let before = (
                forwarded, client.received.count,
                client.receivedBulk.count, client.imageEvents.count
            )
            var events = session.advance(now: t * 1_000, hostMicroseconds: t)
            session.pump(now: t * 1_000)
            while forwarded < box.datagrams.count {
                try client.absorb(box.datagrams[forwarded].bytes, nowMicros: t)
                forwarded += 1
            }
            for datagram in try client.pollOut(nowMicros: t) {
                events += session.receive(
                    datagram, from: Self.tupleA,
                    now: t * 1_000, hostMicroseconds: t
                )
                session.pump(now: t * 1_000)
                while forwarded < box.datagrams.count {
                    try client.absorb(
                        box.datagrams[forwarded].bytes, nowMicros: t
                    )
                    forwarded += 1
                }
            }
            for event in events { onEvent(event) }
            idle = (
                forwarded, client.received.count,
                client.receivedBulk.count, client.imageEvents.count
            ) == before ? idle + 1 : 0
        }
    }

    private var imagesTier: Capabilities {
        .wireDefault.declaringClipboardText().declaringClipboardImages()
    }

    // MARK: Leg 1 — the gate is 10 ∧ 12, never 11

    func testImageGateNegotiatesWithoutFileConsent() throws {
        // Neither end accepts files (no key 11) — images still agree.
        let (session, clientValue, box) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        var agreed: Capabilities?
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.clipboardImagesAgreed, true,
                       "images must agree with NO key 11 anywhere")
        XCTAssertEqual(agreed?.bulkTransfer, false)
        XCTAssertTrue(session.agreedClipboardImages)
        XCTAssertFalse(session.agreedBulkTransfer)

        // A text-only client degrades v2 to v1 — text agreed, images
        // not, and the host's image mouth stays silent.
        let (session2, client2Value, box2) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: .wireDefault.declaringClipboardText()
        )
        var client2 = client2Value
        var forwarded2 = 0
        var t2: UInt64 = 1_000
        try settle(session2, &client2, box2, forwarded: &forwarded2, t: &t2)
        XCTAssertTrue(session2.agreedClipboardText)
        XCTAssertFalse(session2.agreedClipboardImages)
        XCTAssertEqual(
            session2.noteHostClipboardImageChanged(
                [1, 2, 3], now: t2 * 1_000, hostMicroseconds: t2
            ), [],
            "an ungated session never narrates the host clipboard"
        )

        print("P-1 gate (negotiation): images agreed 10∧12 with no "
            + "key 11; text-only peer degrades to v1, host mouth silent")
    }

    // MARK: Leg 2 — both directions in vivo + the boomerang proofs

    func testGateImageRoundTripsBothDirectionsAndEchoesSuppress() throws {
        let (session, clientValue, box) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertTrue(session.agreedClipboardImages)

        // Client → host: a 150 KiB "PNG" (3 chunks — the multi-chunk
        // geometry through the sealed stack).
        let clientImage = makePayload(count: 150_000, seed: 0xF00D)
        try client.shareImage(clientImage, nowMicros: t)
        var applied: [(data: [UInt8], mime: String)] = []
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
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
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
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
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
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
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertTrue(session.arqIsQuiescent)

        print("P-1 gate (in vivo): client image → host byte-exact "
            + "(\(clientImage.count) B, 3 chunks); host image → client "
            + "byte-exact (\(hostImage.count) B); both echoes suppressed")
    }

    // MARK: Leg 3 — rule 3: ungated 0x22 drops loud; the lanes'
    // gates stay independent

    func testGateUngatedCargoDropsLoudAndLanesStayIndependent() throws {
        // A files-only pair: chan 8 is OPEN (key 11 agreed) but the
        // image dialect is not — the marker itself must draw the
        // typed drop, never reach the file machinery.
        let (session, clientValue, box) = try establish(
            hostCapabilities: .wireDefault.declaringClipboardText()
                .declaringBulkTransfer(),
            clientCapabilities: .wireDefault.declaringClipboardText()
                .declaringBulkTransfer()
        )
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertTrue(session.agreedBulkTransfer)
        XCTAssertFalse(session.agreedClipboardImages)

        let cargo = try ClipboardImageCargo(
            transferId: 0xD1, mime: "image/png"
        )
        try client.sendRaw(cargo.encode(), nowMicros: t)
        var refusals = 0
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
            if case .dropped(.clipboardImagesNotNegotiated) = $0 {
                refusals += 1
            }
        }
        XCTAssertEqual(refusals, 1)

        // The mirror: an images-only pair (NO key 11) — a bare file
        // offer on the open chan 8 is still ungated traffic.
        let (session2, client2Value, box2) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client2 = client2Value
        var forwarded2 = 0
        var t2: UInt64 = 1_000
        try settle(session2, &client2, box2, forwarded: &forwarded2, t: &t2)
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
        try settle(session2, &client2, box2, forwarded: &forwarded2, t: &t2) {
            if case .dropped(.bulkNotNegotiated) = $0 { fileRefusals += 1 }
            if case .bulkMessageReceived = $0 { surfaced += 1 }
        }
        XCTAssertEqual(fileRefusals, 1)
        XCTAssertEqual(surfaced, 0)
        XCTAssertEqual(session2.counters.bulkMessagesReceived, 0)

        print("P-1 gate (rule 3): ungated 0x22 dropped loud; file "
            + "offer on an images-only chan 8 dropped loud — the "
            + "lanes' gates are independent")
    }

    // MARK: Leg 4 — a foreign mime is typed weather, and the
    // trailing offer never leaks

    func testGateForeignMimeDeclinedAndOfferSwallowed() throws {
        let (session, clientValue, box) = try establish(
            hostCapabilities: imagesTier,
            clientCapabilities: imagesTier
        )
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)

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
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
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

        print("P-1 gate (mime): image/jxl → abort(declined), offer "
            + "swallowed, nothing leaked")
    }
}
