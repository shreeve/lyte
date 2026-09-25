import Foundation
import Glibc
@testable import lyte_host
import LyteIO
import LyteWire
import XCTest

/// A streaming session's sender thread wakes once per paced release.
/// Each pass reads only the sockets that polled readable, and the kernel
/// send queues are sampled at most once per pacer quantum while the
/// socket state is calm. How many passes a run takes depends on how the
/// machine schedules the sender, so the sampling is judged per datagram
/// sent, which the stream fixes.
final class SenderSyscallLoopbackTests: XCTestCase {
    func testAStreamingSendersPassesSpendFewSyscalls() throws {
        let hostStatic = NoiseKeyPair.generate()
        let rate = 100_000_000
        let wire = try SessionWire(
            listener: HostListener(hostStatic: hostStatic),
            rateBitsPerSecond: rate)
        let client = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        try client.dial()
        XCTAssertEqual(try awaitClient(
            wire, timeoutSeconds: 5
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

        let sent = wire.outboxCounters.datagramsSent
        let perPassReceives =
            Double(wire.receiveCalls) / Double(max(wire.drainPasses, 1))
        let perDatagramQueries = Double(wire.outqQueries) / Double(max(sent, 1))
        // A 1 ms quantum at the pacer rate carries this many full
        // datagrams, and one sample queries both media sockets: the bound
        // is twice one sample per quantum.
        let datagramsPerQuantum =
            Double(rate) / 8 / 1_000 / Double(WireBudget.maxDatagramByteCount)
        XCTAssertGreaterThan(sent, 1_000, "the frames streamed")
        XCTAssertLessThan(perPassReceives, 1.5,
            "a pass reads only what polled readable")
        XCTAssertLessThan(perDatagramQueries, 2 * 2 / datagramsPerQuantum,
            """
                the send queues are sampled about once per quantum while \
                calm: \(wire.outqQueries) SIOCOUTQ for \(sent) datagrams
                """)
    }
}
