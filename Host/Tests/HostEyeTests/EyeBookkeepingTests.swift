#if os(Linux)

@testable import HostEye
import XCTest

final class EyeBookkeepingTests: XCTestCase {
    func testGemHandlesCloseOncePerDistinctBufferObject() {
        XCTAssertEqual(uniqueGemHandles([7, 0, 0, 0]), [7])
        // CCS: the main and aux planes share one BO handle.
        XCTAssertEqual(uniqueGemHandles([7, 7, 9, 0]), [7, 9])
        XCTAssertEqual(uniqueGemHandles([0, 0, 0, 0]), [])
    }
}

#endif
