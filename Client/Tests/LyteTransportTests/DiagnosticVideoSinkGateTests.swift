import AVFoundation
import CoreMedia
import Foundation
import LyteClientTestKit
import XCTest
@testable import LyteTransport
import LyteWire

/// Pins the harsh-path static-IDR storm seam: the diagnostic renderer
/// leaf must close `IdrRequester` when an IRAP reaches `enqueue`. The
/// old sink omitted that close, so wire-view retried 0x10 forever and
/// the host's 500 ms offer window re-armed retained-surface IDRs at ~2 Hz.
final class DiagnosticVideoSinkGateTests: XCTestCase {

    func testIrapEnqueueNotifiesCloseCallback() throws {
        let idrAnnexB = try loadCorpusIdr()
        let frames = LockedFrames()
        let layer = AVSampleBufferDisplayLayer()
        let sink = AVSampleBufferRendererVideoSink(
            renderer: layer.sampleBufferRenderer
        ) { frames.append($0) }

        let idr = DecodeUnit(
            frameNumber: FrameNumber(rawValue: 7),
            timestamp: HostTimestamp(microseconds: 116_669),
            isIDR: true,
            annexB: idrAnnexB)
        let sample = try XCTUnwrap(
            VideoRenderFactory().makeSampleBuffer(from: idr))
        sink.submit(sample: sample, unit: idr)
        XCTAssertEqual(frames.all.map(\.rawValue), [7])

        let inter = DecodeUnit(
            frameNumber: FrameNumber(rawValue: 8),
            timestamp: HostTimestamp(microseconds: 133_336),
            isIDR: false,
            annexB: idrAnnexB)
        sink.submit(sample: sample, unit: inter)
        XCTAssertEqual(
            frames.all.map(\.rawValue), [7],
            "non-IRAP submit must not close the recovery episode")
    }

    func testIrapCloseEndsIdrRequesterEpisode() throws {
        let idrAnnexB = try loadCorpusIdr()
        let emitted = LockedRequests()
        let requester = IdrRequester(retryIntervalMilliseconds: 500) {
            emitted.append($0)
        }
        let base = ClientTimestamp(microseconds: 40_000_000)
        requester.recordRecoveryDemand(
            frame: FrameNumber(rawValue: 1), now: base)
        XCTAssertEqual(emitted.all.count, 1)
        XCTAssertTrue(requester.snapshotStats().recoveryOutstanding)

        let frames = LockedFrames()
        let layer = AVSampleBufferDisplayLayer()
        let sink = AVSampleBufferRendererVideoSink(
            renderer: layer.sampleBufferRenderer
        ) { frame in
            frames.append(frame)
            requester.noteUsableIrapAccepted()
        }
        let idr = DecodeUnit(
            frameNumber: FrameNumber(rawValue: 12),
            timestamp: HostTimestamp(microseconds: 200_004),
            isIDR: true,
            annexB: idrAnnexB)
        let sample = try XCTUnwrap(
            VideoRenderFactory().makeSampleBuffer(from: idr))
        sink.submit(sample: sample, unit: idr)

        XCTAssertEqual(frames.all.map(\.rawValue), [12])
        requester.flushIfDue(
            now: base.advanced(byMicroseconds: 500_000))
        XCTAssertEqual(
            emitted.all.count, 1,
            "IRAP enqueue must end the episode; no 500 ms retry storm")
        XCTAssertFalse(requester.snapshotStats().recoveryOutstanding)
        XCTAssertEqual(requester.snapshotStats().episodesCompleted, 1)
    }

    private func loadCorpusIdr() throws -> [UInt8] {
        let directory = ClientTestPaths.videoCorpus
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory)
            .filter { $0.hasPrefix("frame-0") && $0.hasSuffix(".annexb") }
            .sorted()
        let first = try XCTUnwrap(names.first)
        return [UInt8](try Data(contentsOf: URL(
            fileURLWithPath: directory + "/" + first)))
    }

    private final class LockedFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FrameNumber] = []
        func append(_ f: FrameNumber) {
            lock.lock(); stored.append(f); lock.unlock()
        }
        var all: [FrameNumber] {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    private final class LockedRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [IdrRequest] = []
        func append(_ r: IdrRequest) {
            lock.lock(); stored.append(r); lock.unlock()
        }
        var all: [IdrRequest] {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }
}
