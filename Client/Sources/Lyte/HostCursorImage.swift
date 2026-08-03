import AppKit
import LyteWire

/// E3: the 0x24 wire shape → the NSCursor the stream view wears.
/// Pixels arrive BGRA premultiplied, rows top-to-bottom (the DRM
/// ARGB8888 little-endian order) — exactly CGImage's
/// premultipliedFirst + byteOrder32Little reading.
enum HostCursorImage {
    /// `scale` maps host device pixels to view points so the worn
    /// cursor matches the video's on-glass magnification. A hidden
    /// shape becomes a clear 1×1 cursor (the host hid its pointer;
    /// NSCursor.hide is process-global and would leak past the view).
    static func cursor(
        from shape: CursorShape, scale: CGFloat
    ) -> NSCursor? {
        guard !shape.isHidden else {
            let clear = NSImage(size: NSSize(width: 1, height: 1))
            return NSCursor(image: clear, hotSpot: .zero)
        }
        let width = Int(shape.width), height = Int(shape.height)
        guard scale > 0,
              let provider = CGDataProvider(
                  data: Data(shape.pixels) as CFData),
              let cg = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue:
                      CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil,
                  shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let image = NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(width) * scale,
                         height: CGFloat(height) * scale))
        // NSCursor's hot spot lives in the image's flipped (top-left
        // origin) coordinates — the same orientation the wire uses.
        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: CGFloat(shape.hotspotX) * scale,
                             y: CGFloat(shape.hotspotY) * scale))
    }
}
