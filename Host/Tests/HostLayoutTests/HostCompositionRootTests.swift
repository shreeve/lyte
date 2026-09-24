import Foundation
import LyteTestKit
import XCTest

final class HostCompositionRootTests: XCTestCase {
    func testShippingHostHasNoPlaintextTransportMode() throws {
        let tree = RepositorySourceTree()
        let files = try tree.swiftFiles(below: "Host/Sources/lyte-host")
        for file in files {
            let shippingSource = try String(contentsOf: file, encoding: .utf8)
            let path = tree.relativePath(for: file)
            for retiredWitness in ["--insecure", "testPassthrough"] {
                XCTAssertFalse(
                    shippingSource.contains(retiredWitness),
                    "shipping plaintext witness \(retiredWitness) returned in \(path)"
                )
            }
        }
    }
}
