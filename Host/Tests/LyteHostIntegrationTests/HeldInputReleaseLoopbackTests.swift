import Foundation
import Glibc
@testable import lyte_host
import LyteWire
import XCTest

/// A client that drops off the network mid-press cannot send the key's
/// release; the host releases what it holds once the path goes dark, not
/// at the 30 s liveness close.
final class HeldInputReleaseLoopbackTests: XCTestCase {
    func testASilentClientsHeldInputIsReleasedWhenItsPathGoesDark() throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0), peer: nil,
            rateBitsPerSecond: 1_000_000)
        let injector = HoldingInjector()
        wire.inputInjector = injector

        let client = try LoopbackDialer(
            port: wire.localPort, hostStaticPublicKey: hostStatic.publicKey)
        try client.dial()
        XCTAssertEqual(try awaitClient(
            wire, hostStatic: hostStatic, timeoutSeconds: 5
        ) {
            let reply = try XCTUnwrap(client.awaitMessage2())
            try client.confirm(message2: reply.payload)
        }, .established)

        // The dialer sends no feedback, so 350 ms later its path is dark.
        let deadline = Date().addingTimeInterval(3)
        while injector.releases == 0, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(injector.releases, 1,
            "held input is released when the session freezes")

        wire.shutdown(reason: .shuttingDown, lingerSeconds: 0)
        XCTAssertEqual(injector.releases, 2,
            "and again when the session closes")
    }
}

/// Reports one held key on every release; counts the calls.
private final class HoldingInjector: InputInjector {
    let name = "holding"
    private let lock = NSLock()
    private var releaseCount = 0

    var releases: Int {
        lock.lock()
        defer { lock.unlock() }
        return releaseCount
    }

    func inject(_ event: InputEvent) throws {}
    func noteMonitorExtent(width: UInt32, height: UInt32) {}

    func releaseHeld() -> Int {
        lock.lock()
        defer { lock.unlock() }
        releaseCount += 1
        return 1
    }

    func stop() {}
}
