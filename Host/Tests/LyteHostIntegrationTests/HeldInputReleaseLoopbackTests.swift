import Foundation
import Glibc
import HostCore
@testable import lyte_host
import LyteWire
import XCTest

/// A client that drops off the network mid-press cannot send the key's
/// release. The host rides out an ordinary network hitch with everything
/// still held, releases the keys a compositor would autorepeat after a
/// long silence, and releases modifiers and pointer buttons only when the
/// session closes.
final class HeldInputReleaseLoopbackTests: XCTestCase {
    private static let keyA: UInt32 = 30
    private static let leftShift: UInt32 = 42
    private static let leftButton: UInt32 = 0x110

    func testHeldInputRidesOutAHitchAndOnlyRepeatingKeysGoAfterLongSilence()
        throws {
        let hostStatic = NoiseKeyPair.generate()
        let wire = try SessionWire(
            listener: HostListener(port: 0),
            rateBitsPerSecond: 1_000_000)
        let injector = HoldingInjector()
        injector.hold(keys: [Self.keyA, Self.leftShift], buttons: [Self.leftButton])
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

        func feedback(forSeconds seconds: Double) throws {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                try client.sendFeedback()
                usleep(40_000)
            }
        }

        // A live client's 40 ms feedback, one 400 ms hitch (past the
        // 350 ms FROZEN detector), then feedback again: nothing released.
        try feedback(forSeconds: 0.4)
        usleep(400_000)
        try feedback(forSeconds: 0.4)
        XCTAssertEqual(injector.released, [], "a hitch releases nothing")

        // 2.5 s of silence: the letter goes, Shift and the button stay.
        usleep(2_500_000)
        XCTAssertEqual(injector.released, [Self.keyA])
        try feedback(forSeconds: 0.2)
        XCTAssertEqual(injector.released, [Self.keyA])

        wire.shutdown(reason: .shuttingDown, lingerSeconds: 0)
        XCTAssertEqual(injector.released,
                       [Self.keyA, Self.leftShift, Self.leftButton],
                       "the close releases everything still held")
    }
}

/// Holds a scripted set of keys and buttons; records every code a
/// release takes, in order.
private final class HoldingInjector: InputInjector {
    let name = "holding"
    private let lock = NSLock()
    private var book = HeldInputBook()
    private var releasedCodes: [UInt32] = []

    var released: [UInt32] { lock.withLock { releasedCodes } }

    func hold(keys: [UInt32], buttons: [UInt32]) {
        lock.withLock {
            for key in keys { book.noteKey(key, pressed: true) }
            for button in buttons { book.noteButton(button, pressed: true) }
        }
    }

    func inject(_ event: InputEvent) throws {}
    func noteMonitorExtent(width: UInt32, height: UInt32) {}

    func releaseHeld(_ scope: HeldInputBook.Scope) -> Int {
        lock.withLock {
            let codes = book.takeReleases(scope)
            releasedCodes += codes
            return codes.count
        }
    }

    func stop() {}
}
