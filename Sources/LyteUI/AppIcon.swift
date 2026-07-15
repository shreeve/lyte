import AppKit

/// Programmatic app icon for the unbundled dev CLI: an indigo→blue squircle
/// with a white bolt. Used for the Dock and the About panel until M5 ships a
/// real asset-catalog icon.
enum AppIcon {
    static let shared: NSImage = make()

    private static func make() -> NSImage {
        let canvas = NSSize(width: 512, height: 512)
        return NSImage(size: canvas, flipped: false) { _ in
            // Apple icon grid: content squircle inset from the canvas
            let box = NSRect(x: 52, y: 52, width: 408, height: 408)
            let squircle = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225,
                                        yRadius: box.width * 0.225)

            NSGraphicsContext.saveGraphicsState()
            let dropShadow = NSShadow()
            dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            dropShadow.shadowOffset = NSSize(width: 0, height: -6)
            dropShadow.shadowBlurRadius = 18
            dropShadow.set()
            NSColor.black.withAlphaComponent(0.2).setFill()
            squircle.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            squircle.addClip()
            NSGradient(colors: [
                NSColor(calibratedRed: 0.32, green: 0.18, blue: 0.92, alpha: 1),
                NSColor(calibratedRed: 0.10, green: 0.58, blue: 1.00, alpha: 1),
            ])?.draw(in: box, angle: -65)
            NSGraphicsContext.restoreGraphicsState()

            // White bolt, slightly oversized, gently shadowed
            let config = NSImage.SymbolConfiguration(pointSize: 240, weight: .semibold)
            guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Lyte")?
                .withSymbolConfiguration(config) else { return true }
            let tinted = NSImage(size: bolt.size, flipped: false) { rect in
                bolt.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let symbolSize = NSSize(width: tinted.size.width * 1.1, height: tinted.size.height * 1.1)
            let symbolRect = NSRect(x: box.midX - symbolSize.width / 2,
                                    y: box.midY - symbolSize.height / 2,
                                    width: symbolSize.width, height: symbolSize.height)
            NSGraphicsContext.saveGraphicsState()
            let symbolShadow = NSShadow()
            symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            symbolShadow.shadowOffset = NSSize(width: 0, height: -4)
            symbolShadow.shadowBlurRadius = 10
            symbolShadow.set()
            tinted.draw(in: symbolRect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}
