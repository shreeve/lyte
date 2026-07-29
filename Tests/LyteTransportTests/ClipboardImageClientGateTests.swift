import XCTest
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (P-1, the client half of clipboard v2 — images). Pinned
// behaviors:
//
//   • capability key 12 rides the W7 spine byte-equal to the host's
//     encoding (wireDefault + `0C F5`), and the session core's DEFAULT
//     config declares it beside keys 9–11 (dialect, not consent —
//     the images rung stays OFF by default like text);
//   • in vivo through the REAL core against a scripted 10∧12 host
//     stand-in running the REAL Wire ClipboardImageChannel: a local
//     image copy rides chan 8 as 0x22 cargo + offer + chunks and
//     lands byte-exact (multi-chunk, through real ARQ + Noise), the
//     digest verdict returns, a host image surfaces as the typed
//     event — and BOTH apply echoes suppress through the shared book
//     (the boomerang proofs, cross-modal keys);
//   • the consent tier is Off / Text only / Text + images: with the
//     images rung off nothing leaves (.sharingDisabled) and an
//     inbound marker draws abort(declined) — typed, never silent,
//     because the image sender waits on a verdict; the live toggle
//     opens both directions;
//   • the rule-3 gate holds per LANE: against a text-only host the
//     image share refuses before a byte leaves (.notNegotiated) and
//     a hostile 0x22 drops loud; a FILE offer against an images-only
//     agreement stays ungated traffic (dropped loud, never surfaced)
//     — keys 11 and 12 gate independently;
//   • ceilings are weather: empty and over-32 MiB copies suppress
//     without a byte leaving; a second copy mid-transfer reports
//     .suppressedBusy (latest-wins, the superseded copy drops);
//   • the per-host images-rung default: pre-P-1 pinned_hosts.json
//     decodes unchanged, the preference survives a re-pair, and the
//     setter refuses unknown hashes.
//
// NOT here, deliberately: the live joint leg (real NSPasteboard ↔
// Mutter clipboard) waits on J-G4a.

final class ClipboardImageClientGateTests: XCTestCase {

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

    // MARK: Leg 1 — key 12 on the spine; the core default declares

    func testCapabilityKeyTwelveOnTheSpineAndCoreDefaultDeclares() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        XCTAssertEqual(base.first, 0xA8)
        var expected = base
        expected[0] = 0xA9
        expected += [0x0C, 0xF5]
        let declared = Capabilities.wireDefault.declaringClipboardImages()
        XCTAssertEqual(try declared.encodeCbor(), expected,
                       "key 12 = frozen wireDefault bytes + `0C F5`")

        XCTAssertTrue(declared.intersecting(declared).clipboardImages)
        XCTAssertFalse(
            declared.intersecting(.wireDefault).clipboardImages)

        // The agreed gate is 10 ∧ 12 — and NEVER key 11: the consent
        // tiers do not couple image sync to file consent.
        let imagesTier = Capabilities.wireDefault
            .declaringClipboardText().declaringClipboardImages()
        XCTAssertTrue(
            imagesTier.intersecting(imagesTier).clipboardImagesAgreed,
            "10∧12 agree with NO key 11 anywhere")
        XCTAssertFalse(
            declared.intersecting(declared).clipboardImagesAgreed,
            "key 12 without key 10 is not the feature")

        // The session core's DEFAULT declaration carries key 12
        // beside 9–11 (dialect); the images rung's consent defaults
        // OFF like text.
        let defaults = LyteUdpSessionCoreConfig()
        XCTAssertTrue(defaults.capabilities.clipboardImages)
        XCTAssertTrue(defaults.capabilities.clipboardText)
        XCTAssertTrue(defaults.capabilities.bulkTransfer)
        XCTAssertFalse(defaults.shareClipboardImages,
                       "the images rung defaults OFF — consent, tiered")
        print("P-1 client gate (spine): declaration = frozen bytes + "
            + "`0C F5`; agreed gate is 10∧12 (never 11); consent off")
    }

    // MARK: - The scripted images-tier host (the BulkHostStandIn
    // shape, grown the REAL Wire ClipboardImageChannel)

    private final class ImageHostStandIn: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        let connectionId: ConnectionId
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var bulkSeq: UInt16 = 0
        var ctrlArq: ArqEndpoint<HostClock>
        var bulkArq: ArqEndpoint<HostClock>
        var negotiator: CapabilityNegotiator
        private var handshakeOutbox: [[UInt8]] = []

        // The production lane logic — the host's real seam.
        var channel = ClipboardImageChannel()
        var book = ClipboardSyncBook()
        var imageRng = SplitMix64(seed: 0xB01)
        private var pendingSendMicros: UInt64 = 0

        // Evidence.
        var agreed: Capabilities?
        /// Bulk messages the channel did NOT claim — the file lane's.
        var bulkReceived: [BulkMessage] = []
        /// Images the channel applied, byte-exact.
        var applied: [(data: [UInt8], mime: String)] = []
        /// The channel's non-send, non-apply events, in order.
        var imageEvents: [ClipboardImageEvent] = []

        init(localCapabilities: Capabilities) {
            var rng = SplitMix64(seed: 0x0122)
            connectionId = ConnectionId.random(using: &rng)
            var config = ArqConfig()
            // The extra 16: this stand-in's envelopes carry the
            // connection-id extension, which ctrlPlaintextBudget does
            // not account for — a FULL segment (the 64 KiB chunks of
            // this gate, unlike the small answers of F-4's) would
            // overflow the 1152 B datagram ceiling by the extension's
            // width otherwise.
            config.maxSegmentBodyByteCount = min(
                config.maxSegmentBodyByteCount,
                ReliableCtrlEndpoint.ctrlPlaintextBudget
                    - ArqBounds.segmentHeaderByteCount - 16
            )
            ctrlArq = ArqEndpoint(channel: .ctrl, config: config)
            bulkArq = ArqEndpoint(channel: .bulkTransfer, config: config)
            negotiator = CapabilityNegotiator(
                role: .host, local: localCapabilities)
        }

        // NoiseHandshakeIO — answered in-process.

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
                message: try negotiator.start().encode(),
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

        /// One client datagram: unseal → the CHANNEL's ARQ → route.
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
                        try consumeBulkStream(message, nowMicros: nowMicros)
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

        /// The host session core's routing, in miniature: marker →
        /// channel; claimed id → channel; the rest → the file lane.
        private func consumeBulkStream(
            _ bytes: [UInt8], nowMicros: UInt64
        ) throws {
            if bytes.first == CtrlMessageType.clipboardImageCargo {
                let cargo = try ClipboardImageCargo.decode(bytes)
                try absorbChannelEvents(
                    channel.ingestCargo(cargo), nowMicros: nowMicros)
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
            bulkReceived.append(message)
        }

        private func absorbChannelEvents(
            _ events: [ClipboardImageEvent], nowMicros: UInt64
        ) throws {
            for event in events {
                switch event {
                case .send(let bytes):
                    try bulkArq.send(
                        message: bytes,
                        now: HostTimestamp(microseconds: nowMicros))
                case .applyImage(let data, let mime):
                    applied.append((data, mime))
                default:
                    imageEvents.append(event)
                }
            }
        }

        /// A host-side copy through the real channel — the
        /// noteHostClipboardImageChanged seam, in miniature.
        func shareImage(_ data: [UInt8], nowMicros: UInt64) throws {
            try absorbChannelEvents(
                channel.shareLocalImage(
                    data, sha256: Sha256.digest(data),
                    book: &book, rng: &imageRng
                ),
                nowMicros: nowMicros
            )
        }

        /// Raw chan-8 bytes (crafting hostile/foreign traffic).
        func injectBulk(_ message: [UInt8], nowMicros: UInt64) throws {
            try bulkArq.send(
                message: message,
                now: HostTimestamp(microseconds: nowMicros))
        }

        /// One host beat: due ARQ output from BOTH endpoints.
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
    }

    // MARK: - The client harness (the ClipboardClientGateTests shape)

    private final class Harness: @unchecked Sendable {
        let host: ImageHostStandIn
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        private var outbound: [[UInt8]] = []
        private var forwarded = 0
        let clock = VirtualClock()

        var events: [LyteUdpSessionEvent] = []

        init(
            host: ImageHostStandIn,
            coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
        ) throws {
            self.host = host
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_183,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: NoiseKeyPair.generate(),
                attempts: 3, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            let clock = self.clock
            let sender = TransportSender(crypto: crypto, transmit: {
                [weak self] datagram in
                self?.outbound.append(datagram)
                return true
            })
            self.core = LyteUdpSessionCore(
                demux: demux,
                sender: sender,
                config: coreConfig,
                now: { ClientTimestamp(microseconds: clock.value) },
                onSample: { _, _ in },
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
                              host.applied.count, host.imageEvents.count,
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
                        host.applied.count, host.imageEvents.count,
                        events.count) == before ? idle + 1 : 0
            }
        }

        var imageApplies: [(data: [UInt8], mime: String)] {
            events.compactMap {
                if case .hostClipboardImageChanged(let data, let mime) = $0 {
                    return (data, mime)
                }
                return nil
            }
        }

        var fileLaneEvents: [BulkMessage] {
            events.compactMap {
                if case .bulkMessageReceived(let message) = $0 {
                    return message
                }
                return nil
            }
        }
    }

    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private var imagesTier: Capabilities {
        .wireDefault.declaringClipboardText().declaringClipboardImages()
    }

    // MARK: Leg 2 — both directions in vivo + the boomerang proofs

    func testGateImageRoundTripsBothDirectionsAndEchoesSuppress() throws {
        let host = ImageHostStandIn(localCapabilities: imagesTier)
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true
        config.shareClipboardImages = true
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.agreed?.clipboardImagesAgreed, true,
                       "10∧12 must agree — and with NO key 11 in the "
                        + "stand-in's declaration")
        XCTAssertEqual(host.agreed?.bulkTransfer, false)
        XCTAssertTrue(harness.core.clipboardImagesNegotiated)
        XCTAssertTrue(harness.core.clipboardImageSharingEnabled)

        // Mac → host: a 150 KB "PNG" (3 chunks — the multi-chunk
        // geometry through real ARQ segmentation + Noise sealing).
        let macImage = makePayload(count: 150_000, seed: 0xF00D)
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(
                macImage, now: ClientTimestamp(microseconds: t)),
            .shared
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.applied.count, 1, "exactly one apply")
        XCTAssertEqual(host.applied.first?.data, macImage,
                       "byte-exact through seal/unseal + ARQ + chunks")
        XCTAssertEqual(host.applied.first?.mime, "image/png")
        XCTAssertEqual(
            harness.core.clipboardImageCounters.sharesCompleted, 1,
            "the digest verdict must round-trip back to the sender")

        // The boomerang proof, host side: the leaf's echo of that
        // apply suppresses through the stand-in's book — nothing
        // returns on the wire.
        try host.shareImage(macImage, nowMicros: t)
        XCTAssertEqual(host.imageEvents.compactMap { event -> ClipboardImageSuppressReason? in
            if case .suppressed(let reason) = event { return reason }
            return nil
        }, [.loopEcho])
        host.imageEvents.removeAll()
        try harness.settle(t: &t)
        XCTAssertTrue(harness.imageApplies.isEmpty,
                      "an apply echo must not boomerang as a share")

        // Host → Mac: a genuine host copy lands as the typed event,
        // byte-exact, and the stand-in hears the verdict.
        let hostImage = makePayload(count: 70_000, seed: 0xBEEF)
        try host.shareImage(hostImage, nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.imageApplies.count, 1)
        XCTAssertEqual(harness.imageApplies.first?.data, hostImage)
        XCTAssertEqual(harness.imageApplies.first?.mime, "image/png")
        XCTAssertTrue(host.imageEvents.contains { event in
            if case .shareCompleted = event { return true }
            return false
        })
        XCTAssertEqual(
            harness.core.clipboardImageCounters.imagesApplied, 1)

        // The boomerang proof, client side: the NSPasteboard echo of
        // that apply judges suppressedEcho through the client's book.
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(
                hostImage, now: ClientTimestamp(microseconds: t)),
            .suppressedEcho
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.applied.count, 1,
                       "the echo must never return as new cargo")

        print("P-1 client gate (in vivo): Mac image → host byte-exact "
            + "(\(macImage.count) B, 3 chunks); host image → typed event "
            + "byte-exact (\(hostImage.count) B); both echoes suppressed")
    }

    // MARK: Leg 3 — the consent tier gates both directions, live

    func testGateImagesRungOffMeansTypedDeclineAndNothingLeaves() throws {
        let host = ImageHostStandIn(localCapabilities: imagesTier)
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true   // Text only — the middle tier.
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertTrue(harness.core.clipboardImagesNegotiated,
                      "capability negotiates regardless — dialect")
        XCTAssertFalse(harness.core.clipboardImageSharingEnabled)

        // Nothing leaves.
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(
                [1, 2, 3], now: ClientTimestamp(microseconds: t)),
            .sharingDisabled
        )
        try harness.settle(t: &t)
        XCTAssertTrue(host.applied.isEmpty)

        // Nothing lands — but TYPED: the host's cargo draws
        // abort(declined) (the sender waits on a verdict; silence is
        // text's posture, not images').
        try host.shareImage(
            makePayload(count: 9_000, seed: 0x0FF), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.imageApplies.count, 0)
        XCTAssertTrue(host.imageEvents.contains { event in
            if case .shareAborted(let reason, let byRemote) = event {
                return reason == .declined && byRemote
            }
            return false
        }, "the decline must reach the sender as abort(declined)")
        XCTAssertEqual(
            harness.core.clipboardImageCounters.receivesRefused, 1)
        host.imageEvents.removeAll()

        // The live toggle opens both directions.
        harness.core.setClipboardImageSharing(true)
        XCTAssertTrue(harness.core.clipboardImageSharingEnabled)
        let image = makePayload(count: 5_000, seed: 0x0107)
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(
                image, now: ClientTimestamp(microseconds: t)),
            .shared
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.applied.count, 1)
        XCTAssertEqual(host.applied.first?.data, image)

        print("P-1 client gate (consent): images-off = quiet AND a "
            + "typed abort(declined); the live toggle opens both ways")
    }

    // MARK: Leg 4 — rule 3 per lane: 10∧12 vs 11 stay independent

    func testGateRuleThreePerLaneAndCeilingsAreWeather() throws {
        // A text-only host (key 10, no 12): the image share refuses
        // BEFORE a byte leaves, and a hostile 0x22 drops loud.
        let textHost = ImageHostStandIn(
            localCapabilities: .wireDefault.declaringClipboardText())
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true
        config.shareClipboardImages = true   // consent on — not enough
        let harness = try Harness(host: textHost, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertFalse(harness.core.clipboardImagesNegotiated)
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(
                [1, 2, 3], now: ClientTimestamp(microseconds: t)),
            .notNegotiated
        )

        // The hostile marker: dropped loud, no event, no reply.
        let cargo = try ClipboardImageCargo(
            transferId: 0xD1, mime: "image/png")
        try textHost.injectBulk(cargo.encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.imageApplies.count, 0)
        XCTAssertEqual(
            harness.core.snapshotCounters().clipboardDropsLoud, 1,
            "an unnegotiated 0x22 is a loud clipboard drop")

        // The mirror: an images-only agreement (NO key 11) — a bare
        // FILE offer on the open chan 8 is still ungated traffic:
        // dropped loud, never surfaced to the file lane's owner.
        let imagesHost = ImageHostStandIn(localCapabilities: imagesTier)
        var config2 = LyteUdpSessionCoreConfig()
        config2.shareClipboard = true
        config2.shareClipboardImages = true
        let harness2 = try Harness(host: imagesHost, coreConfig: config2)
        var t2: UInt64 = 1_000
        harness2.clock.value = t2
        try harness2.core.open(now: ClientTimestamp(microseconds: t2))
        try harness2.settle(t: &t2)
        XCTAssertFalse(harness2.core.bulkTransferNegotiated)
        XCTAssertTrue(harness2.core.clipboardImagesNegotiated)
        let fileOffer = try BulkOffer(
            transferId: 0xF11E, totalByteCount: 10,
            chunkByteCount: 4_096,
            sha256: [UInt8](repeating: 7, count: 32),
            name: "sneaky.bin"
        )
        try imagesHost.injectBulk(
            BulkMessage.offer(fileOffer).encode(), nowMicros: t2)
        try harness2.settle(t: &t2)
        XCTAssertEqual(harness2.fileLaneEvents.count, 0,
                       "a file offer must never surface on an "
                        + "images-only agreement")
        XCTAssertEqual(
            harness2.core.snapshotCounters().bulkDropsLoud, 1)

        // Ceilings are weather on the negotiated session: empty and
        // over-budget suppress without a byte leaving; a second copy
        // mid-transfer is .suppressedBusy (latest-wins).
        XCTAssertEqual(
            harness2.core.shareLocalClipboardImage(
                [], now: ClientTimestamp(microseconds: t2)),
            .overBudget(0)
        )
        let oneOver = [UInt8](
            repeating: 0xAA,
            count: ClipboardImageWire.maxImageByteCount + 1)
        XCTAssertEqual(
            harness2.core.shareLocalClipboardImage(
                oneOver, now: ClientTimestamp(microseconds: t2)),
            .overBudget(ClipboardImageWire.maxImageByteCount + 1)
        )
        XCTAssertEqual(
            harness2.core.shareLocalClipboardImage(
                makePayload(count: 60_000, seed: 0xAB),
                now: ClientTimestamp(microseconds: t2)),
            .shared
        )
        XCTAssertEqual(
            harness2.core.shareLocalClipboardImage(
                makePayload(count: 4, seed: 0xCD),
                now: ClientTimestamp(microseconds: t2)),
            .suppressedBusy,
            "a second copy mid-transfer drops — latest-wins, no queue"
        )
        try harness2.settle(t: &t2)
        XCTAssertEqual(imagesHost.applied.count, 1)

        print("P-1 client gate (rule 3): share refused pre-wire against "
            + "a text-only host; hostile 0x22 dropped loud; file offer "
            + "on an images-only chan 8 dropped loud; ceilings weather")
    }

    // MARK: Leg 5 — the per-host images-rung default's plumbing

    func testPinnedHostImagesPreferencePlumbing() throws {
        // A pre-P-1 file (no shareClipboardImages key) decodes
        // unchanged: the rung reads nil, meaning text-only.
        let keyHex = String(repeating: "ab", count: 32)
        let legacy = Data("""
        {"hosts":{"deadbeef":{"name":"pup","address":"10.0.0.249",\
        "port":41000,"staticPublicKeyHex":"\(keyHex)",\
        "pairedAt":"2026-07-21T09:00:00Z","shareClipboard":true}}}
        """.utf8)
        let store = try JSONDecoder().decode(
            PinnedHostStore.self, from: legacy)
        XCTAssertNil(store.hosts["deadbeef"]?.shareClipboardImages)
        XCTAssertEqual(store.hosts["deadbeef"]?.shareClipboard, true,
                       "CL-15's preference decodes beside the new one")

        // Round trip through the real save/load path, rung set.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1-pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var live = PinnedHostStore()
        let staticKey = (0..<32).map { UInt8($0) }
        live.pin(staticPublicKey: staticKey, name: "pup",
                 address: "10.0.0.249", port: 41_000,
                 pairedAt: "2026-07-22T15:00:00Z")
        let pkh = try XCTUnwrap(live.hosts.keys.first)
        XCTAssertTrue(live.setShareClipboardImages(
            publicKeyHash: pkh, share: true))
        try live.save(to: url)
        let reloaded = PinnedHostStore.load(from: url)
        XCTAssertEqual(
            reloaded.host(publicKeyHash: pkh)?.shareClipboardImages, true)

        // Text-only writes nil — the default posture keeps the file
        // clean (the setShareClipboard precedent).
        var cleaned = reloaded
        XCTAssertTrue(cleaned.setShareClipboardImages(
            publicKeyHash: pkh, share: false))
        XCTAssertNil(cleaned.hosts[pkh]?.shareClipboardImages)

        // A re-pair refreshes dial hints WITHOUT resetting the rung.
        var repaired = reloaded
        repaired.pin(staticPublicKey: staticKey, name: "pup",
                     address: "10.0.0.77", port: 41_131,
                     pairedAt: "2026-07-23T09:00:00Z")
        XCTAssertEqual(repaired.hosts[pkh]?.shareClipboardImages, true,
                       "a re-pair is a trust event, not a settings reset")

        // The setter refuses hashes it has never pinned.
        XCTAssertFalse(repaired.setShareClipboardImages(
            publicKeyHash: "0000", share: true))
    }
}
