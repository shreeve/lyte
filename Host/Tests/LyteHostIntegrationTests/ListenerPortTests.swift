import CNetIO
@testable import lyte_host
import XCTest

/// Two hosts on one port fail loudly instead of silently sharing its
/// traffic, while a session's own media sockets still join the port.
final class ListenerPortTests: XCTestCase {
    func testASecondListenerOnAHeldPortIsRefused() throws {
        let first = try HostListener()
        let port = lyte_netio_local_port(first.netio)
        XCTAssertThrowsError(try HostListener(port: port)) { error in
            XCTAssertTrue("\(error)".contains("already bound"), "\(error)")
        }

        var err = [CChar](repeating: 0, count: 256)
        let media = lyte_netio_new("0.0.0.0", port, &err, err.count)
        XCTAssertNotNil(media, "a media socket joins the listening port")
        lyte_netio_free(media)
    }
}
