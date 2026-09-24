import XCTest
import LyteCore

final class DequeTests: XCTestCase {
    func testFifoOrderAcrossInterleavedAppendsAndRemovals() {
        var deque = Deque<Int>()
        var model: [Int] = []
        var next = 0
        for step in 0..<10_000 {
            if step % 3 == 2, !model.isEmpty {
                XCTAssertEqual(deque.removeFirst(), model.removeFirst())
            } else {
                deque.append(next)
                model.append(next)
                next += 1
            }
            XCTAssertEqual(deque.count, model.count)
            XCTAssertEqual(deque.first, model.first)
        }
        XCTAssertEqual(Array(deque), model)
    }

    /// A queue that never fully drains must not retain its consumed
    /// history: storage stays bounded by the live count, not the total
    /// ever appended.
    func testNeverDrainingQueueKeepsStorageBounded() {
        var deque = Deque<UInt64>()
        for value in 0..<64 { deque.append(UInt64(value)) }
        for value in 64..<200_000 {
            deque.append(UInt64(value))
            XCTAssertEqual(deque.removeFirst(), UInt64(value - 64))
        }
        XCTAssertEqual(deque.count, 64)
        XCTAssertLessThanOrEqual(deque.retainedCapacity, 512)
    }

    func testDrainingKeepsCapacityForTheNextBurst() {
        var deque = Deque<Int>(minimumCapacity: 16)
        for value in 0..<100 { deque.append(value) }
        let capacity = deque.retainedCapacity
        while deque.popFirst() != nil {}
        XCTAssertTrue(deque.isEmpty)
        XCTAssertEqual(deque.retainedCapacity, capacity)
        XCTAssertNil(deque.popFirst())
    }

    func testBulkRemovalAndPredicateRemovalKeepOrder() {
        var deque = Deque(0..<100)
        deque.removeFirst(40)
        XCTAssertEqual(deque.first, 40)
        deque.removeAll { $0.isMultiple(of: 2) }
        XCTAssertEqual(Array(deque), Array(stride(from: 41, to: 100, by: 2)))
        deque[0] = -1
        XCTAssertEqual(deque.first, -1)
        deque.removeAll()
        XCTAssertTrue(deque.isEmpty)
    }

    func testBoundedRingKeepsTheNewestInOrder() {
        var ring = BoundedRing<Int>(capacity: 4)
        XCTAssertNil(ring.append(0))
        XCTAssertEqual(Array(ring), [0])
        for value in 1..<4 { XCTAssertNil(ring.append(value)) }
        XCTAssertTrue(ring.isFull)
        for value in 4..<11 {
            XCTAssertEqual(ring.append(value), value - 4)
            XCTAssertEqual(Array(ring), Array((value - 3)...value))
        }
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        ring.append(42)
        XCTAssertEqual(Array(ring), [42])
    }
}
