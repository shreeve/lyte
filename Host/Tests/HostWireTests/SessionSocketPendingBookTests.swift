import XCTest
import Foundation
import HostCore
import HostSession
@testable import HostWire
import LyteWire

final class SessionSocketPendingBookTests: XCTestCase {
    private func datagram(
        _ pacerClass: PacerClass,
        frame: UInt32,
        seq: UInt16,
        bytes: Int,
        destination: FourTuple? = nil
    ) -> VideoChannelDatagram {
        VideoChannelDatagram(
            bytes: [UInt8](repeating: 0xA5, count: bytes),
            pacerClass: pacerClass,
            frameNumber: FrameNumber(rawValue: frame),
            seq: ChannelSeq(rawValue: seq),
            isKeyframe: false,
            destination: destination
        )
    }

    func testEveryPacerClassMapsToItsOneWireEvidenceChannel() {
        XCTAssertEqual(PacerClass.control.sessionChannel, .ctrl)
        XCTAssertEqual(PacerClass.audio.sessionChannel, .audio)
        XCTAssertEqual(PacerClass.bulk.sessionChannel, .bulkTransfer)
        XCTAssertEqual(PacerClass.freshVideo.sessionChannel, .videoActive)
        XCTAssertEqual(PacerClass.videoTail.sessionChannel, .videoActive)
    }

    func testNoteAndRemoveTrackRatesFramesAndAggregatesExactly() {
        let fresh = datagram(.freshVideo, frame: 7, seq: 1, bytes: 3)
        let tail = datagram(.videoTail, frame: 7, seq: 2, bytes: 2)
        let tail8 = datagram(.videoTail, frame: 8, seq: 3, bytes: 4)
        let bulk = datagram(.bulk, frame: 9, seq: 4, bytes: 5)
        let control = datagram(.control, frame: 0, seq: 5, bytes: 6)
        let offPrimary = datagram(
            .freshVideo, frame: 10, seq: 6, bytes: 7,
            destination: FourTuple(
                localAddress: "10.0.0.1", localPort: 41_000,
                remoteAddress: "10.0.0.2", remotePort: 42_000
            )
        )

        var book = SessionSocketPendingBook()
        for (datagram, rate) in [
            (fresh, 10), (tail, 20), (tail8, 30),
            (bulk, 40), (control, 50), (offPrimary, 60),
        ] {
            book.note(datagram, releaseRateBitsPerSecond: rate)
        }
        XCTAssertEqual(book.pendingDatagramCount, 5)
        XCTAssertEqual(book.videoDatagramCount, 3)
        XCTAssertEqual(book.videoByteCount, 9)
        XCTAssertEqual(book.videoFrameNumbers, [7, 8])

        XCTAssertEqual(book.remove(tail), 20)
        XCTAssertEqual(book.videoDatagramCount, 2)
        XCTAssertEqual(book.videoByteCount, 7)
        XCTAssertEqual(book.videoFrameNumbers, [7, 8])
        XCTAssertEqual(book.remove(fresh), 10)
        XCTAssertEqual(book.videoFrameNumbers, [8])
        XCTAssertEqual(book.remove(tail8), 30)
        XCTAssertEqual(book.videoDatagramCount, 0)
        XCTAssertEqual(book.videoByteCount, 0)
        XCTAssertTrue(book.videoFrameNumbers.isEmpty)
        XCTAssertEqual(book.remove(bulk), 40)
        XCTAssertEqual(book.remove(control), 50)
        XCTAssertNil(book.remove(offPrimary))
        XCTAssertEqual(book.pendingDatagramCount, 0)
    }

    func testRepeatedRemovalCannotUnderflowVideoBooks() {
        let video = datagram(.freshVideo, frame: 7, seq: 1, bytes: 3)
        let sibling = datagram(.freshVideo, frame: 7, seq: 2, bytes: 5)
        var book = SessionSocketPendingBook()
        book.note(video, releaseRateBitsPerSecond: 10)
        book.note(sibling, releaseRateBitsPerSecond: 20)

        XCTAssertEqual(book.remove(video), 10)
        XCTAssertNil(book.remove(video))
        XCTAssertEqual(book.videoDatagramCount, 1)
        XCTAssertEqual(book.videoByteCount, 5)
        XCTAssertEqual(book.videoFrameNumbers, [7])
        XCTAssertEqual(book.remove(sibling), 20)
        XCTAssertEqual(book.videoDatagramCount, 0)
        XCTAssertEqual(book.videoByteCount, 0)
        XCTAssertTrue(book.videoFrameNumbers.isEmpty)
    }
}
