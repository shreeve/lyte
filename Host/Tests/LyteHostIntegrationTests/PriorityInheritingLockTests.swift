import Foundation
@testable import lyte_host
import XCTest

/// The session lock excludes like any mutex, and `try` never waits.
final class PriorityInheritingLockTests: XCTestCase {
    func testTryFailsWhileAnotherThreadHoldsTheLock() {
        let lock = PriorityInheritingLock()
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread {
            lock.lock()
            held.signal()
            release.wait()
            lock.unlock()
            done.signal()
        }.start()
        held.wait()
        XCTAssertFalse(lock.try(), "held elsewhere")
        release.signal()
        done.wait()
        XCTAssertTrue(lock.try(), "free again")
        lock.unlock()
    }

    func testIncrementsUnderTheLockAreNeverLost() {
        let lock = PriorityInheritingLock()
        nonisolated(unsafe) var count = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<10_000 {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(count, 80_000)
    }
}
