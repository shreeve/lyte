// The chan-0 seal-order pin (v1-final analysis, finding 4). Channel 0
// carries three independent senders on three threads — ARQ service,
// beacon echoes, IDR requests — and NoiseTransport's extended counter
// demands strict per-channel commit monotonicity at seal time. The
// sender must therefore make allocation order the commit order: seq
// allocation and seal are one critical section. This gate hammers one
// sender from several threads through a crypto that enforces exactly
// Noise's law, and fails loudly if any seal ever observes seqs out of
// order (the pre-fix shape: allocate under the lock, seal outside it).

import LyteWire
import XCTest

@testable import LyteTransport

/// A TransportCrypto that mirrors NoiseTransport's monotonic-commit
/// law: seal commits the envelope's seq per channel and throws if a
/// seq ever arrives at the sealer out of allocation order.
private final class StrictMonotonicCrypto: TransportCrypto, @unchecked Sendable {
    struct OutOfOrder: Error {}
    private let lock = NSLock()
    private var lastCommitted: [UInt8: UInt16] = [:]
    private(set) var commits = 0

    var modeDescription: String { "strict-monotonic test crypto" }

    func open() throws {}

    func seal(
        plaintext: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let channel = envelope.channel.rawValue
        if let last = lastCommitted[channel] {
            // The exact Noise law: strictly the next seq, no gaps, no
            // reordering — chan seqs are the AEAD nonce's serial half.
            guard envelope.seq.rawValue == last &+ 1 else {
                throw OutOfOrder()
            }
        }
        lastCommitted[channel] = envelope.seq.rawValue
        commits += 1
        return Array(plaintext)
    }

    func unseal(
        wirePayload: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        Array(wirePayload)
    }
}

final class TransportSenderConcurrencyTests: XCTestCase {
    /// Four threads, one channel, 2,000 sends each: every seal must
    /// observe its seq in exact allocation order (the strict crypto
    /// throws otherwise and the sender counts it), and the far side
    /// must see one contiguous serial stream. Pre-fix, the
    /// allocate-then-unlock-then-seal window made this fail within a
    /// few hundred iterations.
    func testConcurrentSendersOnOneChannelNeverCommitOutOfOrder() {
        let crypto = StrictMonotonicCrypto()
        let seqLock = NSLock()
        nonisolated(unsafe) var sentSeqs: [UInt16] = []
        let sender = TransportSender(crypto: crypto) { datagram in
            // Decode the envelope back off the wire bytes — the seq
            // the receiver would track.
            if let decoded = try? Envelope.decode(datagram[...]) {
                seqLock.lock()
                sentSeqs.append(decoded.envelope.seq.rawValue)
                seqLock.unlock()
            }
            return true
        }

        let threads = 4
        let perThread = 2_000
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            Thread.detachNewThread {
                for i in 0..<perThread {
                    _ = try? sender.send(
                        channel: ChannelId(rawValue: 0),
                        timestamp: ClientTimestamp(
                            microseconds: UInt64(i)),
                        plaintext: [0x7f, UInt8(i & 0xff)]
                    )
                }
                group.leave()
            }
        }
        XCTAssertEqual(
            group.wait(timeout: .now() + 30), .success,
            "senders wedged — the allocate+seal critical section deadlocked?"
        )

        let stats = sender.snapshotStats()
        XCTAssertEqual(stats.sealFailures, 0,
                       "a seal observed seqs out of allocation order — "
                       + "the Noise monotonic-commit law would have "
                       + "thrown sendSequenceNotMonotonic on the wire")
        XCTAssertEqual(stats.datagramsSent, UInt64(threads * perThread))
        XCTAssertEqual(crypto.commits, threads * perThread)

        // The wire saw one contiguous u16-serial stream (wrapping):
        // every allocated seq left exactly once.
        seqLock.lock()
        let seqs = sentSeqs
        seqLock.unlock()
        XCTAssertEqual(seqs.count, threads * perThread)
        XCTAssertEqual(Set(seqs).count, min(seqs.count, 65_536))
    }
}
