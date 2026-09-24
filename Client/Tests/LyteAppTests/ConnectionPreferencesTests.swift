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
        let hop = CoalescedMainActorHop(interval: .milliseconds(20)) { runs.bump() }
        for _ in 0..<200 { hop.schedule() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(runs.value, 1)
        hop.schedule()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(runs.value, 2, "a later change still lands")
    }
}

@MainActor
private final class Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
