import AppKit
import XCTest
@testable import LyteUI

/// The pasteboard glue against a private named pasteboard (never the
/// user's general one): host images land as PNG with a TIFF promise that
/// renders on demand, the glue swallows its own writes, and a TIFF-only
/// local copy is read out as PNG.
final class PasteboardSyncTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: .init("dev.shreeve.lyte.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    private func pngBytes(width: Int = 3, height: Int = 2) throws -> [UInt8] {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return Array(try XCTUnwrap(rep.representation(using: .png, properties: [:])))
    }

    func testHostImageLandsAsPngWithTiffRenderedOnDemand() throws {
        let sync = PasteboardSync(pasteboard: pasteboard, onLocalChange: { _ in })
        let png = try pngBytes()
        sync.apply(imageData: png)

        XCTAssertEqual(pasteboard.data(forType: .png).map(Array.init), png)
        XCTAssertTrue(pasteboard.types?.contains(.tiff) == true)
        let tiff = try XCTUnwrap(pasteboard.data(forType: .tiff))
        XCTAssertEqual(NSBitmapImageRep(data: tiff)?.pixelsWide, 3)
    }

    func testOwnWritesAreSwallowedAndTiffOnlyCopiesReadAsPng() throws {
        let images = Received()
        let texts = Received()
        let sync = PasteboardSync(
            pasteboard: pasteboard, intervalMilliseconds: 10,
            onLocalChange: { texts.append(Array($0.utf8)) })
        sync.onLocalImageChange = { images.append($0) }
        sync.setImagesEnabled(true)
        sync.start()
        defer { sync.stop() }

        sync.apply(imageData: try pngBytes())
        sync.apply("from the host")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(images.all.isEmpty && texts.all.isEmpty,
                      "the glue's own writes must never echo back")

        // A local copy that only offers TIFF.
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: Data(try pngBytes(width: 5)))?
            .tiffRepresentation)
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        let deadline = Date().addingTimeInterval(2)
        while images.all.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let png = try XCTUnwrap(images.all.first)
        XCTAssertEqual(NSBitmapImageRep(data: Data(png))?.pixelsWide, 5)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UInt8]] = []
    func append(_ item: [UInt8]) { lock.withLock { items.append(item) } }
    var all: [[UInt8]] { lock.withLock { items } }
}
