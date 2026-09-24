import AppKit

/// The menu-bar glyph: the app icon's two overlapping screens as outlines,
/// the front screen knocking out the rear one's lines where it covers them.
/// A template image, so the system tints it for the menu bar's appearance.
public enum MenuBarGlyph {
    public static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let fit = NSAffineTransform()
            fit.translateX(by: side / 2, yBy: side / 2)
            fit.scale(by: 0.9)
            fit.translateX(by: -side / 2, yBy: -side / 2)
            fit.concat()
            let rear = outline([(5.5, 14.0), (17.3, 16.0), (17.3, 5.5), (5.5, 6.4)])
            let front = outline([(0.7, 9.1), (9.8, 10.3), (9.8, 2.1), (0.7, 3.0)])
            NSColor.black.set()
            rear.stroke()
            NSGraphicsContext.current?.compositingOperation = .clear
            front.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            front.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lyte"
        return image
    }()

    private static func outline(_ corners: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: corners[0].0, y: corners[0].1))
        for corner in corners.dropFirst() {
            path.line(to: NSPoint(x: corner.0, y: corner.1))
        }
        path.close()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        return path
    }
}
