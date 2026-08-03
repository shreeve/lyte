// The deterministic bulk-transfer replay harness — the ONE driving
// loop `lyte-wire-vectorgen bulk` (authoring the transfer vectors)
// and the test suite (replaying them frozen) share, so the vectors
// mean exactly one thing. Auto-consent, synchronous storage, honest
// digests: every `.readChunk` is answered immediately from the
// payload, every `.store` is persisted and confirmed immediately,
// and `.verify` digests the chunks ACTUALLY stored (so a corrupted
// store would fail the sha-exact bar, not slide through).
//
// Sessions model teardown/reconnect: fresh engines every session,
// possession and the resume book persisting across them (exactly the
// ends' obligation, design record 20260728-053300 §5), and
// `receiverIngestLimit` cutting delivery mid-flight — with in-order
// ARQ carriage, a blackout means the receiver saw a prefix of the
// sender's emissions, which is precisely what the cap expresses.

import LyteCore
import LyteWire

public struct BulkTransferHarness {
    public let offer: BulkOffer
    public let payload: [UInt8]
    public let window: Int

    /// Persisted chunk storage, across sessions.
    public private(set) var store: [UInt64: [UInt8]] = [:]
    /// The receiver's persisted resume book, across sessions.
    public private(set) var resumeBook: [BulkResumeState] = []

    public struct SessionResult: Sendable {
        /// Complete emission lists, in emission order — including
        /// messages the teardown kept the peer from ever seeing.
        public var senderMessages: [[UInt8]]
        public var receiverMessages: [[UInt8]]
        public var senderFinalState: BulkSendEngine.State
        public var receiverFinalState: BulkReceiveEngine.State
    }

    /// `initialPossession` seeds a pre-existing resume state (with
    /// its chunks synthesized from the payload) — the holed-map case.
    public init(
        offer: BulkOffer,
        payload: [UInt8],
        window: Int,
        initialPossession: BulkPossession? = nil
    ) {
        self.offer = offer
        self.payload = payload
        self.window = window
        if let initialPossession {
            for index in 0..<offer.chunkCount
            where initialPossession.holds(index) {
                store[index] = chunkData(index)
            }
            resumeBook = [BulkResumeState(
                transferId: offer.transferId,
                totalByteCount: offer.totalByteCount,
                chunkByteCount: offer.chunkByteCount,
                sha256: offer.sha256,
                name: offer.name,
                possession: initialPossession
            )]
        }
    }

    public func chunkData(_ index: UInt64) -> [UInt8] {
        let size = offer.byteCount(ofChunk: index) ?? 0
        let start = Int(index) * Int(offer.chunkByteCount)
        return Array(payload[start..<start + size])
    }

    /// The digest of the assembled store — the payload's digest once
    /// (and only once) every chunk landed intact.
    public func assembledDigest() -> [UInt8] {
        var assembled = [UInt8]()
        assembled.reserveCapacity(payload.count)
        for index in 0..<offer.chunkCount {
            assembled.append(contentsOf: store[index] ?? [])
        }
        return Sha256.digest(assembled)
    }

    /// Runs one session to quiescence (or to the delivery cap) and
    /// persists the receiver's resume state for the next one.
    public mutating func runSession(
        receiverIngestLimit: Int? = nil
    ) throws -> SessionResult {
        var sender = BulkSendEngine(offer: offer)
        var receiver = BulkReceiveEngine(
            config: BulkTransferConfig(receiveWindowChunks: window),
            resumeBook: resumeBook
        )

        var senderOut: [[UInt8]] = []
        var receiverOut: [[UInt8]] = []
        var toReceiver: [BulkMessage] = []
        var toSender: [BulkMessage] = []
        var receiverIngested = 0

        func pumpSender(_ actions: [BulkSendEngine.Action]) throws {
            for action in actions {
                switch action {
                case .emit(let message):
                    senderOut.append(message.encode())
                    toReceiver.append(message)
                case .readChunk(let index):
                    try pumpSender(sender.supplyChunk(
                        index: index, data: chunkData(index)
                    ))
                case .completed, .aborted, .violated:
                    break
                }
            }
        }

        func pumpReceiver(_ actions: [BulkReceiveEngine.Action]) throws {
            for action in actions {
                switch action {
                case .emit(let message):
                    receiverOut.append(message.encode())
                    toSender.append(message)
                case .offered:
                    try pumpReceiver(receiver.accept())
                case .store(let index, let data):
                    store[index] = data
                    try pumpReceiver(receiver.chunkStored(index: index))
                case .verify:
                    try pumpReceiver(receiver.verificationResult(
                        digest: assembledDigest()
                    ))
                case .completed, .aborted, .violated:
                    break
                }
            }
        }

        try pumpSender(sender.begin())
        var progressed = true
        while progressed {
            progressed = false
            while !toReceiver.isEmpty {
                if let limit = receiverIngestLimit,
                   receiverIngested >= limit {
                    // Teardown: everything still in flight is lost.
                    toReceiver.removeAll()
                    break
                }
                let message = toReceiver.removeFirst()
                receiverIngested += 1
                try pumpReceiver(receiver.ingest(message))
                progressed = true
            }
            while !toSender.isEmpty {
                let message = toSender.removeFirst()
                try pumpSender(sender.ingest(message))
                progressed = true
            }
        }

        // Persist across the session boundary — the ends' obligation.
        resumeBook.removeAll { $0.transferId == offer.transferId }
        if let resume = receiver.resumeState {
            resumeBook.append(resume)
        }

        return SessionResult(
            senderMessages: senderOut,
            receiverMessages: receiverOut,
            senderFinalState: sender.state,
            receiverFinalState: receiver.state
        )
    }
}
