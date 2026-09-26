import LyteClientTestKit
import Foundation
import LyteWire
import XCTest
@testable import LyteTransport

final class MediaIsolationStressTests: XCTestCase {
    /// A sample build stalled at the renderer seam holds only the sample
    /// worker: ingest (the receive thread) returns with it still blocked.
    func testVideoBuildBackpressureNeverHoldsTheReceiveThread() throws {
        let idr = try ClientTestPaths.videoCorpusFrames(1)[0]
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
