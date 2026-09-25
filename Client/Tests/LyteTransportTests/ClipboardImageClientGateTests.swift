import XCTest
import LyteClientTestKit
import Foundation
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit

// Clipboard images (keys 10 ∧ 12) through the real core against a scripted
// host running the real Wire ClipboardImageChannel: a local image rides
// chan 8 as 0x22 cargo + offer + chunks and lands byte-exact, a host image
// surfaces as the typed event, and both apply echoes suppress. With the
// images rung off nothing leaves and an inbound marker draws
// abort(declined). Keys 11 and 12 gate independently per lane; empty and
// over-32 MiB copies suppress without a byte leaving, and a second copy
// mid-transfer reports .suppressedBusy.

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

    // MARK: - The scripted images-tier host (the REAL Wire
    // ClipboardImageChannel)

    fileprivate final class ImageHostStandIn: ScriptedHost {
        var peer: SealedCtrlPeer<HostClock>
        var handshakeOutbox: [[UInt8]] = []
        let localCapabilities: Capabilities

        // The production lane logic — the host's real seam.
        var channel = ClipboardImageChannel()
        var book = ClipboardSyncBook()
        var imageRng = SplitMix64(seed: 0xB01)

        // Evidence.
        var agreed: Capabilities?
        /// Bulk messages the channel did NOT claim — the file lane's.
        var bulkReceived: [BulkMessage] = []
        /// Images the channel applied, byte-exact.
        var applied: [(data: [UInt8], mime: String)] = []
        /// The channel's non-send, non-apply events, in order.
        var imageEvents: [ClipboardImageEvent] = []

        var progressMark: Int {
            bulkReceived.count + applied.count + imageEvents.count
        }

        init(localCapabilities: Capabilities) {
            var rng = SplitMix64(seed: 0x0122)
            peer = SealedCtrlPeer(
                connectionId: ConnectionId.random(using: &rng),
                carriesBulk: true)
            self.localCapabilities = localCapabilities
        }

        func didEstablish() throws {
            try declare(localCapabilities)
        }

        /// One client datagram: unseal → the CHANNEL's ARQ → route.
        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            switch try peer.absorb(bytes, nowMicros: nowMicros) {
            case .reliable(let envelope, _, let events):
                for case .message(_, let message) in events {
                    if envelope.channel == .bulkTransfer {
                        try consumeBulkStream(message, nowMicros: nowMicros)
                    } else {
                        dispatchCtrlPlain(message)
                    }
                }
            case .plain(_, let plaintext):
                dispatchCtrlPlain(plaintext)
            case .handshakeCompleted, .duplicate, .unopened:
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
                    message, book: &book, hasher: { Sha256() }
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
                    try injectBulk(bytes, nowMicros: nowMicros)
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
                    data, sha256: { Sha256.digest(data) },
                    book: &book, rng: &imageRng
                ),
                nowMicros: nowMicros
            )
        }

        private func dispatchCtrlPlain(_ message: [UInt8]) {
            guard message.first == CtrlMessageType.capabilityDeclaration,
                  let intersection = try? peer.receiveDeclaration(message)
            else { return }
            agreed = intersection
        }
    }

    // MARK: - The client harness

    private typealias Harness = ClientCoreHarness<ImageHostStandIn>

    private var imagesTier: Capabilities {
        .wireDefault.declaringClipboardText().declaringClipboardImages()
    }

    // MARK: Both directions in vivo + the boomerang proofs

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
        XCTAssertTrue(harness.core.control.clipboardImagesNegotiated)
        XCTAssertTrue(harness.core.control.clipboardImageSharingEnabled)

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
            harness.core.control.clipboardImageCounters.sharesCompleted, 1,
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
            harness.core.control.clipboardImageCounters.imagesApplied, 1)

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
    }

    // MARK: The consent tier gates both directions, live

    func testGateImagesRungOffMeansTypedDeclineAndNothingLeaves() throws {
        let host = ImageHostStandIn(localCapabilities: imagesTier)
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true   // Text only — the middle tier.
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertTrue(harness.core.control.clipboardImagesNegotiated,
                      "capability negotiates regardless — dialect")
        XCTAssertFalse(harness.core.control.clipboardImageSharingEnabled)

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
            harness.core.control.clipboardImageCounters.receivesRefused, 1)
        host.imageEvents.removeAll()

        // The live toggle opens both directions.
        harness.core.setClipboardImageSharing(true)
        XCTAssertTrue(harness.core.control.clipboardImageSharingEnabled)
        let image = makePayload(count: 5_000, seed: 0x0107)
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(
                image, now: ClientTimestamp(microseconds: t)),
            .shared
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.applied.count, 1)
        XCTAssertEqual(host.applied.first?.data, image)
    }

    // MARK: Rule 3 per lane: 10∧12 vs 11 stay independent

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
        XCTAssertFalse(harness.core.control.clipboardImagesNegotiated)
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
        XCTAssertFalse(harness2.core.control.agreedCapabilities?.bulkTransfer == true)
        XCTAssertTrue(harness2.core.control.clipboardImagesNegotiated)
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
    }

    // MARK: Hashing cost stays off refused images and the lock

    /// Records every digest the core finishes and the size of every
    /// slice it hashes; while finishing a whole-blob digest (a local
    /// copy), probes whether another thread can take the core lock.
    private final class HashProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var probesThatWaited = 0
        private var sizes: [Int] = []
        weak var core: LyteUdpSessionCore?

        var callCount: Int { lock.withLock { calls } }
        var lockedDuringHash: Int { lock.withLock { probesThatWaited } }
        var absorbedSizes: [Int] { lock.withLock { sizes } }

        func absorbed(_ count: Int) { lock.withLock { sizes.append(count) } }

        func finished(wholeBlob: Bool) {
            lock.withLock { calls += 1 }
            guard wholeBlob else { return }
            let done = DispatchSemaphore(value: 0)
            let core = self.core
            DispatchQueue.global().async {
                _ = core?.control.clipboardImageSharingEnabled
                done.signal()
            }
            if done.wait(timeout: .now() + 2) == .timedOut {
                lock.withLock { probesThatWaited += 1 }
            }
        }

        func makeHasher() -> any ClipboardImageHasher { Hasher(probe: self) }

        private struct Hasher: ClipboardImageHasher {
            let probe: HashProbe
            var sha = Sha256()
            var absorbCalls = 0
            mutating func absorb(_ bytes: ArraySlice<UInt8>) {
                absorbCalls += 1
                probe.absorbed(bytes.count)
                sha.update(bytes)
            }
            mutating func finish() -> [UInt8] {
                probe.finished(wholeBlob: absorbCalls == 1)
                return sha.finalized()
            }
        }
    }

    func testRefusedImagesAreNeverHashedAndHashingLeavesTheCoreLockFree()
        throws
    {
        let host = ImageHostStandIn(localCapabilities: imagesTier)
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true
        config.shareClipboardImages = true
        let probe = HashProbe()
        let harness = try Harness(
            host: host, coreConfig: config,
            imageHasher: { probe.makeHasher() })
        probe.core = harness.core
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        let now = ClientTimestamp(microseconds: t)

        let oneOver = [UInt8](
            repeating: 0x5A,
            count: ClipboardImageWire.maxImageByteCount + 1)
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(oneOver, now: now),
            .overBudget(oneOver.count))
        harness.core.setClipboardImageSharing(false)
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(
                makePayload(count: 3_000, seed: 0x31), now: now),
            .sharingDisabled)
        XCTAssertEqual(probe.callCount, 0,
                       "a refused image must never be hashed")
        XCTAssertEqual(
            harness.core.control.clipboardImageCounters.sharesSuppressed, 1,
            "the pre-digest ceiling refusal still counts as suppressed")

        harness.core.setClipboardImageSharing(true)
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(
                makePayload(count: 3_000, seed: 0x32), now: now),
            .shared)
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(probe.lockedDuringHash, 0,
                       "the digest must run outside the core lock")
        XCTAssertEqual(
            harness.core.shareLocalClipboardImage(oneOver, now: now),
            .suppressedBusy,
            "an over-ceiling copy mid-transfer keeps the busy verdict")
        XCTAssertEqual(probe.callCount, 1)
        try harness.settle(t: &t)
        XCTAssertEqual(host.applied.count, 1)
    }

    /// An incoming image is hashed one chunk per delivered message, so
    /// the receive thread never hashes a whole blob under the core lock.
    func testIncomingImageIsHashedOneChunkAtATime() throws {
        let host = ImageHostStandIn(localCapabilities: imagesTier)
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true
        config.shareClipboardImages = true
        let probe = HashProbe()
        let harness = try Harness(
            host: host, coreConfig: config,
            imageHasher: { probe.makeHasher() })
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        let hostImage = makePayload(count: 150_000, seed: 0xCAFE)
        try host.shareImage(hostImage, nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.imageApplies.first?.data, hostImage)
        XCTAssertEqual(probe.absorbedSizes, [65_536, 65_536, 18_928])
        XCTAssertEqual(probe.callCount, 1)
    }
}

fileprivate extension ClientCoreHarness
where Host == ClipboardImageClientGateTests.ImageHostStandIn {
    convenience init(
        host: Host,
        coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig(),
        imageHasher: @escaping @Sendable () -> any ClipboardImageHasher = {
            Sha256()
        }
    ) throws {
        try self.init(
            host: host, hostPort: 41_183,
            coreConfig: coreConfig, imageHasher: imageHasher)
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
