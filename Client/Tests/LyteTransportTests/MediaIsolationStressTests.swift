import LyteClientTestKit
import Foundation
import LyteWire
import XCTest
@testable import LyteTransport

final class MediaIsolationStressTests: XCTestCase {
    private static var corpusDirectory: String {
        ClientTestPaths.videoCorpus
    }

    /// A sample build stalled at the renderer seam holds only the sample
    /// worker: ingest (the receive thread) returns with it still blocked.
    func testVideoBuildBackpressureNeverHoldsTheReceiveThread() throws {
        let idrName = try FileManager.default
            .contentsOfDirectory(atPath: Self.corpusDirectory)
            .filter { $0.hasPrefix("frame-0") && $0.hasSuffix(".annexb") }
            .sorted().first!
        let idr = [UInt8](try Data(contentsOf: URL(
            fileURLWithPath: Self.corpusDirectory + "/" + idrName)))
        var packetizer = VideoPacketizer()
        let shards = try packetizer.packetize(
            frame: idr,
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: true,
            regime: .clean)

        let enteredRendererSeam = DispatchSemaphore(value: 0)
        let releaseRendererSeam = DispatchSemaphore(value: 0)
        let pipeline = LyteVideoPipeline(
            asynchronousSampleBuild: true,
            nowNanoseconds: { 0 },
            sink: HeadlessVideoSink(receive: { _, _ in
                enteredRendererSeam.signal()
                releaseRendererSeam.wait()
            }))
        defer { releaseRendererSeam.signal() }
        for shard in shards {
            pipeline.ingest(
                envelope: shard.envelope,
                payload: shard.payload,
                now: ClientTimestamp(microseconds: 1_000))
        }
        XCTAssertEqual(
            enteredRendererSeam.wait(timeout: .now() + 5), .success)
    }
}
