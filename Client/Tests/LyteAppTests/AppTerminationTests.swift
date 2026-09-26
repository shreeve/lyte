import Foundation
import XCTest
@testable import Lyte

/// Quitting says goodbye: every window's session is closed with the typed
/// teardown, and termination waits for those closes — but never forever.
@MainActor
final class AppTerminationTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    func testQuitWaitsForEveryGoodbyeToFinish() async {
        let closes = SessionCloses()
        let finished = Counter()
        for _ in 0..<3 {
            closes.run {
                Thread.sleep(forTimeInterval: 0.05)
                finished.add()
            }
        }
        let drained = expectation(description: "drained")
        closes.whenDrained(within: .seconds(10)) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(finished.count, 3, "quit ran ahead of a goodbye")
    }

    func testAStuckCloseCannotHoldQuitHostage() async throws {
        let closes = SessionCloses()
        let release = DispatchSemaphore(value: 0)
        closes.run { release.wait() }
        let replies = Counter()
        let drained = expectation(description: "drained")
        let started = ContinuousClock.now
        closes.whenDrained(within: .milliseconds(100)) {
            replies.add()
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(replies.count, 1, "termination is answered exactly once")
    }

    func testDisconnectAllSaysGoodbyeOnEveryOpenWindow() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.succeed]
        let model = ConnectionModel(services: harness.services)
        try await harness.connect(model)
        let session = try XCTUnwrap(model.lyteSession)
        OpenConnections.shared.insert(model)

        OpenConnections.shared.disconnectAll()

        XCTAssertEqual(harness.endings(of: session), [.goodbye])
        guard case .pickHost = model.phase else {
            return XCTFail("the window kept streaming: \(model.phase)")
        }
    }
}
