import Foundation
import XCTest
@testable import Lyte

/// The App Nap / display-sleep assertion spans exactly the time any
/// stream runs, however many windows overlap.
final class StreamActivityTests: XCTestCase {
    func testOneAssertionSpansOverlappingStreams() {
        var begun = 0
        var ended: [ObjectIdentifier] = []
        let token = NSObject()
        var activity = StreamActivity(
            begin: { begun += 1; return token },
            end: { ended.append(ObjectIdentifier($0)) })

        activity.streamsChanged(to: 1)
        activity.streamsChanged(to: 2)
        activity.streamsChanged(to: 1)
        XCTAssertEqual(begun, 1)
        XCTAssertTrue(ended.isEmpty, "a stream still runs")
        activity.streamsChanged(to: 0)
        XCTAssertEqual(ended, [ObjectIdentifier(token)])
        activity.streamsChanged(to: 0)
        XCTAssertEqual(ended.count, 1, "ended once")

        activity.streamsChanged(to: 1)
        XCTAssertEqual(begun, 2, "the next stream asserts again")
    }
}
