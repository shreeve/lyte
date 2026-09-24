import Foundation
import LyteTransport
import XCTest
@testable import Lyte

/// Per-host preferences are read once per connect and written through:
/// menus and views that read them on every render never touch the disk.
@MainActor
final class ConnectionPreferencesTests: XCTestCase {
    func testPreferenceReadsNeverReloadTheStore() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.succeed]
        let model = ConnectionModel(services: harness.services)
        await model.connectLyte(harness.host)
        let loads = harness.pinLoads

        for _ in 0..<50 {
            _ = model.startHostMutedPreference
            _ = model.shareClipboardPreference
            _ = model.shareClipboardImagesPreference
        }
        XCTAssertEqual(harness.pinLoads, loads, "a menu render must not read the disk")
    }

    func testPreferenceWritesGoThroughAndReadBack() async throws {
        let harness = LifecycleHarness()
        harness.startPlan = [.succeed]
        let model = ConnectionModel(services: harness.services)
        await model.connectLyte(harness.host)
        let pkh = try XCTUnwrap(harness.host.publicKeyHash)

        XCTAssertTrue(model.startHostMutedPreference, "unset means start muted")
        XCTAssertFalse(model.shareClipboardPreference, "clipboard defaults off")

        model.startHostMutedPreference = false
        model.shareClipboardPreference = true
        XCTAssertFalse(model.startHostMutedPreference)
        XCTAssertTrue(model.shareClipboardPreference)
        let stored = try XCTUnwrap(harness.savedPins.host(publicKeyHash: pkh))
        XCTAssertEqual(stored.startHostAudioMuted, false)
        XCTAssertEqual(stored.shareClipboard, true)
        XCTAssertEqual(harness.pinSaves, 2)
    }

    func testCoalescedHopRunsOnceForABurst() async throws {
        let runs = Counter()
        let clock = ManualSleeper()
        let hop = CoalescedMainActorHop(
            interval: .milliseconds(100), sleep: clock.sleep
        ) { runs.bump() }

        for _ in 0..<200 { hop.schedule() }
        try await clock.waitForSleepers(1)
        XCTAssertEqual(clock.requested, [.milliseconds(100)],
                       "a burst waits out one interval, once")
        XCTAssertEqual(runs.value, 0, "nothing runs before the interval")
        clock.wakeAll()
        try await waitUntil { runs.value == 1 }

        hop.schedule()
        try await clock.waitForSleepers(1)
        XCTAssertEqual(clock.requested.count, 2)
        clock.wakeAll()
        try await waitUntil { runs.value == 2 }
        XCTAssertEqual(runs.value, 2, "a later change still lands")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition never held")
    }
}

/// A virtual clock for `CoalescedMainActorHop`: every sleep parks until
/// the test wakes it.
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var durations: [Duration] = []

    var requested: [Duration] { lock.withLock { durations } }

    var sleep: CoalescedMainActorHop.Sleep {
        { [self] duration in
            await withCheckedContinuation { continuation in
                lock.withLock {
                    durations.append(duration)
                    parked.append(continuation)
                }
            }
        }
    }

    func waitForSleepers(_ count: Int) async throws {
        for _ in 0..<10_000 {
            if lock.withLock({ parked.count }) >= count { return }
            await Task.yield()
        }
        XCTFail("no sleeper parked")
    }

    func wakeAll() {
        let woken = lock.withLock {
            defer { parked.removeAll() }
            return parked
        }
        for continuation in woken { continuation.resume() }
    }
}

@MainActor
private final class Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
