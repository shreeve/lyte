import Darwin
import Foundation
import XCTest
@testable import lyte_helperd

/// The root helper's hold accounting, with awdl0's switch replaced by a
/// recorder: holds are per connection, released exactly once, and a
/// vanished connection can never strand the radio down.
final class AwdlHoldControllerTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [Bool] = []
        private var _idles = 0
        var states: [Bool] { lock.withLock { _states } }
        var idles: Int { lock.withLock { _idles } }
        func record(_ up: Bool) { lock.withLock { _states.append(up) } }
        func idle() { lock.withLock { _idles += 1 } }
    }

    private func makeController(
        _ recorder: Recorder, idleExitDelay: DispatchTimeInterval = .seconds(60),
        heldMarker: URL? = nil
    ) -> AwdlHoldController {
        AwdlHoldController(configuration: .init(
            setAwdlUp: { recorder.record($0) },
            watchRoutes: false,
            backstopInterval: .seconds(60),
            idleExitDelay: idleExitDelay,
            onIdle: { recorder.idle() },
            heldMarker: heldMarker))
    }

    private func temporaryMarker() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("awdl-held")
    }

    // MARK: - A killed predecessor

    /// A daemon killed mid-hold (crash, SIGKILL) restores nothing; its
    /// successor must raise awdl0 before serving anyone.
    func testSuccessorRestoresTheRadioAKilledHolderLeftDown() throws {
        let marker = try temporaryMarker()
        let killed = makeController(Recorder(), heldMarker: marker)
        killed.streamBegan(killed.makeOwner())
        XCTAssertEqual(killed.outstandingHolds, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let recorder = Recorder()
        let successor = makeController(recorder, heldMarker: marker)
        successor.reconcileAfterUncleanExit()
        XCTAssertEqual(recorder.states, [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        successor.reconcileAfterUncleanExit()
        XCTAssertEqual(recorder.states, [true], "reconciles once")
    }

    func testCleanReleaseLeavesNothingToReconcile() throws {
        let marker = try temporaryMarker()
        let clean = makeController(Recorder(), heldMarker: marker)
        let owner = clean.makeOwner()
        clean.streamBegan(owner)
        clean.streamEnded(owner)
        XCTAssertEqual(clean.outstandingHolds, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let recorder = Recorder()
        makeController(recorder, heldMarker: marker).reconcileAfterUncleanExit()
        XCTAssertEqual(recorder.states, [], "a clean exit is not second-guessed")
    }

    func testLastStreamOutRestoresTheRadio() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let app = controller.makeOwner()
        controller.streamBegan(app)
        controller.streamBegan(app)
        controller.streamEnded(app)
        XCTAssertEqual(controller.outstandingHolds, 1)
        XCTAssertEqual(recorder.states, [false])
        controller.streamEnded(app)
        XCTAssertEqual(controller.outstandingHolds, 0)
        XCTAssertEqual(recorder.states, [false, true])
    }

    func testVanishedConnectionReleasesOnlyItsOwnHolds() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let crashed = controller.makeOwner()
        let alive = controller.makeOwner()
        controller.streamBegan(crashed)
        controller.streamBegan(crashed)
        controller.streamBegan(alive)
        controller.ownerVanished(crashed)
        XCTAssertEqual(controller.outstandingHolds, 1)
        XCTAssertEqual(recorder.states, [false], "the live stream still needs the hold")
        controller.streamEnded(alive)
        XCTAssertEqual(controller.outstandingHolds, 0)
        XCTAssertEqual(recorder.states, [false, true])
    }

    func testCallDeliveredAfterInvalidationCannotStrandTheRadio() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let owner = controller.makeOwner()
        // Invalidation overtakes a streamBegan delivered on another thread.
        controller.ownerVanished(owner)
        controller.streamBegan(owner)
        XCTAssertEqual(controller.outstandingHolds, 0)
        XCTAssertEqual(recorder.states, [], "a dead connection never takes a hold")
    }

    func testUnbalancedEndFromOneConnectionNeverStealsAnothersHold() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let a = controller.makeOwner()
        let b = controller.makeOwner()
        controller.streamBegan(a)
        controller.streamEnded(b)
        controller.streamEnded(b)
        XCTAssertEqual(controller.outstandingHolds, 1)
        XCTAssertEqual(recorder.states, [false])
    }

    func testShutdownRestoresWhileHolding() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.streamBegan(controller.makeOwner())
        controller.restoreForShutdown()
        XCTAssertEqual(recorder.states, [false, true])
        controller.restoreForShutdown()
        XCTAssertEqual(recorder.states, [false, true], "restore is idempotent")
    }

    /// SIGTERM restores, then the process exits; a stream start queued
    /// behind the restore must not take awdl0 down with nobody left to
    /// bring it back.
    func testStreamStartAfterShutdownRestoreIsRefused() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let app = controller.makeOwner()
        controller.streamBegan(app)
        controller.restoreForShutdown()
        controller.streamBegan(app)
        controller.streamBegan(controller.makeOwner())
        XCTAssertEqual(controller.outstandingHolds, 0)
        XCTAssertEqual(recorder.states, [false, true])
    }

    func testIdleExitFiresOnlyWhenNothingHolds() {
        let recorder = Recorder()
        let controller = makeController(recorder, idleExitDelay: .milliseconds(20))
        let owner = controller.makeOwner()
        controller.streamBegan(owner)
        controller.streamEnded(owner)
        // A new stream inside the linger cancels the exit.
        controller.streamBegan(owner)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(recorder.idles, 0)
        controller.streamEnded(owner)
        let deadline = Date().addingTimeInterval(2)
        while recorder.idles == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(recorder.idles, 1)
    }

    /// The app's launch-time version probe connects, asks, and leaves
    /// without a hold: the daemon it spawned must still go idle.
    func testConnectionThatNeverHeldStillLeadsToIdleExit() {
        let recorder = Recorder()
        let controller = makeController(recorder, idleExitDelay: .milliseconds(20))
        controller.ownerVanished(controller.makeOwner())
        let deadline = Date().addingTimeInterval(2)
        while recorder.idles == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(recorder.idles, 1)
        XCTAssertEqual(recorder.states, [], "no hold, no radio change")
    }

    // MARK: - Interface control

    func testFlagRequestsMatchTheSDKEncoding() {
        XCTAssertEqual(InterfaceControl.getFlagsRequest, 0xC020_6911)
        XCTAssertEqual(InterfaceControl.setFlagsRequest, 0x8020_6910)
    }

    func testLoopbackFlagsReadThroughTheIoctl() throws {
        let flags = try XCTUnwrap(InterfaceControl.flags(of: "lo0"))
        XCTAssertNotEqual(flags & IFF_UP, 0)
        XCTAssertNotEqual(flags & IFF_LOOPBACK, 0)
        XCTAssertNil(InterfaceControl.flags(of: "nope9"))
    }

    func testOnlyTheInterfacesOwnUpEdgeReasserts() {
        func message(type: Int32, index: UInt16, flags: Int32) -> [UInt8] {
            var header = if_msghdr()
            header.ifm_msglen = UInt16(MemoryLayout<if_msghdr>.size)
            header.ifm_version = UInt8(RTM_VERSION)
            header.ifm_type = UInt8(type)
            header.ifm_index = index
            header.ifm_flags = flags
            return withUnsafeBytes(of: header) { Array($0) }
        }
        let up = Int32(IFF_UP | IFF_RUNNING)
        XCTAssertTrue(InterfaceControl.isUpEdge(
            routingMessage: message(type: RTM_IFINFO, index: 9, flags: up)[...],
            interfaceIndex: 9))
        XCTAssertFalse(InterfaceControl.isUpEdge(
            routingMessage: message(type: RTM_IFINFO, index: 9, flags: 0)[...],
            interfaceIndex: 9), "our own down-edge must not re-enter")
        XCTAssertFalse(InterfaceControl.isUpEdge(
            routingMessage: message(type: RTM_IFINFO, index: 4, flags: up)[...],
            interfaceIndex: 9), "other interfaces are ignored")
        XCTAssertFalse(InterfaceControl.isUpEdge(
            routingMessage: message(type: RTM_NEWADDR, index: 9, flags: up)[...],
            interfaceIndex: 9), "address churn is ignored")
        XCTAssertFalse(InterfaceControl.isUpEdge(
            routingMessage: [UInt8](repeating: 0, count: 4)[...], interfaceIndex: 9))
    }
}
