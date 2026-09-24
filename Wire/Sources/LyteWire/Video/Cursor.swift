// Cursor-shape sync: the video carries no composited cursor (the client's
// local cursor gives zero-latency positioning), so the host announces each
// hardware-cursor-plane shape change as metadata and the client wears it
// as the local cursor over the video view.
//
// CursorShape (0x24), host→client only, rides the ARQ ordered CTRL stream
// (group 0): ordering is the contract and the last delivered shape wins.
// Layout (little-endian):
//
//   offset size field
//   0      1    type     0x24
//   1      2    width    u16 LE, pixels; 0 = hidden
//   3      2    height   u16 LE; zero exactly when width is zero
//   5      2    hotspotX u16 LE, < width when visible, 0 when hidden
//   7      2    hotspotY u16 LE, < height when visible, 0 when hidden
//   9      …    pixels   width*height*4 bytes, BGRA rows
//                        top-to-bottom (DRM ARGB8888 little-endian
//                        memory order), premultiplied alpha, tightly
//                        packed (no row padding — the host crops the
//                        plane's content box and repacks)
//
// Empty is a state: width == height == 0 with no pixel bytes means the
// cursor is hidden, and hiding must sync. Validation at encode AND decode:
// sides ≤ 256, image ≤ 65,536 bytes, pixel byte count exactly
// width*height*4, hotspot inside the image. Never traps on hostile bytes.
//
// Capability key 13 (`CapabilityKey.cursorShape`, bool) rides
// `Capabilities.unknownEntries` and survives intersection only on mutual
// declaration. A host that composites the cursor into the video never
// declares it.

/// The cursor-shape layer's fixed numbers (wire v1).
public enum CursorWire {
    /// DRM cursor planes cap at 256 per side
    /// (DRM_CAP_CURSOR_WIDTH/HEIGHT on every driver Lyte targets).
    public static let maxSide = 256
    /// The image ceiling, bytes (width*height*4): area ≤ 16,384 px. The
    /// host crops the plane to its content box; an over-ceiling crop is
    /// suppressed and counted, never sent.
    public static let maxImageByteCount = 65_536
    /// type ‖ width ‖ height ‖ hotspotX ‖ hotspotY.
    public static let headerByteCount = 9
}

// MARK: - The capability spine helper

extension Capabilities {
    /// True when this set carries `cursorShape: true` (key 13) — see
    /// `declaresFlag(_:)`.
    public var cursorShape: Bool {
        declaresFlag(CapabilityKey.cursorShape)
    }

    /// A copy of this set declaring `cursorShape`.
    public func declaringCursorShape() -> Capabilities {
        declaringFlag(CapabilityKey.cursorShape)
    }
}

// MARK: - The CTRL codec

/// The host's cursor-shape announcement (type 0x24).
public struct CursorShape: Hashable, Sendable {
    /// Pixels; 0 = hidden (then height, hotspots, and pixels are all
    /// zero/empty).
    public var width: UInt16
    public var height: UInt16
    /// The click point inside the image, < width when visible.
    public var hotspotX: UInt16
    public var hotspotY: UInt16
    /// width*height*4 bytes: BGRA rows top-to-bottom (DRM ARGB8888
    /// little-endian memory order), premultiplied alpha, no row
    /// padding.
    public var pixels: [UInt8]

    public init(
        width: UInt16, height: UInt16,
        hotspotX: UInt16, hotspotY: UInt16,
        pixels: [UInt8]
    ) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }

    /// The "cursor is hidden" value — the plane holds fb 0.
    public static let hidden = CursorShape(
        width: 0, height: 0, hotspotX: 0, hotspotY: 0, pixels: []
    )

    public var isHidden: Bool {
        width == 0 && height == 0
    }

    /// Throws when the value breaks the wire contract — an
    /// over-ceiling or malformed shape is the caller's
    /// suppress-and-count verdict, not wire input.
    public func encode() throws -> [UInt8] {
        try validate()
        var out: [UInt8] = [CtrlMessageType.cursorShape]
        out.reserveCapacity(CursorWire.headerByteCount + pixels.count)
        wireAppendLE(width, to: &out)
        wireAppendLE(height, to: &out)
        wireAppendLE(hotspotX, to: &out)
        wireAppendLE(hotspotY, to: &out)
        out.append(contentsOf: pixels)
        return out
    }

    /// Decodes a whole ARQ-delivered message (type byte first).
    /// Throws on the wrong type, truncation, dimension/hotspot/count
    /// violations, and over-ceiling images; never traps on hostile
    /// bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> CursorShape {
        guard let first = payload.first else {
            throw CursorMessageError.truncatedMessage
        }
        guard first == CtrlMessageType.cursorShape else {
            throw CursorMessageError.unexpectedType(first)
        }
        guard payload.count >= CursorWire.headerByteCount else {
            throw CursorMessageError.truncatedMessage
        }
        let base = payload.startIndex
        let shape = CursorShape(
            width: wireReadLE(payload, at: base + 1),
            height: wireReadLE(payload, at: base + 3),
            hotspotX: wireReadLE(payload, at: base + 5),
            hotspotY: wireReadLE(payload, at: base + 7),
            pixels: Array(payload.dropFirst(CursorWire.headerByteCount))
        )
        try shape.validate()
        return shape
    }

    public static func decode(_ payload: [UInt8]) throws -> CursorShape {
        try decode(payload[...])
    }

    /// The shared encode/decode contract.
    private func validate() throws {
        let w = Int(width), h = Int(height)
        // Zero is all-or-nothing: a lone zero side is malformed.
        guard (w == 0) == (h == 0),
              w <= CursorWire.maxSide, h <= CursorWire.maxSide else {
            throw CursorMessageError.invalidDimensions(
                width: w, height: h
            )
        }
        let imageByteCount = w * h * 4
        guard imageByteCount <= CursorWire.maxImageByteCount else {
            throw CursorMessageError.imageOverBudget(imageByteCount)
        }
        guard pixels.count == imageByteCount else {
            throw CursorMessageError.pixelCountMismatch(
                expected: imageByteCount, found: pixels.count
            )
        }
        if isHidden {
            guard hotspotX == 0, hotspotY == 0 else {
                throw CursorMessageError.hotspotOutsideImage(
                    x: Int(hotspotX), y: Int(hotspotY)
                )
            }
        } else {
            guard hotspotX < width, hotspotY < height else {
                throw CursorMessageError.hotspotOutsideImage(
                    x: Int(hotspotX), y: Int(hotspotY)
                )
            }
        }
    }
}

public enum CursorMessageError: Error, Equatable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    /// A lone zero side, or a side past 256.
    case invalidDimensions(width: Int, height: Int)
    /// width*height*4 past the 65,536 B ceiling.
    case imageOverBudget(Int)
    /// The pixel bytes don't match width*height*4 exactly.
    case pixelCountMismatch(expected: Int, found: Int)
    /// Hotspot at/past the image edge (or nonzero while hidden).
    case hotspotOutsideImage(x: Int, y: Int)
}
