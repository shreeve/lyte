import LyteClientSession
import LyteWire
import Synchronization
import XCTest
import LyteTransport

/// The native NACK shell reads the clock model's RTT (a lock of its own)
/// only for the signal that uses it: every accepted, decoded, stale or
/// duplicate shard passes through here on the receive path.
final class NackPolicyShellTests: XCTestCase {
    func testOnlyNackCandidatesReadTheRtt() {
        let reads = Mutex(0)
        let policy = NackPolicy(
            rtt: { reads.withLock { $0 += 1 }; return 1_000 },
            emit: { _ in },
            escalate: { _, _ in })
        let now = ClientTimestamp(microseconds: 1_000)
        let frame = FrameNumber(rawValue: 4)

        for signal: VideoRepairSignal in [
            .repairShardAccepted(frame: frame, shardIndex: 0),
            .frameDecoded(frame: frame),
            .framesGone(from: frame, through: frame),
            .satisfiedShardDropped(frame: frame, shardIndex: 1),
            .staleShardDropped(frame: frame),
        ] {
            policy.handle(signal, now: now)
        }
        XCTAssertEqual(reads.withLock { $0 }, 0)

        policy.handle(.nackCandidates(
            frame: FrameNumber(rawValue: 5), missingShardIndices: [0],
            parityShards: 2, frameAgeMicroseconds: 0), now: now)
        XCTAssertEqual(reads.withLock { $0 }, 1)
    }
}
