import AppKit
import XCTest
@testable import LyteUI

/// The menu-bar glyph is a system-tinted template of the icon's two
/// screens, and the front screen hides the rear one's lines behind it.
final class MenuBarGlyphTests: XCTestCase {
    private func alpha(at point: NSPoint, in bitmap: NSBitmapImageRep, scale: CGFloat) -> CGFloat {
        let x = Int(point.x * scale)
        let y = bitmap.pixelsHigh - 1 - Int(point.y * scale)
        return bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    func testTemplateGlyphOccludesTheRearScreenBehindTheFrontOne() throws {
        let glyph = MenuBarGlyph.image
        XCTAssertTrue(glyph.isTemplate)
        XCTAssertEqual(glyph.size, NSSize(width: 18, height: 18))

        let scale: CGFloat = 4
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        glyph.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
        NSGraphicsContext.restoreGraphicsState()

        // The rear screen's left edge (x 5.5 before the 0.9 fit) is drawn
        // above the front screen and knocked out inside it.
        func fitted(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: 9 + (x - 9) * 0.9, y: 9 + (y - 9) * 0.9)
        }
        XCTAssertGreaterThan(alpha(at: fitted(5.5, 12.5), in: bitmap, scale: scale), 0.5)
        XCTAssertEqual(alpha(at: fitted(5.5, 7.5), in: bitmap, scale: scale), 0, accuracy: 0.05)
        // The front screen's own outline survives the knockout.
        XCTAssertGreaterThan(alpha(at: fitted(9.8, 6.0), in: bitmap, scale: scale), 0.5)
    }
}
