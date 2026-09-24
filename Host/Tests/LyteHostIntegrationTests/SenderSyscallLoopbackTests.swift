import Foundation
import Glibc
@testable import lyte_host
import LyteIO
import LyteWire
import XCTest

/// A streaming session's sender thread wakes once per paced release.
/// Each pass reads only the sockets that polled readable, and samples
/// the kernel send queues at most once per pacer quantum while the
/// socket state is calm.
final class SenderSyscallLoopbackTests: XCTestCase {
    func testAStreamingSendersPassesSpendFewSyscalls() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0), peer: nil,
            rateBitsPerSecond: 100_000_000)
        let client = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        try client.dial()
        XCTAssertEqual(try awaitClient(
            wire, hostStatic: hostStatic, timeoutSeconds: 5
        ) {
            let reply = try XCTUnwrap(client.awaitMessage2())
            try client.confirm(message2: reply.payload)
        }, .established)

        // The client's 40 ms feedback keeps the path live.
        let stop = DispatchSemaphore(value: 0)
        let fed = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let feeder = client
        Thread {
            repeat {
                try? feeder.sendFeedback()
            } while stop.wait(timeout: .now() + .milliseconds(20)) == .timedOut
            fed.signal()
        }.start()

        // Two seconds of 60 fps, 40 KB frames: about 20 Mbps.
        let frame: [UInt8] = [0, 0, 0, 1, 0x02, 0x01]
            + [UInt8](repeating: 0xAA, count: 40_000)
        for _ in 0..<120 {
            try frame.withUnsafeBufferPointer {
                try wire.sendFrame(
                    data: $0.baseAddress!, size: $0.count,
                    isKeyframe: false,
                    captureMicros: SystemMonotonicClock.nowMicroseconds)
            }
            usleep(16_667)
        }
        stop.signal()
        fed.wait()
        wire.shutdown(reason: .shuttingDown, lingerSeconds: 0)

        let passes = wire.drainPasses
        let perPassReceives = Double(wire.receiveCalls) / Double(max(passes, 1))
        let perPassQueries = Double(wire.outqQueries) / Double(max(passes, 1))
        print("""
            sender: \(passes) passes, \(wire.receiveCalls) recvmmsg \
            (\(String(format: "%.2f", perPassReceives))/pass), \
            \(wire.outqQueries) SIOCOUTQ \
            (\(String(format: "%.2f", perPassQueries))/pass), \
            \(wire.outboxCounters.datagramsSent) datagrams sent
            """)
        XCTAssertGreaterThan(wire.outboxCounters.datagramsSent, 1_000,
            "the frames streamed")
        XCTAssertLessThan(perPassReceives, 1.5,
            "a pass reads only what polled readable")
        XCTAssertLessThan(perPassQueries, 1.0,
            "the send queues are sampled once per quantum while calm")
    }
}
