// Renders Client/AppIcon's two SVG masters into an .iconset directory.
// usage: swift render-app-icon.swift ART_DIR ICONSET_DIR
//
// AppKit's SVG renderer keeps transparency (Quick Look's does not) but
// ignores SVG filters, so the Dock shadow is drawn here rather than in the
// artwork. The small master supplies 16 and 32 px; the full master the rest.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-app-icon.swift ART_DIR ICONSET_DIR\n".utf8))
    exit(64)
}
let art = URL(fileURLWithPath: arguments[1])
let iconset = URL(fileURLWithPath: arguments[2])

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: art.appendingPathComponent(name)) else {
        FileHandle.standardError.write(Data("cannot load \(name)\n".utf8))
        exit(1)
    }
    return image
}

let full = load("lyte-icon.svg")
let small = load("lyte-icon-small.svg")

func render(_ image: NSImage, pixels: Int, shadow: Bool, to name: String) {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { exit(1) }
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    if shadow {
        let dock = NSShadow()
        dock.shadowColor = NSColor(calibratedRed: 0, green: 0.07, blue: 0.25, alpha: 0.35)
        dock.shadowBlurRadius = 24 * scale
        dock.shadowOffset = NSSize(width: 0, height: -12 * scale)
        dock.set()
    }
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do {
        try png.write(to: iconset.appendingPathComponent("\(name).png"))
    } catch {
        FileHandle.standardError.write(Data("cannot write \(name): \(error)\n".utf8))
        exit(1)
    }
}

let sizes: [(NSImage, Int, String)] = [
    (small, 16, "icon_16x16"), (small, 32, "icon_16x16@2x"),
    (small, 32, "icon_32x32"), (full, 64, "icon_32x32@2x"),
    (full, 128, "icon_128x128"), (full, 256, "icon_128x128@2x"),
    (full, 256, "icon_256x256"), (full, 512, "icon_256x256@2x"),
    (full, 512, "icon_512x512"), (full, 1024, "icon_512x512@2x"),
]
for (image, pixels, name) in sizes {
    render(image, pixels: pixels, shadow: pixels >= 64, to: name)
}
