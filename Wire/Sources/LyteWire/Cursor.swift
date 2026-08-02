// Cursor-shape sync (E3, the direct-eye plan §5 obligation —
// docs/20260801-105800-direct-eye-plan.md): without Mutter's screen-cast
// stream there is no composited cursor in the video, and that is a
// FEATURE — the client's local cursor gives zero-latency positioning
// (input is absolute from the Mac). What the direct eye loses is the
// SHAPE: the hardware cursor plane's image never touches the encoded
// frames. This message carries it as metadata — the host watches the
// cursor plane and announces each shape change; the client wears it
// as the local NSCursor over the video view.
//
// CursorShape (0x24), host→client only: "the host cursor now looks
// like this" (or "is hidden"). Rides the ARQ ordered CTRL stream
// (group 0) like clipboard — a reordered shape swap would leave the
// client wearing yesterday's cursor, so ordering is the contract and
// the last delivered shape wins. Layout (LE, the W4a convention):
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
// Unlike clipboard, EMPTY IS A STATE: width == height == 0 with no
// pixel bytes means the cursor is hidden (the plane holds fb 0), and
// hiding must sync. Validation at encode AND decode: sides ≤ 256
// (DRM_CAP_CURSOR_WIDTH/HEIGHT's ceiling), image ≤ 65,536 bytes (the
// clipboard precedent for the shared ordered stream — area ≤ 16,384
// px, so 128×128 square or any equal-area crop), pixel byte count
// exactly width*height*4, hotspot inside the image. Truncation and
// foreign type bytes reject with what they found. Never traps on
// hostile bytes.
//
// CAPABILITY CARRIAGE — the W7 forward-compat spine, keys 9–12
// repeated: key 13 (CapabilityKey.cursorShape, bool) rides the
// declaration through `Capabilities.unknownEntries` as one canonical
// `0D F5` map entry and survives intersection only on mutual
// byte-equal declaration. ZERO frozen bytes move. Declaration is
// dialect, not policy: a host whose capture organ composites the
// cursor into the video (the portal-era backends) truthfully never
// declares it.

/// The cursor-shape layer's fixed numbers (wire v1).
public enum CursorWire {
    /// DRM cursor planes cap at 256 per side
    /// (DRM_CAP_CURSOR_WIDTH/HEIGHT on every driver Lyte targets).
    public static let maxSide = 256
    /// The image ceiling, bytes (width*height*4). The clipboard
    /// precedent sizes it: 65,536 B on the shared ordered stream —
    /// area ≤ 16,384 px. The host crops the plane to its content box
    /// (real cursor themes are ≤ 96 px of content inside a padded
    /// buffer), so an over-ceiling crop is a suppress-and-count
    /// weather event, never a send.
    public static let maxImageByteCount = 65_536
    /// type ‖ width ‖ height ‖ hotspotX ‖ hotspotY.
    public static let headerByteCount = 9
}

// MARK: - The capability spine helper

extension Capabilities {
    /// The key-13 entry as it rides the wire: CBOR bool under
    /// unsigned key 13 (`0D F5` inside the map) — one canonical byte
    /// image is what makes the intersection's byte-equal rule an
    /// exact AND.
    private static var cursorShapeEntry: CborMapEntry {
        CborMapEntry(
            key: .unsigned(CapabilityKey.cursorShape),
            value: .bool(true)
        )
    }

    /// True when this set (a declaration or an agreed intersection)
    /// carries `cursorShape: true`. On a v1 build the key lives in
    /// `unknownEntries` — which is exactly what makes it survive
    /// intersection only on mutual declaration. A `false` or
    /// wrongly-typed value reads as absent: absence and refusal are
    /// the same posture ("not supported"), per the spine's rule 3.
    public var cursorShape: Bool {
        unknownEntries.contains(Self.cursorShapeEntry)
    }

    /// A copy of this set declaring cursor-shape support.
    /// Idempotent; the CBOR encoder owns canonical key order, so the
    /// entry may append here regardless of surrounding keys.
    public func declaringCursorShape() -> Capabilities {
        guard !cursorShape else { return self }
        var declared = self
        declared.unknownEntries.append(Self.cursorShapeEntry)
        return declared
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
        // Zero is all-or-nothing: a 0×N image has no pixels to carry
        // a hotspot in, and a lone zero side is a zero-fill-adjacent
        // bug to surface.
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
