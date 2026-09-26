import Glibc
@testable import HostEye
import XCTest

/// The render node is named by the device's own fd, never guessed. A
/// render node's fd names itself; opening one touches no display state.
final class RenderNodeTests: XCTestCase {
    func testADevicesFdNamesItsOwnRenderNode() throws {
        let path = DirectScreenSource.fallbackRenderNode
        let fd = open(path, O_RDWR | O_CLOEXEC)
        try XCTSkipIf(fd < 0, "no \(path) on this machine")
        defer { close(fd) }
        XCTAssertEqual(renderNode(forCard: fd), path)
    }

    func testAnFdThatIsNoDrmDeviceNamesNone() throws {
        let fd = open("/dev/null", O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertNil(renderNode(forCard: fd))
    }
}
