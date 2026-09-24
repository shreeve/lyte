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

    /// A writer clears (bumping the count) and fills the pasteboard under
    /// that same count. A tick that lands in between must neither consume
    /// the count (the copy would never be read) nor judge markers on the
    /// empty board (a concealed item written next would be read unvetted).
    func testATickBetweenClearAndWriteNeitherLosesNorLeaksTheCopy() throws {
        let texts = Received()
        let sync = PasteboardSync(
            pasteboard: pasteboard,
            onLocalChange: { texts.append(Array($0.utf8)) })

        pasteboard.clearContents()
        sync.poll()
        let concealed = NSPasteboardItem()
        concealed.setString("hunter2", forType: .string)
        concealed.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([concealed])
        sync.poll()
        sync.poll()
        XCTAssertTrue(texts.all.isEmpty)

        pasteboard.clearContents()
        sync.poll()
        let ordinary = NSPasteboardItem()
        ordinary.setString("ordinary", forType: .string)
        pasteboard.writeObjects([ordinary])
        sync.poll()
        sync.poll()
        XCTAssertEqual(texts.all, [Array("ordinary".utf8)])
    }

    /// A password manager that writes its string and then, in a separate
    /// call under the same count, adds the concealed marker: a tick in
    /// between must not ship the string before the marker lands.
    func testATickBetweenStringAndMarkerNeverShipsTheSecret() throws {
        let texts = Received()
        let sync = PasteboardSync(
            pasteboard: pasteboard,
            onLocalChange: { texts.append(Array($0.utf8)) })

        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        sync.poll()
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        sync.poll()
        sync.poll()
        sync.poll()
        XCTAssertTrue(texts.all.isEmpty, "the secret left before its marker")

        // An ordinary sequential copy still arrives, one tick later.
        pasteboard.clearContents()
        pasteboard.setString("ordinary", forType: .string)
        sync.poll()
        XCTAssertTrue(texts.all.isEmpty)
        sync.poll()
        XCTAssertEqual(texts.all, [Array("ordinary".utf8)])
        sync.poll()
        XCTAssertEqual(texts.all.count, 1, "a consumed change was read twice")
    }

    /// A password manager's copy carries a nspasteboard.org marker; it
    /// must never reach the host. The next ordinary copy still does.
    func testMarkedCopiesNeverLeaveTheMac() throws {
        let texts = Received()
        let images = Received()
        let sync = PasteboardSync(
            pasteboard: pasteboard, intervalMilliseconds: 10,
            onLocalChange: { texts.append(Array($0.utf8)) })
        sync.onLocalImageChange = { images.append($0) }
        sync.setImagesEnabled(true)
        sync.start()
        defer { sync.stop() }

        for marker in PasteboardSync.privateMarkers {
            let item = NSPasteboardItem()
            item.setString("hunter2", forType: .string)
            item.setData(Data(try pngBytes()), forType: .png)
            item.setData(Data(), forType: marker)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            Thread.sleep(forTimeInterval: 0.05)
        }
        pasteboard.clearContents()
        pasteboard.setString("ordinary", forType: .string)
        let deadline = Date().addingTimeInterval(2)
        while texts.all.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(texts.all, [Array("ordinary".utf8)])
        XCTAssertTrue(images.all.isEmpty)
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UInt8]] = []
    func append(_ item: [UInt8]) { lock.withLock { items.append(item) } }
    var all: [[UInt8]] { lock.withLock { items } }
}
