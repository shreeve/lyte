import XCTest
import Foundation
@testable import HostWire
import LyteWire

final class SessionArqLaneTests: XCTestCase {
    private var config: ArqConfig {
        ArqConfig(
            initialRttMicroseconds: 10_000,
            minPtoMicroseconds: 1_000,
            maxPtoMicroseconds: 1_000_000,
            maxSegmentBodyByteCount: 32,
            maxDatagramPayloadByteCount: 96
        )
    }

    func testSessionKeepsExactlyTwoNamedLaneSlotsAndOneServiceLoop() throws {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        let packageRoot = components.joined(separator: "/")
        let session = try String(contentsOfFile:
            packageRoot + "/Sources/HostWire/Session.swift",
            encoding: .utf8
        )

        XCTAssertTrue(session.contains(
            "private var ctrlArqLane: SessionArqLane"
        ))
        XCTAssertTrue(session.contains(
            "private var bulkArqLane: SessionArqLane?"
        ))
        for retired in [
            "private var arq:", "nextArqWakeNS", "nextBulkArqWakeNS",
            "ctrlSeq", "bulkSeq", "private func serviceBulkArq(",
            "private func serviceArq(",
        ] {
            XCTAssertFalse(session.contains(retired), retired)
        }
        XCTAssertEqual(
            session.components(separatedBy: "private func serviceArqLane(")
                .count - 1,
            1
        )
        XCTAssertTrue(session.contains(
            "sequence: ctrlArqLane.pendingEnvelopeSequence"
        ))
        XCTAssertTrue(session.contains("ctrlArqLane.commitEnvelopeSent()"))
    }

    func testSendPollPtoAndAckClearTheExactNanosecondDeadline() throws {
        var sender = SessionArqLane(channel: .ctrl, config: config)
        var receiver = SessionArqLane(channel: .ctrl, config: config)
        try sender.send([0xA5], now: 0)

        let first = sender.poll(now: 0)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(sender.nextDeadlineNanoseconds, 20_000_000)
        XCTAssertTrue(sender.poll(now: 19_999_999).isEmpty)
        XCTAssertEqual(sender.nextDeadlineNanoseconds, 20_000_000)
        XCTAssertEqual(sender.poll(now: 20_000_000), first)
        XCTAssertEqual(sender.nextDeadlineNanoseconds, 60_000_000)

        let delivered = receiver.ingest(first[0][...], now: 21_000_000)
        XCTAssertEqual(delivered, [
            .message(group: .orderedStream, bytes: [0xA5])
        ])
        let ack = receiver.poll(now: 21_000_000)
        XCTAssertEqual(ack.count, 1, "ingest owes an immediate ACK")
        XCTAssertNil(receiver.nextDeadlineNanoseconds)

        _ = sender.ingest(ack[0][...], now: 22_000_000)
        XCTAssertTrue(sender.poll(now: 22_000_000).isEmpty)
        XCTAssertNil(sender.nextDeadlineNanoseconds)
        XCTAssertTrue(sender.isQuiescent)
    }

    func testControlAndBulkKeepEndpointDeadlineAndSequenceStateIndependent()
        throws
    {
        var control = SessionArqLane(channel: .ctrl, config: config)
        var bulk = SessionArqLane(channel: .bulkTransfer, config: config)
        try control.sendOneShot(
            [0x11], group: ArqGroupId(rawValue: 7), now: 0
        )
        try bulk.send([0x22], now: 5_000_000)

        let controlPayload = try XCTUnwrap(control.poll(now: 0).first)
        let bulkPayload = try XCTUnwrap(bulk.poll(now: 5_000_000).first)
        XCTAssertEqual(control.nextDeadlineNanoseconds, 20_000_000)
        XCTAssertEqual(bulk.nextDeadlineNanoseconds, 25_000_000)

        let controlFrames = try ArqFrame.decodeAll(controlPayload)
        let bulkFrames = try ArqFrame.decodeAll(bulkPayload)
        guard case .segment(let controlSegment) = controlFrames[0],
              case .segment(let bulkSegment) = bulkFrames[0]
        else { return XCTFail("both polls must emit segments") }
        XCTAssertEqual(controlSegment.group, ArqGroupId(rawValue: 7))
        XCTAssertEqual(bulkSegment.group, .orderedStream)

        XCTAssertEqual(control.pendingEnvelopeSequence.rawValue, 0)
        XCTAssertEqual(bulk.pendingEnvelopeSequence.rawValue, 0)
        XCTAssertEqual(control.commitEnvelopeSent().rawValue, 0)
        XCTAssertEqual(control.commitEnvelopeSent().rawValue, 1)
        XCTAssertEqual(bulk.commitEnvelopeSent().rawValue, 0)
        XCTAssertEqual(control.pendingEnvelopeSequence.rawValue, 2)
        XCTAssertEqual(bulk.pendingEnvelopeSequence.rawValue, 1)
    }

    func testRefusalAndUncommittedEmissionConsumeNoLaneState() {
        var lane = SessionArqLane(channel: .ctrl, config: config)
        XCTAssertThrowsError(try lane.send([], now: 0))
        XCTAssertTrue(lane.poll(now: 0).isEmpty)
        XCTAssertNil(lane.nextDeadlineNanoseconds)
        XCTAssertTrue(lane.isQuiescent)

        let reserved = lane.pendingEnvelopeSequence
        XCTAssertEqual(lane.pendingEnvelopeSequence, reserved)
        XCTAssertEqual(lane.commitEnvelopeSent(), reserved)
        XCTAssertEqual(lane.pendingEnvelopeSequence, reserved.next)
    }

    func testEnvelopeSequenceWrapsOnlyOnCommit() {
        var lane = SessionArqLane(
            channel: .ctrl,
            config: config,
            initialEnvelopeSequence: ChannelSeq(rawValue: .max)
        )
        XCTAssertEqual(lane.pendingEnvelopeSequence.rawValue, .max)
        XCTAssertEqual(lane.pendingEnvelopeSequence.rawValue, .max)
        XCTAssertEqual(lane.commitEnvelopeSent().rawValue, .max)
        XCTAssertEqual(lane.pendingEnvelopeSequence.rawValue, 0)
    }

    func testCarrierGeometryStillBelongsToTheWireEndpoint() throws {
        var lane = SessionArqLane(
            channel: .ctrl,
            config: ArqConfig(
                maxSegmentBodyByteCount: 1_112,
                maxDatagramPayloadByteCount: 1_101
            )
        )
        try lane.send([UInt8](repeating: 0xA5, count: 4_000), now: 0)
        let payloads = lane.poll(now: 0)
        XCTAssertGreaterThan(payloads.count, 1)
        XCTAssertTrue(payloads.allSatisfy { $0.count <= 1_101 })
    }
}
