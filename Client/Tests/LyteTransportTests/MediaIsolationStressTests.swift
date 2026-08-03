import AVFoundation
import Foundation
import LyteCore
import LyteWire
import XCTest
@testable import LyteTransport

final class MediaIsolationStressTests: XCTestCase {
    private static var corpusDirectory: String {
        ClientTestPaths.videoCorpus
    }

    func testVideoBuildBackpressureCannotBlockAudioPlcOrDeclick() throws {
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

        // Hold the production sample worker at the renderer seam. If video
        // still owned the receive thread or an audio lock, the deterministic
        // audio work below could not complete before this semaphore opens.
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

        // Simulated not-ready renderer: memory stays bounded and one whole
        // video episode recovers while audio continues independently.
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 3, deadlineMicroseconds: 50_000))
        _ = handoff.offer(0, frame: .init(
            isRandomAccess: true, submittedMicroseconds: 0))
        _ = handoff.offer(1, frame: .init(
            isRandomAccess: false, submittedMicroseconds: 1_000))
        _ = handoff.offer(2, frame: .init(
            isRandomAccess: false, submittedMicroseconds: 2_000))
        let pressure = handoff.offer(
            3, frame: .init(
                isRandomAccess: false, submittedMicroseconds: 3_000))
        XCTAssertTrue(pressure.recoveryRequested)
        XCTAssertLessThanOrEqual(handoff.count, 3)

        // The pump's missing packet remains an explicit PLC verdict.
        let jitter = AudioJitterBuffer()
        for number: UInt32 in [0, 1, 3, 4, 5] {
            jitter.insert(
                AudioPacket(
                    number: number,
                    captureMicroseconds: UInt64(number) * 5_000,
                    bytes: [UInt8(number), 1, 2, 3],
                    recovered: false),
                arrivalMicroseconds: UInt64(number) * 5_000)
        }
        XCTAssertEqual(
            jitter.pull(nowMicroseconds: 30_000, urgent: true),
            .packet(AudioPacket(
                number: 0, captureMicroseconds: 0,
                bytes: [0, 1, 2, 3], recovered: false)))
        XCTAssertEqual(
            jitter.pull(nowMicroseconds: 35_000, urgent: true),
            .packet(AudioPacket(
                number: 1, captureMicroseconds: 5_000,
                bytes: [1, 1, 2, 3], recovered: false)))
        XCTAssertEqual(
            jitter.pull(nowMicroseconds: 40_000, urgent: true),
            .conceal(number: 2))
        XCTAssertEqual(jitter.snapshotStats().plcInvocations, 1)

        // Render-ring starvation and recovery stay click-free while the
        // video worker is still blocked.
        let ring = AudioPcmRing()
        ring.write(sine(0..<250))
        let cut = render(ring, wanted: 260)
        ring.write(sine(250..<650))
        let resumed = render(ring, wanted: 128)
        XCTAssertLessThan(maxAdjacentDelta(cut + resumed), 0.1)
    }

    private func sine(_ range: Range<Int>) -> [Float] {
        range.flatMap { n -> [Float] in
            let sample = Float(0.9 * sin(2 * Double.pi * Double(n) / 200))
            return [Float](repeating: sample, count: AudioWire.channels)
        }
    }

    private func render(_ ring: AudioPcmRing, wanted: Int) -> [Float] {
        let buffers = AudioBufferList.allocate(
            maximumBuffers: AudioWire.channels)
        var storage: [UnsafeMutablePointer<Float>] = []
        for channel in 0..<AudioWire.channels {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: wanted)
            pointer.initialize(repeating: .nan, count: wanted)
            buffers[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(wanted * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer))
            storage.append(pointer)
        }
        defer {
            storage.forEach { $0.deallocate() }
            free(buffers.unsafeMutablePointer)
        }
        ring.render(into: buffers, wanted: wanted)
        return (0..<wanted).map { storage[0][$0] }
    }

    private func maxAdjacentDelta(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).reduce(0) {
            max($0, abs($1.0 - $1.1))
        }
    }
}
