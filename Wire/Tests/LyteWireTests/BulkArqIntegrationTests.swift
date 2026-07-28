import XCTest
import Foundation
import LyteWire
import LyteWireTestKit

// The composition the ends will actually run (design record
// 20260728-053300 §3): bulk engines riding chan-8 ArqEndpoints over a
// seeded lossy/jittery SimNet, in virtual time. The engines have no
// timers by design — here the ARQ sublayer beneath them earns that:
// loss and reordering never reach the bulk layer, credit and
// possession stay coherent, and a 100-chunk transfer lands sha-exact.
// The blackout trial kills the whole stack mid-transfer (endpoints,
// engines, pipe — everything but the persisted store and resume book)
// and completes in a second session, the J-G3 resume shape end to end.

final class BulkArqIntegrationTests: XCTestCase {

    private typealias Endpoint = ArqEndpoint<HostClock>

    /// One virtual-time world: two ARQ endpoints on chan 8, the bulk
    /// engines on top, a fault pipe between. Storage is synchronous;
    /// the store and the resume book live OUTSIDE the world so a
    /// blackout can carry them into the next one.
    private struct World {
        var pipe: SimNet
        var senderArq = Endpoint(channel: .bulkTransfer)
        var receiverArq = Endpoint(channel: .bulkTransfer)
        var sender: BulkSendEngine
        var receiver: BulkReceiveEngine
        let offer: BulkOffer
        let payload: [UInt8]
        var now: UInt64 = 0

        init(
            offer: BulkOffer,
            payload: [UInt8],
            window: Int,
            resumeBook: [BulkResumeState],
            net: SimNetConfig,
            seed: UInt64
        ) {
            self.offer = offer
            self.payload = payload
            self.pipe = SimNet(config: net, seed: seed)
            self.sender = BulkSendEngine(offer: offer)
            self.receiver = BulkReceiveEngine(
                config: BulkTransferConfig(receiveWindowChunks: window),
                resumeBook: resumeBook
            )
        }

        func chunkData(_ index: UInt64) -> [UInt8] {
            let start = Int(index) * Int(offer.chunkByteCount)
            let size = offer.byteCount(ofChunk: index)!
            return Array(payload[start..<start + size])
        }
    }

    /// Runs `world` until both engines are terminal and both ARQ
    /// endpoints quiesce, or until `blackoutAfterStores` chunk stores
    /// have been confirmed (the teardown — mid-transfer by
    /// construction), or until the horizon fails the test.
    private func run(
        _ world: inout World,
        store: inout [UInt64: [UInt8]],
        label: String,
        blackoutAfterStores: Int? = nil
    ) throws {
        var storeCount = 0
        func digestOfStore() -> [UInt8] {
            var assembled = [UInt8]()
            for index in 0..<world.offer.chunkCount {
                assembled.append(contentsOf: store[index] ?? [])
            }
            return Sha256.digest(assembled)
        }

        func pumpSender(
            _ actions: [BulkSendEngine.Action], now: UInt64
        ) throws {
            for action in actions {
                switch action {
                case .emit(let message):
                    try world.senderArq.send(
                        message: message.encode(),
                        now: HostTimestamp(microseconds: now)
                    )
                case .readChunk(let index):
                    try pumpSender(world.sender.supplyChunk(
                        index: index, data: world.chunkData(index)
                    ), now: now)
                case .completed, .aborted, .violated:
                    break
                }
            }
        }

        func pumpReceiver(
            _ actions: [BulkReceiveEngine.Action], now: UInt64
        ) throws {
            for action in actions {
                switch action {
                case .emit(let message):
                    try world.receiverArq.send(
                        message: message.encode(),
                        now: HostTimestamp(microseconds: now)
                    )
                case .offered:
                    try pumpReceiver(world.receiver.accept(), now: now)
                case .store(let index, let data):
                    store[index] = data
                    storeCount += 1
                    try pumpReceiver(
                        world.receiver.chunkStored(index: index),
                        now: now
                    )
                case .verify:
                    try pumpReceiver(
                        world.receiver.verificationResult(
                            digest: digestOfStore()
                        ),
                        now: now
                    )
                case .completed, .aborted, .violated:
                    break
                }
            }
        }

        try pumpSender(world.sender.begin(), now: world.now)

        let horizon: UInt64 = 600_000_000 // 600 simulated seconds
        var steps = 0
        while world.now <= horizon {
            steps += 1
            if steps > 500_000 {
                return XCTFail("\(label): step bound — livelock")
            }
            if let cap = blackoutAfterStores, storeCount >= cap {
                return // teardown: the world simply stops
            }

            let instant = HostTimestamp(microseconds: world.now)
            for delivery in world.pipe.deliveries(upTo: world.now) {
                if delivery.destination == 0 {
                    for event in world.senderArq.ingest(
                        payload: delivery.bytes, now: instant
                    ) {
                        guard case .message(_, let bytes) = event
                        else { continue }
                        try pumpSender(world.sender.ingest(
                            try BulkMessage.decode(bytes)
                        ), now: world.now)
                    }
                } else {
                    for event in world.receiverArq.ingest(
                        payload: delivery.bytes, now: instant
                    ) {
                        guard case .message(_, let bytes) = event
                        else { continue }
                        try pumpReceiver(world.receiver.ingest(
                            try BulkMessage.decode(bytes)
                        ), now: world.now)
                    }
                }
            }

            var deadlines: [UInt64] = []
            let fromSender = world.senderArq.poll(now: instant)
            for datagram in fromSender.datagrams {
                XCTAssertLessThanOrEqual(
                    datagram.count,
                    WireBudget.maxPlaintextShardByteCount,
                    "\(label): chan-8 datagram over the shard budget"
                )
                world.pipe.send(
                    from: 0, bytes: datagram, now: world.now
                )
            }
            if let deadline = fromSender.nextTimerDeadline {
                deadlines.append(deadline.microseconds)
            }
            let fromReceiver = world.receiverArq.poll(now: instant)
            for datagram in fromReceiver.datagrams {
                world.pipe.send(
                    from: 1, bytes: datagram, now: world.now
                )
            }
            if let deadline = fromReceiver.nextTimerDeadline {
                deadlines.append(deadline.microseconds)
            }

            let done = world.sender.isTerminal
                && world.receiver.isTerminal
                && world.pipe.nextArrivalTime == nil
                && world.senderArq.isQuiescent
                && world.receiverArq.isQuiescent
            if done { return }

            var candidates = deadlines
            if let arrival = world.pipe.nextArrivalTime {
                candidates.append(arrival)
            }
            let next = candidates.min() ?? (world.now + 10_000)
            world.now = max(next, world.now + 1)
        }
        XCTFail("\(label): did not converge inside the horizon")
    }

    private func makeTransfer(
        chunkCount: Int, chunkBytes: UInt32 = 4_096, seed: UInt64
    ) -> (offer: BulkOffer, payload: [UInt8]) {
        var rng = SplitMix64(seed: seed)
        let total = chunkCount * Int(chunkBytes) - 123
        let payload = rng.bytes(total)
        let offer = try! BulkOffer(
            transferId: rng.next() | 1,
            totalByteCount: UInt64(total),
            chunkByteCount: chunkBytes,
            sha256: Sha256.digest(payload),
            name: "soak.bin",
            mimeHint: "application/octet-stream"
        )
        return (offer, payload)
    }

    /// 100 chunks through 20% loss, duplication, and 5× jitter: the
    /// ARQ sublayer absorbs every fault; the bulk layer sees clean
    /// ordered messages and lands the blob sha-exact.
    func testLossyTransferCompletesShaExact() throws {
        let env = ProcessInfo.processInfo.environment
        let seeds: [UInt64] = env["LYTE_BULK_SEED"]
            .flatMap(UInt64.init).map { [$0] }
            ?? [0xB01D_0001, 0xB01D_0002, 0xB01D_0003]
        for seed in seeds {
            let label = "seed \(seed)"
            let (offer, payload) = makeTransfer(
                chunkCount: 100, seed: seed
            )
            var world = World(
                offer: offer, payload: payload, window: 16,
                resumeBook: [],
                net: SimNetConfig(
                    lossRate: 0.20,
                    duplicateRate: 0.05,
                    baseDelayMicroseconds: 5_000,
                    jitterMicroseconds: 50_000
                ),
                seed: seed
            )
            var store: [UInt64: [UInt8]] = [:]
            try run(&world, store: &store, label: label)
            XCTAssertEqual(
                world.sender.state, .completed, label
            )
            XCTAssertEqual(
                world.receiver.state, .completed, label
            )
            var assembled = [UInt8]()
            for index in 0..<offer.chunkCount {
                assembled.append(contentsOf: store[index] ?? [])
            }
            XCTAssertEqual(
                assembled, payload, "\(label): byte-exact landing"
            )
        }
    }

    /// The J-G3 shape end to end: a lossy session dies mid-transfer
    /// (everything volatile is lost — ARQ state, engines, in-flight
    /// datagrams), the persisted store + resume book seed a second
    /// world, and the transfer completes sha-exact having re-sent
    /// only what the receiver never confirmed.
    func testBlackoutThenResumeCompletesShaExact() throws {
        let seed: UInt64 = 0xB1AC_0001
        let (offer, payload) = makeTransfer(
            chunkCount: 60, seed: seed
        )
        var store: [UInt64: [UInt8]] = [:]

        var first = World(
            offer: offer, payload: payload, window: 8,
            resumeBook: [],
            net: SimNetConfig(
                lossRate: 0.15,
                duplicateRate: 0.03,
                baseDelayMicroseconds: 5_000,
                jitterMicroseconds: 25_000
            ),
            seed: seed
        )
        // The teardown lands after 20 of the 60 chunks confirm —
        // mid-transfer by construction, whatever the loss dice did.
        try run(
            &first, store: &store, label: "blackout session 1",
            blackoutAfterStores: 20
        )
        XCTAssertFalse(
            first.receiver.isTerminal,
            "the blackout must land mid-transfer, not after the end"
        )
        guard let resume = first.receiver.resumeState else {
            return XCTFail("mid-transfer teardown must leave a "
                + "resume state")
        }
        let alreadyHeld = resume.possession.heldChunkCount
        XCTAssertGreaterThanOrEqual(alreadyHeld, 20)
        XCTAssertLessThan(
            alreadyHeld, offer.chunkCount,
            "the blackout must interrupt, not finish"
        )

        // A fresh world: new ARQ endpoints, new engines, new pipe.
        // Only the store and the resume book survive — exactly what
        // the ends persist.
        var second = World(
            offer: offer, payload: payload, window: 8,
            resumeBook: [resume],
            net: SimNetConfig(
                lossRate: 0.10,
                duplicateRate: 0.02,
                baseDelayMicroseconds: 5_000,
                jitterMicroseconds: 20_000
            ),
            seed: seed &+ 1
        )
        try run(&second, store: &store, label: "blackout session 2")
        XCTAssertEqual(second.sender.state, .completed)
        XCTAssertEqual(second.receiver.state, .completed)
        // Session 2 re-sent only what the resume map disclaimed.
        XCTAssertLessThanOrEqual(
            second.sender.issuedReadCount,
            offer.chunkCount - resume.possession.contiguousCount,
            "resume must not re-send the confirmed prefix"
        )
        var assembled = [UInt8]()
        for index in 0..<offer.chunkCount {
            assembled.append(contentsOf: store[index] ?? [])
        }
        XCTAssertEqual(assembled, payload, "sha-exact after resume")
    }
}
