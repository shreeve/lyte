import XCTest
import LyteWire

// Serial comparison and distance across the wrap, including the
// unordered half-window, are envelope-v1.json's seqComparisons table.
final class ChannelSeqTests: XCTestCase {

    func testNextWrapsAt65535() {
        XCTAssertEqual(ChannelSeq(rawValue: 0xFFFF).next.rawValue, 0)
        XCTAssertEqual(ChannelSeq(rawValue: 0).next.rawValue, 1)
    }

    func testAdvancedByNegativeDelta() {
        let seq = ChannelSeq(rawValue: 2)
        XCTAssertEqual(seq.advanced(by: -5).rawValue, 0xFFFD)
        XCTAssertEqual(seq.advanced(by: -5).advanced(by: 5), seq)
    }

    func testConsecutiveIncrementsStayOrdered() {
        var seq = ChannelSeq(rawValue: 0xFFF0)
        for _ in 0..<64 {
            let next = seq.next
            XCTAssertLessThan(seq, next)
            XCTAssertEqual(seq.distance(to: next), 1)
            seq = next
        }
        XCTAssertEqual(seq.rawValue, 0x0030)
    }
}

final class FrameNumberTests: XCTestCase {

    func testOrderingAndWrappingNext() {
        XCTAssertLessThan(FrameNumber(rawValue: 1), FrameNumber(rawValue: 2))
        XCTAssertEqual(FrameNumber(rawValue: 0xFFFF_FFFF).next.rawValue, 0)
    }
}

final class WireTimestampTests: XCTestCase {

    func testSameDomainArithmetic() {
        let start = HostTimestamp(microseconds: 1_000_000)
        let later = start.advanced(byMicroseconds: 16_667)
        XCTAssertEqual(later.microseconds(since: start), 16_667)
        XCTAssertEqual(start.microseconds(since: later), -16_667)
        XCTAssertLessThan(start, later)
    }

    func testNegativeAdvanceWrapsLikeTheClockWould() {
        let t = ClientTimestamp(microseconds: 5)
        XCTAssertEqual(t.advanced(byMicroseconds: -5).microseconds, 0)
        XCTAssertEqual(
            t.advanced(byMicroseconds: -6).microseconds, UInt64.max
        )
    }

    // Cross-domain arithmetic does not compile, which is the point:
    //   HostTimestamp(microseconds: 1)
    //       .microseconds(since: ClientTimestamp(microseconds: 0))
    // fails with a type error. The beacon codec is the only sanctioned
    // conversion between the two domains.
}

final class ChannelIdTests: XCTestCase {

    func testRegistryNumbers() {
        XCTAssertEqual(ChannelId.ctrl.rawValue, 0)
        XCTAssertEqual(ChannelId.audio.rawValue, 1)
        XCTAssertEqual(ChannelId.videoActive.rawValue, 2)
        XCTAssertEqual(ChannelId.feedback.rawValue, 3)
        XCTAssertEqual(ChannelId.videoIdle.rawValue, 4)
        XCTAssertEqual(ChannelId.bulkTransfer.rawValue, 8)
    }

    func testReservedRange() {
        for raw: UInt8 in 5...7 {
            XCTAssertTrue(ChannelId(rawValue: raw).isReserved)
        }
        XCTAssertFalse(ChannelId.videoIdle.isReserved)
        XCTAssertFalse(ChannelId(rawValue: 8).isReserved)
    }

    func testChannelNames() {
        let names = (0...9).map { ChannelId(rawValue: UInt8($0)).description }
        XCTAssertEqual(names, [
            "ctrl", "audio", "video-active", "feedback", "video-idle",
            "reserved", "reserved", "reserved", "bulk-transfer", "feature",
        ])
        XCTAssertEqual("\(ChannelId(rawValue: 255))", "feature")
    }

    func testWireVersion() {
        XCTAssertEqual(WireVersion.major, 1)
        // The reserved TLV slots.
        XCTAssertEqual(WireExtension.ReservedType.connectionId, 0x01)
        XCTAssertEqual(WireExtension.ReservedType.wireVersion, 0x02)
    }
}
