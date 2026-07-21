import XCTest
import LyteWire

final class ChannelSeqTests: XCTestCase {

    func testNextWrapsAt65535() {
        XCTAssertEqual(ChannelSeq(rawValue: 0xFFFF).next.rawValue, 0)
        XCTAssertEqual(ChannelSeq(rawValue: 0).next.rawValue, 1)
    }

    func testSerialComparisonAcrossWrap() {
        // The successor is always ahead, including through the wrap.
        XCTAssertLessThan(ChannelSeq(rawValue: 0xFFFF), ChannelSeq(rawValue: 0))
        XCTAssertLessThan(ChannelSeq(rawValue: 0xFFFE), ChannelSeq(rawValue: 1))
        XCTAssertLessThan(ChannelSeq(rawValue: 0), ChannelSeq(rawValue: 1))
        XCTAssertFalse(ChannelSeq(rawValue: 0) < ChannelSeq(rawValue: 0xFFFF))
        XCTAssertFalse(ChannelSeq(rawValue: 1) < ChannelSeq(rawValue: 1))
    }

    func testSerialDistance() {
        let base = ChannelSeq(rawValue: 60000)
        XCTAssertEqual(base.distance(to: ChannelSeq(rawValue: 4464)), 10000)
        XCTAssertEqual(ChannelSeq(rawValue: 4464).distance(to: base), -10000)
        XCTAssertEqual(base.distance(to: base), 0)
        XCTAssertEqual(
            ChannelSeq(rawValue: 0xFFFF).distance(to: ChannelSeq(rawValue: 0)), 1
        )
    }

    func testAdvancedByNegativeDelta() {
        let seq = ChannelSeq(rawValue: 2)
        XCTAssertEqual(seq.advanced(by: -5).rawValue, 0xFFFD)
        XCTAssertEqual(seq.advanced(by: -5).advanced(by: 5), seq)
    }

    func testHalfWindowDistanceIsUnorderedByRule() {
        // Exactly 0x8000 apart: the one distance serial arithmetic cannot
        // order. Both comparisons are false; distance saturates to
        // Int16.min from either side. Callers never operate here — gate
        // windows are orders of magnitude below the half-window.
        let a = ChannelSeq(rawValue: 100)
        let b = ChannelSeq(rawValue: 100 &+ 0x8000)
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.distance(to: b), Int16.min)
        XCTAssertEqual(b.distance(to: a), Int16.min)
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
    // fails with a type error. The beacon codec (W4a) is the only
    // sanctioned conversion between the two domains.
}

final class ChannelIdTests: XCTestCase {

    func testRegistryNumbers() {
        XCTAssertEqual(ChannelId.ctrl.rawValue, 0)
        XCTAssertEqual(ChannelId.audio.rawValue, 1)
        XCTAssertEqual(ChannelId.videoActive.rawValue, 2)
        XCTAssertEqual(ChannelId.feedback.rawValue, 3)
        XCTAssertEqual(ChannelId.videoIdle.rawValue, 4)
    }

    func testDeliveryClasses() {
        XCTAssertEqual(ChannelId.ctrl.deliveryClass, .reliableOrdered)
        XCTAssertEqual(ChannelId.audio.deliveryClass, .unreliable)
        XCTAssertEqual(ChannelId.videoActive.deliveryClass, .unreliable)
        XCTAssertEqual(ChannelId.feedback.deliveryClass, .unreliable)
        XCTAssertEqual(ChannelId.videoIdle.deliveryClass, .reliableOneShotGroups)
        XCTAssertEqual(
            ChannelId(rawValue: 8).deliveryClass, .reliableOrdered
        )
    }

    func testPriorityOrderIsTheUnifiedRuling() {
        // CTRL > audio > fresh video > tail > refinement > feature > telemetry.
        let order: [WirePriority] = [
            .control, .audio, .freshVideo, .videoTail, .refinement,
            .feature, .telemetry,
        ]
        XCTAssertEqual(order, order.sorted())
        XCTAssertEqual(ChannelId.ctrl.priority, .control)
        XCTAssertEqual(ChannelId.audio.priority, .audio)
        XCTAssertEqual(ChannelId.videoActive.priority, .freshVideo)
        XCTAssertEqual(ChannelId.videoIdle.priority, .videoTail)
        XCTAssertEqual(ChannelId(rawValue: 9).priority, .feature)
        XCTAssertEqual(ChannelId.feedback.priority, .telemetry)
    }

    func testReservedRangeHasNoPolicy() {
        for raw: UInt8 in 5...7 {
            let channel = ChannelId(rawValue: raw)
            XCTAssertTrue(channel.isReserved)
            XCTAssertNil(channel.deliveryClass)
            XCTAssertNil(channel.priority)
        }
        XCTAssertFalse(ChannelId.videoIdle.isReserved)
        XCTAssertFalse(ChannelId(rawValue: 8).isReserved)
    }

    func testFeatureChannels() {
        XCTAssertNil(ChannelId.feature(7))
        XCTAssertEqual(ChannelId.feature(8)?.rawValue, 8)
        XCTAssertEqual(ChannelId.feature(255)?.rawValue, 255)
        XCTAssertTrue(ChannelId(rawValue: 8).isFeature)
        XCTAssertFalse(ChannelId.videoIdle.isFeature)
    }

    func testWireVersion() {
        XCTAssertEqual(WireVersion.major, 1)
        // The reserved TLV slots the handshake (W5) will fill.
        XCTAssertEqual(WireExtension.ReservedType.connectionId, 0x01)
        XCTAssertEqual(WireExtension.ReservedType.wireVersion, 0x02)
    }
}
