import XCTest
import LyteWire
import LyteWireTestKit

// The clipboard-image channel's laws (P-1, clipboard v2): a full
// marker → offer → chunks → digest-verdict loopback between two
// channels (the ends hash — TestKit's Sha256 plays both), the
// suppression ladder, the refusal ladder with its abort answers, the
// refused-id swallow, lane-occupancy discipline, and the book
// interplay that keeps an applied image from boomeranging.

final class ClipboardImageChannelTests: XCTestCase {

    private struct CountingRng: RandomNumberGenerator {
        var value: UInt64 = 0x1000
        mutating func next() -> UInt64 {
            defer { value += 1 }
            return value
        }
    }

    /// Two channels wired back to back: every `.send` from one side
    /// is decoded and delivered to the other (marker bytes to
    /// `ingestCargo`, bulk bytes to `ingest`), until both queues
    /// drain. Non-send events collect per side.
    private struct Loop {
        var channels: [ClipboardImageChannel]
        var books = [ClipboardSyncBook(), ClipboardSyncBook()]
        var events: [[ClipboardImageEvent]] = [[], []]
        /// Bytes claimed by neither lane on delivery — the file
        /// lane's, in a real core; a routing leak in these tests.
        var unclaimed: [[UInt8]] = []

        init(ceiling: Int = ClipboardImageWire.maxImageByteCount) {
            channels = [
                ClipboardImageChannel(imageByteCeiling: ceiling),
                ClipboardImageChannel(imageByteCeiling: ceiling),
            ]
        }

        mutating func absorb(
            _ produced: [ClipboardImageEvent], at side: Int,
            into queues: inout [[[UInt8]]]
        ) {
            for event in produced {
                if case .send(let bytes) = event {
                    queues[1 - side].append(bytes)
                } else {
                    events[side].append(event)
                }
            }
        }

        /// Runs the exchange to quiescence starting from one side's
        /// already-produced events.
        mutating func pump(
            _ initial: [ClipboardImageEvent], from side: Int
        ) {
            var queues: [[[UInt8]]] = [[], []]
            absorb(initial, at: side, into: &queues)
            while !queues[0].isEmpty || !queues[1].isEmpty {
                for target in 0...1 {
                    guard !queues[target].isEmpty else { continue }
                    let bytes = queues[target].removeFirst()
                    let produced = deliver(bytes, to: target)
                    absorb(produced, at: target, into: &queues)
                }
            }
        }

        mutating func deliver(
            _ bytes: [UInt8], to side: Int
        ) -> [ClipboardImageEvent] {
            if bytes.first == CtrlMessageType.clipboardImageCargo {
                guard let cargo = try? ClipboardImageCargo.decode(bytes)
                else {
                    XCTFail("undecodable marker bytes")
                    return []
                }
                return channels[side].ingestCargo(cargo)
            }
            guard let message = try? BulkMessage.decode(bytes) else {
                XCTFail("undecodable bulk bytes")
                return []
            }
            guard channels[side].claims(message) else {
                unclaimed.append(bytes)
                return []
            }
            return channels[side].ingest(
                message, book: &books[side], sha256: Sha256.digest
            )
        }

        mutating func share(
            _ data: [UInt8], from side: Int,
            rng: inout some RandomNumberGenerator
        ) {
            let produced = channels[side].shareLocalImage(
                data, sha256: Sha256.digest(data),
                book: &books[side], rng: &rng
            )
            pump(produced, from: side)
        }
    }

    private func patterned(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    }

    // MARK: The happy path, both geometries

    func testLoopbackLandsShaExactSingleChunk() {
        var loop = Loop()
        var rng = CountingRng()
        let image = patterned(4_000)
        loop.share(image, from: 0, rng: &rng)

        // The sender saw the start and the digest-verified finish.
        guard case .shareStarted(let id, let byteCount)?
                = loop.events[0].first else {
            return XCTFail("no shareStarted: \(loop.events[0])")
        }
        XCTAssertNotEqual(id, 0)
        XCTAssertEqual(byteCount, image.count)
        XCTAssertTrue(loop.events[0].contains(
            .shareCompleted(transferId: id, byteCount: image.count)
        ))

        // The receiver applied EXACTLY the bytes, mime pinned.
        XCTAssertEqual(
            loop.events[1],
            [.applyImage(data: image, mime: "image/png")]
        )
        XCTAssertTrue(loop.unclaimed.isEmpty,
                      "clipboard cargo leaked to the file lane")

        // Counters and lane states settle clean.
        XCTAssertEqual(loop.channels[0].counters.sharesStarted, 1)
        XCTAssertEqual(loop.channels[0].counters.sharesCompleted, 1)
        XCTAssertEqual(loop.channels[1].counters.imagesApplied, 1)
        XCTAssertFalse(loop.channels[0].isSendActive)
        XCTAssertFalse(loop.channels[1].isReceiveActive)

        // The book interplay: the receiver's OS echo suppresses; the
        // sender's identical re-copy dedupes.
        let key = ClipboardImageWire.bookKey(sha256: Sha256.digest(image))
        XCTAssertEqual(loop.books[1].admitLocalChange(bytes: key),
                       .suppressEcho)
        XCTAssertEqual(loop.books[0].admitLocalChange(bytes: key),
                       .suppressDuplicate)
    }

    func testLoopbackLandsShaExactMultiChunk() {
        // Three chunks: 2 × 64 KiB + a 1-byte tail — the geometry
        // corner (final partial chunk) through the whole loop.
        var loop = Loop()
        var rng = CountingRng()
        let image = patterned(2 * 65_536 + 1)
        loop.share(image, from: 0, rng: &rng)

        XCTAssertEqual(
            loop.events[1],
            [.applyImage(data: image, mime: "image/png")]
        )
        XCTAssertEqual(loop.channels[0].counters.sharesCompleted, 1)
        XCTAssertTrue(loop.unclaimed.isEmpty)
    }

    func testConsecutiveSharesBothDirections() {
        // The lanes are per-direction: a completed share frees the
        // lane, and the reverse direction is independent.
        var loop = Loop()
        var rng = CountingRng()
        let first = patterned(1_000)
        let second = patterned(2_000)
        let reply = patterned(3_000)
        loop.share(first, from: 0, rng: &rng)
        loop.share(second, from: 0, rng: &rng)
        loop.share(reply, from: 1, rng: &rng)

        XCTAssertEqual(loop.channels[0].counters.sharesCompleted, 2)
        XCTAssertEqual(loop.channels[1].counters.imagesApplied, 2)
        XCTAssertEqual(loop.channels[1].counters.sharesCompleted, 1)
        XCTAssertEqual(loop.channels[0].counters.imagesApplied, 1)
        XCTAssertTrue(loop.events[0].contains(
            .applyImage(data: reply, mime: "image/png")
        ))
    }

    // MARK: The suppression ladder (local copies that never leave)

    func testSuppressionLadder() {
        var channel = ClipboardImageChannel(imageByteCeiling: 4_096)
        var book = ClipboardSyncBook()
        var rng = CountingRng()

        // Empty read — a leaf bug, loud in the counter.
        XCTAssertEqual(
            channel.shareLocalImage([], sha256: Sha256.digest([]),
                                    book: &book, rng: &rng),
            [.suppressed(.emptyImage)]
        )

        // Over the ceiling: suppressed, never sent (the test seam's
        // small ceiling stands in for 32 MiB).
        let big = patterned(4_097)
        XCTAssertEqual(
            channel.shareLocalImage(big, sha256: Sha256.digest(big),
                                    book: &book, rng: &rng),
            [.suppressed(.overBudget(4_097))]
        )

        // The echo: a remote apply's OS event never boomerangs.
        let image = patterned(64)
        let key = ClipboardImageWire.bookKey(sha256: Sha256.digest(image))
        book.noteRemoteApplied(bytes: key)
        XCTAssertEqual(
            channel.shareLocalImage(image, sha256: Sha256.digest(image),
                                    book: &book, rng: &rng),
            [.suppressed(.loopEcho)]
        )

        // Send lane busy: a share in flight, a second copy drops
        // (latest-wins is v2's documented posture).
        let inFlight = patterned(128)
        let events = channel.shareLocalImage(
            inFlight, sha256: Sha256.digest(inFlight),
            book: &book, rng: &rng
        )
        XCTAssertTrue(events.contains { event in
            if case .shareStarted = event { return true }
            return false
        })
        XCTAssertTrue(channel.isSendActive)
        let superseded = patterned(129)
        XCTAssertEqual(
            channel.shareLocalImage(
                superseded, sha256: Sha256.digest(superseded),
                book: &book, rng: &rng
            ),
            [.suppressed(.sendBusy)]
        )
        XCTAssertEqual(channel.counters.sharesSuppressed, 4)
        XCTAssertEqual(channel.counters.sharesStarted, 1)
    }

    // MARK: The refusal ladder (incoming cargo that never lands)

    private func abortIn(
        _ events: [ClipboardImageEvent]
    ) -> BulkAbort? {
        for event in events {
            guard case .send(let bytes) = event,
                  case .abort(let abort)? = try? BulkMessage.decode(bytes)
            else { continue }
            return abort
        }
        return nil
    }

    func testForeignMimeDrawsDeclinedAndSwallowsTheOffer() throws {
        var channel = ClipboardImageChannel()
        var book = ClipboardSyncBook()
        let cargo = try ClipboardImageCargo(
            transferId: 42, mime: "image/tiff"
        )
        let events = channel.ingestCargo(cargo)
        XCTAssertEqual(events.first,
                       .refused(.unsupportedMime("image/tiff")))
        let abort = abortIn(events)
        XCTAssertEqual(abort?.transferId, 42)
        XCTAssertEqual(abort?.reason, .declined)
        XCTAssertFalse(channel.isReceiveActive)

        // The offer was already in flight behind the marker when the
        // abort left — claimed, swallowed, and the id retires with it.
        let offer = try BulkOffer(
            transferId: 42, totalByteCount: 10,
            chunkByteCount: ClipboardImageWire.chunkByteCount,
            sha256: [UInt8](repeating: 1, count: 32),
            name: "clipboard.png", mimeHint: "image/tiff"
        )
        XCTAssertTrue(channel.claims(.offer(offer)))
        XCTAssertEqual(
            channel.ingest(.offer(offer), book: &book,
                           sha256: Sha256.digest),
            []
        )
        XCTAssertFalse(channel.claims(.offer(offer)),
                       "a swallowed offer retires its refused id")
    }

    func testCaseInsensitiveMimeIsAdmitted() throws {
        var channel = ClipboardImageChannel()
        let cargo = try ClipboardImageCargo(
            transferId: 7, mime: "IMAGE/PNG"
        )
        XCTAssertEqual(channel.ingestCargo(cargo), [])
        XCTAssertTrue(channel.isReceiveActive)
    }

    func testOverBudgetOfferDrawsDeclined() throws {
        var channel = ClipboardImageChannel(imageByteCeiling: 1_024)
        var book = ClipboardSyncBook()
        let cargo = try ClipboardImageCargo(
            transferId: 9, mime: "image/png"
        )
        XCTAssertEqual(channel.ingestCargo(cargo), [])
        // The marker carries no size — the ceiling is enforced
        // against the OFFER, never trusted.
        let offer = try BulkOffer(
            transferId: 9, totalByteCount: 1_025,
            chunkByteCount: ClipboardImageWire.chunkByteCount,
            sha256: [UInt8](repeating: 2, count: 32),
            name: "clipboard.png", mimeHint: "image/png"
        )
        let events = channel.ingest(.offer(offer), book: &book,
                                    sha256: Sha256.digest)
        XCTAssertEqual(events.first, .refused(.overBudget(1_025)))
        XCTAssertEqual(abortIn(events)?.reason, .declined)
        XCTAssertFalse(channel.isReceiveActive)
        XCTAssertEqual(channel.counters.receivesRefused, 1)
    }

    func testReceiveLaneBusyDrawsBusy() throws {
        var channel = ClipboardImageChannel()
        let first = try ClipboardImageCargo(
            transferId: 11, mime: "image/png"
        )
        XCTAssertEqual(channel.ingestCargo(first), [])
        // A second marker while the first is pending: abort(busy).
        let second = try ClipboardImageCargo(
            transferId: 12, mime: "image/png"
        )
        let events = channel.ingestCargo(second)
        XCTAssertEqual(events.first, .refused(.receiveBusy))
        let abort = abortIn(events)
        XCTAssertEqual(abort?.transferId, 12)
        XCTAssertEqual(abort?.reason, .busy)
        // The first intent survives untouched.
        XCTAssertTrue(channel.isReceiveActive)
    }

    func testDeclineCargoIsTheCallerTierAnswer() throws {
        // The consent tier lives at the CALLER; the channel supplies
        // the typed refusal (decline + swallow) on request.
        var channel = ClipboardImageChannel()
        var book = ClipboardSyncBook()
        let cargo = try ClipboardImageCargo(
            transferId: 13, mime: "image/png"
        )
        let events = channel.declineCargo(cargo)
        XCTAssertEqual(abortIn(events)?.reason, .declined)
        XCTAssertFalse(channel.isReceiveActive)
        let offer = try BulkOffer(
            transferId: 13, totalByteCount: 10,
            chunkByteCount: ClipboardImageWire.chunkByteCount,
            sha256: [UInt8](repeating: 3, count: 32),
            name: "clipboard.png", mimeHint: "image/png"
        )
        XCTAssertTrue(channel.claims(.offer(offer)))
        XCTAssertEqual(
            channel.ingest(.offer(offer), book: &book,
                           sha256: Sha256.digest),
            []
        )
    }

    func testMarkerWithoutItsOfferIsAViolation() throws {
        // Ordered carriage makes anything between marker and offer a
        // peer bug — the typed violation answer plus the abort.
        var channel = ClipboardImageChannel()
        var book = ClipboardSyncBook()
        let cargo = try ClipboardImageCargo(
            transferId: 21, mime: "image/png"
        )
        XCTAssertEqual(channel.ingestCargo(cargo), [])
        let chunk = try BulkChunk(
            transferId: 21, chunkIndex: 0, data: [1, 2, 3]
        )
        XCTAssertTrue(channel.claims(.chunk(chunk)))
        let events = channel.ingest(.chunk(chunk), book: &book,
                                    sha256: Sha256.digest)
        guard case .violated(let violation)? = events.first else {
            return XCTFail("expected violation: \(events)")
        }
        XCTAssertEqual(
            violation,
            .unexpectedMessage(type: CtrlMessageType.bulkChunk)
        )
        XCTAssertEqual(abortIn(events)?.reason, .protocolViolation)
        XCTAssertFalse(channel.isReceiveActive)
    }

    // MARK: Remote aborts against the send lane

    func testRemoteDeclineAbortsTheShare() throws {
        var channel = ClipboardImageChannel()
        var book = ClipboardSyncBook()
        var rng = CountingRng()
        let image = patterned(64)
        let events = channel.shareLocalImage(
            image, sha256: Sha256.digest(image), book: &book, rng: &rng
        )
        guard case .shareStarted(let id, _)? = events.dropFirst().first
        else {
            return XCTFail("expected shareStarted: \(events)")
        }
        let abort = try BulkAbort(transferId: id, reason: .declined)
        XCTAssertTrue(channel.claims(.abort(abort)))
        XCTAssertEqual(
            channel.ingest(.abort(abort), book: &book,
                           sha256: Sha256.digest),
            [.shareAborted(reason: .declined, byRemote: true)]
        )
        XCTAssertFalse(channel.isSendActive)
        XCTAssertEqual(channel.counters.sharesAborted, 1)

        // An aborted share never touched the book: the same image
        // still shares (the peer never applied it).
        XCTAssertEqual(
            book.admitLocalChange(
                bytes: ClipboardImageWire.bookKey(
                    sha256: Sha256.digest(image)
                )
            ),
            .share
        )
    }

    // MARK: Routing

    func testChannelClaimsOnlyItsOwnTransfers() throws {
        var channel = ClipboardImageChannel()
        // A file-lane offer (no marker preceded it) is not ours.
        let offer = try BulkOffer(
            transferId: 777, totalByteCount: 10,
            chunkByteCount: ClipboardImageWire.chunkByteCount,
            sha256: [UInt8](repeating: 4, count: 32),
            name: "report.pdf", mimeHint: "application/pdf"
        )
        XCTAssertFalse(channel.claims(.offer(offer)))

        // After a marker, that id (and only that id) is ours.
        let cargo = try ClipboardImageCargo(
            transferId: 778, mime: "image/png"
        )
        _ = channel.ingestCargo(cargo)
        let ours = try BulkOffer(
            transferId: 778, totalByteCount: 10,
            chunkByteCount: ClipboardImageWire.chunkByteCount,
            sha256: [UInt8](repeating: 5, count: 32),
            name: "clipboard.png", mimeHint: "image/png"
        )
        XCTAssertTrue(channel.claims(.offer(ours)))
        XCTAssertFalse(channel.claims(.offer(offer)))
    }
}
