import HostSession
import XCTest

final class AnsweredHandshakeMemoryTests: XCTestCase {
    private func message1(_ ephemeral: UInt8, tail: UInt8 = 0) -> [UInt8] {
        [UInt8](repeating: ephemeral, count: 32)
            + [UInt8](repeating: tail, count: 64)
    }

    func testAnAnsweredMessage1IsKnownByItsEphemeral() {
        var memory = AnsweredHandshakeMemory()
        XCTAssertFalse(memory.contains(message1: message1(1)))
        memory.record(message1: message1(1))
        XCTAssertTrue(memory.contains(message1: message1(1)))
        XCTAssertTrue(memory.contains(message1: message1(1, tail: 9)),
                      "the same ephemeral is the same dial")
        XCTAssertFalse(memory.contains(message1: message1(2)))
    }

    func testShortInputsAreNeverKnown() {
        var memory = AnsweredHandshakeMemory()
        memory.record(message1: [UInt8](repeating: 1, count: 8))
        XCTAssertEqual(memory.count, 0)
        XCTAssertFalse(memory.contains(message1: [UInt8](repeating: 1, count: 8)))
    }

    func testTheOldestAgeOutPastCapacity() {
        var memory = AnsweredHandshakeMemory(capacity: 3)
        for e in UInt8(1)...4 { memory.record(message1: message1(e)) }
        XCTAssertEqual(memory.count, 3)
        XCTAssertFalse(memory.contains(message1: message1(1)))
        for e in UInt8(2)...4 {
            XCTAssertTrue(memory.contains(message1: message1(e)))
        }
        memory.record(message1: message1(3))
        XCTAssertEqual(memory.count, 3, "a repeat takes no slot")
        memory.record(message1: message1(5))
        XCTAssertFalse(memory.contains(message1: message1(2)))
        XCTAssertTrue(memory.contains(message1: message1(3)))
    }
}
