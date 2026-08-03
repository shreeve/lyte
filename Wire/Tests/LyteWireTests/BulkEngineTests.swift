import XCTest
import LyteCore
import LyteWire
import LyteWireTestKit

// The W10 transfer engines in virtual time: happy path, backpressure
// under a stingy/slow receiver, teardown-resume completing sha-exact,
// aborts from every seat, the whole remote-violation surface, and the
// local-API misuse throws. The engines are event-driven by design (no
// timers — ARQ owns retransmission below), so "virtual time" here is
// the causal order of actions, with storage confirmations deferred
// wherever the test wants the disk to be slow.

final class BulkEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// A 5-chunk offer: 4 × 4096 + 1000 = 17,384 bytes of counting
    /// payload.
    private func makeFixture(
        chunkCount: Int = 5, finalChunkBytes: Int = 1_000
    ) -> (offer: BulkOffer, payload: [UInt8]) {
        let total = (chunkCount - 1) * 4_096 + finalChunkBytes
        let payload = (0..<total).map { UInt8($0 & 0xFF) }
        let offer = try! BulkOffer(
            transferId: 0xB01D_FACE_0000_0001,
            totalByteCount: UInt64(total),
            chunkByteCount: 4_096,
            sha256: Sha256.digest(payload),
            name: "fixture.bin",
            mimeHint: "application/octet-stream"
        )
        return (offer, payload)
    }

    private func chunkData(
        _ offer: BulkOffer, _ payload: [UInt8], _ index: UInt64
    ) -> [UInt8] {
        let start = Int(index) * Int(offer.chunkByteCount)
        let size = offer.byteCount(ofChunk: index)!
        return Array(payload[start..<start + size])
    }

    private func emissions(
        _ actions: [BulkSendEngine.Action]
    ) -> [BulkMessage] {
        actions.compactMap {
            if case .emit(let message) = $0 { return message }
            return nil
        }
    }

    private func emissions(
        _ actions: [BulkReceiveEngine.Action]
    ) -> [BulkMessage] {
        actions.compactMap {
            if case .emit(let message) = $0 { return message }
            return nil
        }
    }

    private func reads(
        _ actions: [BulkSendEngine.Action]
    ) -> [UInt64] {
        actions.compactMap {
            if case .readChunk(let index) = $0 { return index }
            return nil
        }
    }

    private func stores(
        _ actions: [BulkReceiveEngine.Action]
    ) -> [(index: UInt64, data: [UInt8])] {
        actions.compactMap {
            if case .store(let index, let data) = $0 {
                return (index, data)
            }
            return nil
        }
    }

    // MARK: - Happy path

    func testHappyPathSingleSession() throws {
        let (offer, payload) = makeFixture()
        var harness = BulkTransferHarness(
            offer: offer, payload: payload, window: 16
        )
        let result = try harness.runSession()
        XCTAssertEqual(result.senderFinalState, .completed)
        XCTAssertEqual(result.receiverFinalState, .completed)
        // Sender: the offer + exactly one message per chunk (in-order
        // carriage + a generous window = no retransmission layer here).
        XCTAssertEqual(result.senderMessages.count, 1 + 5)
        XCTAssertEqual(result.senderMessages[0][0],
                       CtrlMessageType.bulkOffer)
        for message in result.senderMessages.dropFirst() {
            XCTAssertEqual(message[0], CtrlMessageType.bulkChunk)
        }
        // Receiver: accept first, complete last.
        XCTAssertEqual(result.receiverMessages.first?[0],
                       CtrlMessageType.bulkAccept)
        XCTAssertEqual(result.receiverMessages.last?[0],
                       CtrlMessageType.bulkComplete)
        // The sha-exact bar.
        XCTAssertEqual(harness.assembledDigest(), offer.sha256)
        // Nothing left to resume: the transfer finished.
        XCTAssertTrue(harness.resumeBook.isEmpty)
    }

    /// A one-chunk blob (the smallest transfer that can exist).
    func testSingleChunkTransfer() throws {
        let (offer, payload) = makeFixture(
            chunkCount: 1, finalChunkBytes: 17
        )
        var harness = BulkTransferHarness(
            offer: offer, payload: payload, window: 16
        )
        let result = try harness.runSession()
        XCTAssertEqual(result.senderFinalState, .completed)
        XCTAssertEqual(result.receiverFinalState, .completed)
        XCTAssertEqual(harness.assembledDigest(), offer.sha256)
    }

    // MARK: - Backpressure

    /// Window 1, storage confirmed one chunk at a time: the transfer
    /// strictly alternates read → chunk → store → ack, with never
    /// more than one chunk in flight — the stingiest receiver there
    /// is, honored end to end.
    func testBackpressureWindowOneLockstep() throws {
        let (offer, payload) = makeFixture()
        var sender = BulkSendEngine(offer: offer)
        var receiver = BulkReceiveEngine(
            config: BulkTransferConfig(receiveWindowChunks: 1)
        )

        let offerEmit = emissions(try sender.begin())
        let offered = receiver.ingest(offerEmit[0])
        guard case .offered(let surfaced, let resuming)? =
            offered.first else {
            return XCTFail("no consent surfacing")
        }
        XCTAssertEqual(surfaced, offer)
        XCTAssertFalse(resuming)
        var toSender = emissions(try receiver.accept())
        XCTAssertEqual(toSender.count, 1)

        var storedOrder: [UInt64] = []
        var completeSeen = false
        var guardCounter = 0
        while !toSender.isEmpty {
            guardCounter += 1
            XCTAssertLessThan(guardCounter, 40, "livelock")
            var senderActions: [BulkSendEngine.Action] = []
            for message in toSender {
                senderActions += sender.ingest(message)
            }
            toSender = []
            let requested = reads(senderActions)
            XCTAssertLessThanOrEqual(
                requested.count, 1,
                "window 1 must never request read-ahead"
            )
            var chunkEmits = emissions(senderActions)
            for index in requested {
                chunkEmits += emissions(try sender.supplyChunk(
                    index: index,
                    data: chunkData(offer, payload, index)
                ))
            }
            for message in chunkEmits {
                let actions = receiver.ingest(message)
                let pendingStores = stores(actions)
                XCTAssertLessThanOrEqual(
                    pendingStores.count, 1,
                    "window 1 must never buffer two stores"
                )
                XCTAssertTrue(emissions(actions).isEmpty,
                              "no ack before the store confirms")
                for (index, data) in pendingStores {
                    XCTAssertEqual(
                        data, chunkData(offer, payload, index)
                    )
                    storedOrder.append(index)
                    let after = try receiver.chunkStored(index: index)
                    toSender += emissions(after)
                    if after.contains(.verify) {
                        let verdict = try receiver.verificationResult(
                            digest: Sha256.digest(payload)
                        )
                        toSender += emissions(verdict)
                    }
                }
            }
            for message in toSender
            where message.encode()[0] == CtrlMessageType.bulkComplete {
                completeSeen = true
            }
        }
        // Drain the final receiver messages into the sender.
        XCTAssertTrue(completeSeen || sender.state == .completed)
        XCTAssertEqual(storedOrder, [0, 1, 2, 3, 4],
                       "in-order carriage stores in order")
        XCTAssertEqual(receiver.state, .completed)
        XCTAssertEqual(sender.state, .completed)
    }

    /// Window 4, a slow disk that defers every confirmation: the
    /// sender's issued reads never outrun granted credit, so chunks
    /// in flight (read but unconfirmed) stay ≤ the window — memory
    /// bounded on BOTH ends by the same number.
    func testBackpressureSlowDiskNeverExceedsWindow() throws {
        let (offer, payload) = makeFixture(
            chunkCount: 8, finalChunkBytes: 4_096
        )
        let window = 4
        var sender = BulkSendEngine(offer: offer)
        var receiver = BulkReceiveEngine(
            config: BulkTransferConfig(receiveWindowChunks: window)
        )

        _ = receiver.ingest(emissions(try sender.begin())[0])
        var senderActions: [BulkSendEngine.Action] = []
        for message in emissions(try receiver.accept()) {
            senderActions += sender.ingest(message)
        }
        // The opening grant admits exactly the window.
        XCTAssertEqual(reads(senderActions), [0, 1, 2, 3])
        XCTAssertEqual(sender.creditTotal, UInt64(window))

        // Supply all four; the receiver banks four pending stores and
        // says nothing (no acks before durability).
        var pendingConfirms: [UInt64] = []
        for index in reads(senderActions) {
            for message in emissions(try sender.supplyChunk(
                index: index, data: chunkData(offer, payload, index)
            )) {
                let actions = receiver.ingest(message)
                XCTAssertTrue(emissions(actions).isEmpty)
                pendingConfirms += stores(actions).map(\.index)
            }
        }
        XCTAssertEqual(pendingConfirms, [0, 1, 2, 3])
        // Sender is starved — no credit, no reads, nothing in flight
        // beyond the window.
        XCTAssertEqual(sender.issuedReadCount, UInt64(window))

        // Confirm store 0: credit 5 < 4 + step(2) — no ack yet.
        XCTAssertTrue(
            emissions(try receiver.chunkStored(index: 0)).isEmpty
        )
        // Confirm store 1: credit 6 ≥ 6 — the refresh lands, and the
        // sender reads exactly two more.
        let refresh = emissions(try receiver.chunkStored(index: 1))
        XCTAssertEqual(refresh.count, 1)
        senderActions = []
        for message in refresh {
            senderActions += sender.ingest(message)
        }
        XCTAssertEqual(reads(senderActions), [4, 5])
        XCTAssertEqual(sender.creditTotal, 6)
        XCTAssertLessThanOrEqual(
            sender.issuedReadCount - 2, UInt64(window),
            "in-flight reads bounded by the window"
        )
    }

    /// A stale grant (lower credit than already granted) never claws
    /// credit back.
    func testStaleCreditNeverRegresses() throws {
        let (offer, payload) = makeFixture()
        _ = payload
        var sender = BulkSendEngine(offer: offer)
        _ = try sender.begin()
        _ = sender.ingest(.accept(try BulkAccept(
            transferId: offer.transferId, creditTotal: 4
        )))
        XCTAssertEqual(sender.creditTotal, 4)
        let actions = sender.ingest(.ack(try BulkAck(
            transferId: offer.transferId,
            creditTotal: 2,
            possession: BulkChunkMap(contiguousCount: 1)
        )))
        XCTAssertEqual(sender.creditTotal, 4,
                       "credit is a monotonic max")
        XCTAssertTrue(reads(actions).isEmpty,
                      "no new headroom, no new reads")
        XCTAssertEqual(sender.state, .transferring)
    }

    // MARK: - Teardown, resume, sha-exact completion

    func testTeardownResumeCompletesShaExact() throws {
        let (offer, payload) = makeFixture()
        var harness = BulkTransferHarness(
            offer: offer, payload: payload, window: 16
        )
        // Session 1 dies after the receiver ingests the offer plus
        // two chunks.
        let first = try harness.runSession(receiverIngestLimit: 3)
        XCTAssertNotEqual(first.receiverFinalState, .completed)
        XCTAssertEqual(harness.resumeBook.count, 1)
        XCTAssertEqual(
            harness.resumeBook[0].possession.contiguousCount, 2
        )
        // Session 2 resumes and finishes.
        let second = try harness.runSession()
        XCTAssertEqual(second.senderFinalState, .completed)
        XCTAssertEqual(second.receiverFinalState, .completed)
        // Only the three missing chunks travel again.
        let resent = second.senderMessages.filter {
            $0[0] == CtrlMessageType.bulkChunk
        }
        XCTAssertEqual(resent.count, 3)
        XCTAssertEqual(harness.assembledDigest(), offer.sha256)
        XCTAssertTrue(harness.resumeBook.isEmpty)
    }

    /// A holed possession map (extras beyond the prefix): the sender
    /// re-dispatches exactly the holes, never the held chunks.
    func testResumeWithHolesDispatchesOnlyMissing() throws {
        let (offer, payload) = makeFixture(
            chunkCount: 8, finalChunkBytes: 4_096
        )
        var harness = BulkTransferHarness(
            offer: offer, payload: payload, window: 16,
            initialPossession: BulkPossession(
                contiguousCount: 3, extras: [5, 6]
            )
        )
        let result = try harness.runSession()
        XCTAssertEqual(result.senderFinalState, .completed)
        XCTAssertEqual(result.receiverFinalState, .completed)
        let sentChunks = result.senderMessages.filter {
            $0[0] == CtrlMessageType.bulkChunk
        }
        XCTAssertEqual(sentChunks.count, 3, "chunks 3, 4, 7 only")
        XCTAssertEqual(harness.assembledDigest(), offer.sha256)
    }

    /// Resume when possession is already complete (the teardown ate
    /// only the finish): no chunks travel; the digest still gates.
    func testResumeAlreadyCompleteVerifiesWithoutChunks() throws {
        let (offer, payload) = makeFixture()
        var harness = BulkTransferHarness(
            offer: offer, payload: payload, window: 16,
            initialPossession: BulkPossession(contiguousCount: 5)
        )
        let result = try harness.runSession()
        XCTAssertEqual(result.senderFinalState, .completed)
        XCTAssertEqual(result.receiverFinalState, .completed)
        XCTAssertEqual(
            result.senderMessages.count, 1,
            "the offer alone — not one chunk travels"
        )
        XCTAssertEqual(harness.assembledDigest(), offer.sha256)
    }

    /// The identity quadruple must match WHOLE: same id, different
    /// digest = the file changed under the id → abort(resumeMismatch).
    func testResumeMismatchAborts() throws {
        let (offer, payload) = makeFixture()
        _ = payload
        var receiver = BulkReceiveEngine(
            config: BulkTransferConfig(),
            resumeBook: [BulkResumeState(
                transferId: offer.transferId,
                totalByteCount: offer.totalByteCount,
                chunkByteCount: offer.chunkByteCount,
                sha256: [UInt8](repeating: 0xEE, count: 32),
                name: offer.name,
                possession: BulkPossession(contiguousCount: 2)
            )]
        )
        var sender = BulkSendEngine(offer: offer)
        let offerEmit = emissions(try sender.begin())
        let actions = receiver.ingest(offerEmit[0])
        guard case .aborted(.resumeMismatch, false)? = actions.last
        else {
            return XCTFail("expected abort(resumeMismatch)")
        }
        XCTAssertEqual(
            receiver.state, .aborted(.resumeMismatch, byRemote: false)
        )
        // The wire abort crosses; the sender lands aborted-by-remote.
        let abortMessages = emissions(actions)
        XCTAssertEqual(abortMessages.count, 1)
        let senderActions = sender.ingest(abortMessages[0])
        XCTAssertEqual(
            sender.state, .aborted(.resumeMismatch, byRemote: true)
        )
        XCTAssertEqual(
            senderActions,
            [.aborted(.resumeMismatch, byRemote: true)]
        )
    }

    // MARK: - Aborts from every seat

    func testDeclineReachesSenderAsRemoteAbort() throws {
        let (offer, _) = makeFixture()
        var sender = BulkSendEngine(offer: offer)
        var receiver = BulkReceiveEngine()
        _ = receiver.ingest(emissions(try sender.begin())[0])
        let declined = try receiver.decline()
        XCTAssertEqual(
            receiver.state, .aborted(.declined, byRemote: false)
        )
        _ = sender.ingest(emissions(declined)[0])
        XCTAssertEqual(
            sender.state, .aborted(.declined, byRemote: true)
        )
    }

    func testSenderCancelReachesReceiver() throws {
        let (offer, payload) = makeFixture()
        _ = payload
        var sender = BulkSendEngine(offer: offer)
        var receiver = BulkReceiveEngine()
        _ = receiver.ingest(emissions(try sender.begin())[0])
        _ = try receiver.accept()
        let cancelled = sender.cancel()
        XCTAssertEqual(
            sender.state, .aborted(.cancelled, byRemote: false)
        )
        _ = receiver.ingest(emissions(cancelled)[0])
        XCTAssertEqual(
            receiver.state, .aborted(.cancelled, byRemote: true)
        )
        // A cancelled transfer leaves a resume state? No — aborted is
        // terminal; there is nothing mid-flight to persist.
        XCTAssertNil(receiver.resumeState)
    }

    func testReceiverStorageFailureReachesSender() throws {
        let (offer, payload) = makeFixture()
        var sender = BulkSendEngine(offer: offer)
        var receiver = BulkReceiveEngine()
        _ = receiver.ingest(emissions(try sender.begin())[0])
        var senderActions: [BulkSendEngine.Action] = []
        for message in emissions(try receiver.accept()) {
            senderActions += sender.ingest(message)
        }
        let index = reads(senderActions)[0]
        let chunkEmit = emissions(try sender.supplyChunk(
            index: index, data: chunkData(offer, payload, index)
        ))
        _ = receiver.ingest(chunkEmit[0])
        let failed = receiver.storageFailed()
        XCTAssertEqual(
            receiver.state,
            .aborted(.storageFailure, byRemote: false)
        )
        _ = sender.ingest(emissions(failed)[0])
        XCTAssertEqual(
            sender.state, .aborted(.storageFailure, byRemote: true)
        )
    }

    func testShaMismatchAbortsBothEnds() throws {
        let (offer, payload) = makeFixture(
            chunkCount: 1, finalChunkBytes: 64
        )
        var sender = BulkSendEngine(offer: offer)
        var receiver = BulkReceiveEngine()
        _ = receiver.ingest(emissions(try sender.begin())[0])
        var senderActions: [BulkSendEngine.Action] = []
        for message in emissions(try receiver.accept()) {
            senderActions += sender.ingest(message)
        }
        let chunkEmit = emissions(try sender.supplyChunk(
            index: 0, data: chunkData(offer, payload, 0)
        ))
        let stored = receiver.ingest(chunkEmit[0])
        let confirm = try receiver.chunkStored(
            index: stores(stored)[0].index
        )
        XCTAssertTrue(confirm.contains(.verify))
        for message in emissions(confirm) {
            _ = sender.ingest(message)
        }
        XCTAssertEqual(sender.state, .awaitingVerification)
        // The disk lied: the assembled digest is wrong.
        let verdict = try receiver.verificationResult(
            digest: [UInt8](repeating: 0, count: 32)
        )
        XCTAssertEqual(
            receiver.state, .aborted(.shaMismatch, byRemote: false)
        )
        _ = sender.ingest(emissions(verdict)[0])
        XCTAssertEqual(
            sender.state, .aborted(.shaMismatch, byRemote: true)
        )
    }

    // MARK: - Remote violations (never a throw, always an abort)

    func testReceiverViolationChunkOutOfRange() throws {
        let (offer, _) = makeFixture()
        var receiver = BulkReceiveEngine()
        _ = receiver.ingest(.offer(offer))
        _ = try receiver.accept()
        let actions = receiver.ingest(.chunk(try BulkChunk(
            transferId: offer.transferId, chunkIndex: 5,
            data: [0xAA]
        )))
        XCTAssertEqual(actions.first, .violated(.chunkOutOfRange(5)))
        XCTAssertEqual(
            receiver.state,
            .aborted(.protocolViolation, byRemote: false)
        )
    }

    func testReceiverViolationWrongChunkSize() throws {
        let (offer, _) = makeFixture()
        var receiver = BulkReceiveEngine()
        _ = receiver.ingest(.offer(offer))
        _ = try receiver.accept()
        let actions = receiver.ingest(.chunk(try BulkChunk(
            transferId: offer.transferId, chunkIndex: 0,
            data: [0xAA, 0xBB]
        )))
        XCTAssertEqual(
            actions.first,
            .violated(.chunkByteCountMismatch(index: 0, byteCount: 2))
        )
    }

    func testReceiverViolationDuplicateChunk() throws {
        let (offer, payload) = makeFixture()
        var receiver = BulkReceiveEngine()
        _ = receiver.ingest(.offer(offer))
        _ = try receiver.accept()
        let chunk = try BulkChunk(
            transferId: offer.transferId, chunkIndex: 0,
            data: chunkData(offer, payload, 0)
        )
        let first = receiver.ingest(.chunk(chunk))
        _ = try receiver.chunkStored(index: stores(first)[0].index)
        let second = receiver.ingest(.chunk(chunk))
        XCTAssertEqual(second.first, .violated(.duplicateChunk(0)))
    }

    func testReceiverViolationCreditExceeded() throws {
        let (offer, payload) = makeFixture()
        var receiver = BulkReceiveEngine(
            config: BulkTransferConfig(receiveWindowChunks: 1)
        )
        _ = receiver.ingest(.offer(offer))
        _ = try receiver.accept() // grant = 1
        _ = receiver.ingest(.chunk(try BulkChunk(
            transferId: offer.transferId, chunkIndex: 0,
            data: chunkData(offer, payload, 0)
        )))
        // A second chunk without a fresh grant breaks the contract.
        let actions = receiver.ingest(.chunk(try BulkChunk(
            transferId: offer.transferId, chunkIndex: 1,
            data: chunkData(offer, payload, 1)
        )))
        XCTAssertEqual(actions.first, .violated(.creditExceeded))
    }

    func testReceiverViolationForeignTransferAndRoleReversal() throws {
        let (offer, _) = makeFixture()
        var receiver = BulkReceiveEngine()
        _ = receiver.ingest(.offer(offer))
        _ = try receiver.accept()
        // A chunk for a transfer we never heard of.
        var probe = BulkReceiveEngine()
        _ = probe.ingest(.offer(offer))
        _ = try probe.accept()
        let foreign = probe.ingest(.chunk(try BulkChunk(
            transferId: 0xDEAD, chunkIndex: 0, data: [1]
        )))
        XCTAssertEqual(
            foreign.first, .violated(.foreignTransfer(0xDEAD))
        )
        // Role reversal: sender-bound messages arriving at a receiver.
        let reversal = receiver.ingest(.ack(try BulkAck(
            transferId: offer.transferId, creditTotal: 1,
            possession: BulkChunkMap(contiguousCount: 0)
        )))
        XCTAssertEqual(
            reversal.first,
            .violated(.unexpectedMessage(type: CtrlMessageType.bulkAck))
        )
    }

    func testSenderViolationPossessionOverClaimed() throws {
        let (offer, _) = makeFixture() // 5 chunks
        var sender = BulkSendEngine(offer: offer)
        _ = try sender.begin()
        let actions = sender.ingest(.accept(try BulkAccept(
            transferId: offer.transferId,
            creditTotal: 4,
            possession: BulkChunkMap(contiguousCount: 6)
        )))
        XCTAssertEqual(
            actions.first, .violated(.possessionOverClaimed)
        )
        XCTAssertEqual(
            sender.state,
            .aborted(.protocolViolation, byRemote: false)
        )
    }

    func testSenderViolationUnexpectedMessages() throws {
        let (offer, _) = makeFixture()
        var sender = BulkSendEngine(offer: offer)
        _ = try sender.begin()
        // An echo of our own offer is not a receiver message.
        let actions = sender.ingest(.offer(offer))
        XCTAssertEqual(
            actions.first,
            .violated(.unexpectedMessage(
                type: CtrlMessageType.bulkOffer
            ))
        )
        // Terminal states swallow everything after.
        XCTAssertTrue(sender.ingest(.offer(offer)).isEmpty)
    }

    /// Chunks held since the SESSION START (a resume the accept-map
    /// window under-claimed) are tolerated silently; chunks stored
    /// THIS session are duplicates and violate.
    func testUnderClaimToleranceBoundary() throws {
        let (offer, payload) = makeFixture()
        var receiver = BulkReceiveEngine(
            config: BulkTransferConfig(receiveWindowChunks: 8),
            resumeBook: [BulkResumeState(
                transferId: offer.transferId,
                totalByteCount: offer.totalByteCount,
                chunkByteCount: offer.chunkByteCount,
                sha256: offer.sha256,
                name: offer.name,
                possession: BulkPossession(contiguousCount: 2)
            )]
        )
        let offered = receiver.ingest(.offer(offer))
        guard case .offered(_, let resuming)? = offered.first,
              resuming else {
            return XCTFail("expected a resuming consent surface")
        }
        _ = try receiver.accept()
        // Chunk 0 is held from the resume state: tolerated, consumed,
        // no store, no violation.
        let tolerated = receiver.ingest(.chunk(try BulkChunk(
            transferId: offer.transferId, chunkIndex: 0,
            data: chunkData(offer, payload, 0)
        )))
        XCTAssertTrue(stores(tolerated).isEmpty)
        XCTAssertFalse(tolerated.contains {
            if case .violated = $0 { return true }
            return false
        })
        XCTAssertEqual(receiver.state, .receiving)
        // Chunk 2 stores normally…
        let fresh = receiver.ingest(.chunk(try BulkChunk(
            transferId: offer.transferId, chunkIndex: 2,
            data: chunkData(offer, payload, 2)
        )))
        _ = try receiver.chunkStored(index: stores(fresh)[0].index)
        // …and its repeat is a true duplicate.
        let dup = receiver.ingest(.chunk(try BulkChunk(
            transferId: offer.transferId, chunkIndex: 2,
            data: chunkData(offer, payload, 2)
        )))
        XCTAssertEqual(dup.first, .violated(.duplicateChunk(2)))
    }

    // MARK: - Local API misuse throws (shell bugs, loud)

    func testLocalApiMisuseThrows() throws {
        let (offer, payload) = makeFixture()
        var sender = BulkSendEngine(offer: offer)
        _ = try sender.begin()
        XCTAssertThrowsError(try sender.begin()) {
            XCTAssertEqual($0 as? BulkSendError, .notIdle)
        }
        XCTAssertThrowsError(
            try sender.supplyChunk(index: 0, data: [1])
        ) {
            XCTAssertEqual(
                $0 as? BulkSendError, .chunkNotRequested(0)
            )
        }
        _ = sender.ingest(.accept(try BulkAccept(
            transferId: offer.transferId, creditTotal: 2
        )))
        XCTAssertThrowsError(
            try sender.supplyChunk(index: 0, data: [1, 2, 3])
        ) {
            XCTAssertEqual(
                $0 as? BulkSendError,
                .wrongChunkByteCount(index: 0, expected: 4_096,
                                     actual: 3)
            )
        }

        var receiver = BulkReceiveEngine()
        XCTAssertThrowsError(try receiver.accept()) {
            XCTAssertEqual($0 as? BulkReceiveError, .noOfferPending)
        }
        XCTAssertThrowsError(try receiver.decline()) {
            XCTAssertEqual($0 as? BulkReceiveError, .noOfferPending)
        }
        XCTAssertThrowsError(try receiver.chunkStored(index: 0)) {
            XCTAssertEqual(
                $0 as? BulkReceiveError, .storeNotPending(0)
            )
        }
        XCTAssertThrowsError(
            try receiver.verificationResult(
                digest: Sha256.digest(payload)
            )
        ) {
            XCTAssertEqual($0 as? BulkReceiveError, .notVerifying)
        }
    }

    /// A read answered after the transfer moved past transferring is
    /// dropped silently — the in-flight-read race, not a shell bug.
    func testStaleSupplyChunkDropsSilently() throws {
        let (offer, payload) = makeFixture()
        var sender = BulkSendEngine(offer: offer)
        _ = try sender.begin()
        var actions = sender.ingest(.accept(try BulkAccept(
            transferId: offer.transferId, creditTotal: 2
        )))
        XCTAssertFalse(reads(actions).isEmpty)
        _ = sender.cancel()
        actions = try sender.supplyChunk(
            index: 0, data: chunkData(offer, payload, 0)
        )
        XCTAssertTrue(actions.isEmpty)
    }
}
