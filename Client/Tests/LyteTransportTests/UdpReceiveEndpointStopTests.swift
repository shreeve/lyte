// The stop()-joins-before-close pin (analysis finding 12's residue).
// stop() must not return — and must not free the fd number — while the
// receive thread is still inside its datagram handling: a roaming
// re-dial that binds a fresh socket in that window can be handed the
// recycled fd, and the old loop steals its datagrams. The contract this
// pins: when stop() returns, the receive thread's work is finished.

import Foundation
import LyteCore
import LyteWire
import XCTest

@testable import LyteTransport

private struct PassthroughCrypto: TransportCrypto {
    var modeDescription: String { "passthrough test crypto" }
    func open() throws {}
    func seal(
        plaintext: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] { Array(plaintext) }
    func unseal(
        wirePayload: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] { Array(wirePayload) }
}

final class UdpReceiveEndpointStopTests: XCTestCase {
    func testSocketUsesSharedProtectedTosAndNamedVideoServiceClass() throws {
        let endpoint = UdpReceiveEndpoint(port: 0, crypto: PassthroughCrypto())
        try endpoint.start()
        defer { endpoint.stop() }

        var tos: Int32 = -1
        var tosLength = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(endpoint.fd, IPPROTO_IP, IP_TOS, &tos, &tosLength), 0
        )
        XCTAssertEqual(tos, Int32(WireTos.protected))

        var serviceType: Int32 = -1
        var serviceTypeLength = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(
                endpoint.fd, SOL_SOCKET, SO_NET_SERVICE_TYPE,
                &serviceType, &serviceTypeLength
            ),
            0
        )
        XCTAssertEqual(serviceType, NET_SERVICE_TYPE_VI)
    }

    /// A datagram handler blocks mid-flight while another thread calls
    /// stop(): stop() must wait for the handler (the receive thread) to
    /// finish before returning. Pre-fix, stop() closed the fd and could
    /// return with the thread still running inside the loop.
    func testStopJoinsTheReceiveThreadBeforeReturning() throws {
        let handlerEntered = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var handlerFinished = false
        let endpoint = UdpReceiveEndpoint(
            port: 0, crypto: PassthroughCrypto()
        ) { _, _ in
            handlerEntered.signal()
            releaseHandler.wait()
            handlerFinished = true
        }
        try endpoint.start()

        // One datagram to self drives the loop into the blocked handler.
        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { close(sender) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.boundPort.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let payload: [UInt8] = [0x01, 0x02, 0x03]
        _ = payload.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sender, buf.baseAddress, buf.count, 0,
                           sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(
            handlerEntered.wait(timeout: .now() + 5), .success,
            "the receive loop never saw the datagram")

        // stop() from another thread while the handler is pinned.
        let stopReturned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            endpoint.stop()
            stopReturned.signal()
        }
        // stop() must NOT return while the handler still blocks —
        // 300 ms is three receive-timeout periods of margin.
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + 0.3), .timedOut,
            "stop() returned while the receive thread was still working "
            + "— the fd number was freed under a live loop")
        XCTAssertFalse(handlerFinished)
        // The discriminating observable: the fd number must still be
        // OURS while the thread lives. Pre-fix, stop() closed it at
        // entry — a concurrent re-dial could be handed the recycled
        // number while this loop still runs.
        XCTAssertGreaterThanOrEqual(
            endpoint.fd, 0,
            "the fd was freed before the receive thread was joined")

        releaseHandler.signal()
        XCTAssertEqual(
            stopReturned.wait(timeout: .now() + 5), .success,
            "stop() never returned after the handler finished")
        XCTAssertTrue(handlerFinished,
                      "stop() returned before the handler completed")
    }
}
