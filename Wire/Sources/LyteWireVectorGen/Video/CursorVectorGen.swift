// Authors Vectors/cursor-v1.json: the cursor-shape CTRL message (0x24)
// and the key-13 capability spine. Roundtrip bytes come from the codecs;
// reject bytes are hand-built.

import LyteCore
import LyteWire
import LyteWireTestKit

/// `count` copies of one BGRA pixel.
private func pixels(_ bgra: [UInt8], count: Int) -> [UInt8] {
    Array([[UInt8]](repeating: bgra, count: count).joined())
}

private let tealish: [UInt8] = [0x10, 0x20, 0x30, 0xFF]

public func makeCursorVectorFile() throws -> CursorVectorFile {
    var vectors: [CursorVector] = []

    func shape(
        _ name: String, _ description: String,
        width: Int, height: Int, hotspotX: Int, hotspotY: Int,
        pixels: [UInt8]
    ) throws {
        let shape = CursorShape(
            width: UInt16(width), height: UInt16(height),
            hotspotX: UInt16(hotspotX), hotspotY: UInt16(hotspotY),
            pixels: pixels
        )
        vectors.append(CursorVector(
            name: name, description: description,
            kind: .roundtrip, codec: .cursorShape,
            messageHex: Hex.string(try shape.encode()),
            width: width, height: height,
            hotspotX: hotspotX, hotspotY: hotspotY,
            pixelsHex: Hex.string(pixels)
        ))
    }

    func reject(_ name: String, _ description: String, _ hex: String, _ error: String) {
        vectors.append(CursorVector(
            name: name, description: description,
            kind: .decodeReject, codec: .cursorShape,
            messageHex: hex, error: error
        ))
    }

    func capabilities(
        _ name: String, _ description: String, _ set: Capabilities
    ) throws {
        vectors.append(CursorVector(
            name: name, description: description,
            kind: .roundtrip, codec: .capabilitySet,
            messageHex: Hex.string(try set.encodeCbor()),
            cursorShape: set.cursorShape
        ))
    }

    try shape(
        "shape-1x1-minimal",
        "The smallest visible cursor: 1×1, hotspot (0,0), one opaque blue BGRA pixel (FF 00 00 FF) — the hand-computed anchor: 24 ‖ 0100 ‖ 0100 ‖ 0000 ‖ 0000 ‖ ff0000ff.",
        width: 1, height: 1, hotspotX: 0, hotspotY: 0,
        pixels: [0xFF, 0x00, 0x00, 0xFF]
    )
    try shape(
        "shape-2x2-nominal",
        "2×2 with hotspot (1,1) — the last legal hotspot corner — and four distinct BGRA pixels, pinning row order (top row first) and the LE u16 fields.",
        width: 2, height: 2, hotspotX: 1, hotspotY: 1,
        pixels: [0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
                     0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF]
    )
    try shape(
        "shape-4x2-asymmetric",
        "width ≠ height (4×2, hotspot (3,0)) — a transposed decode cannot pass; the LE width/height fields land in the right slots.",
        width: 4, height: 2, hotspotX: 3, hotspotY: 0,
        pixels: pixels(tealish, count: 8)
    )
    try shape(
        "hidden",
        "The hidden state: all four u16 fields zero, no pixel bytes — nine bytes total, and unlike clipboard EMPTY IS A STATE (the cursor plane holds fb 0).",
        width: 0, height: 0, hotspotX: 0, hotspotY: 0,
        pixels: []
    )
    try shape(
        "shape-side-cap-256x1",
        "The 256 side cap exactly, legal: 256×1 (a maximal beam), hotspot (255,0) — the last legal hotspot on the cap side.",
        width: 256, height: 1, hotspotX: 255, hotspotY: 0,
        pixels: pixels(tealish, count: 256)
    )
    try shape(
        "shape-max-budget-128x128",
        "The exact image ceiling as legal bytes: 128×128 = 65,536 BGRA bytes (area 16,384 px), hotspot (64,64).",
        width: 128, height: 128, hotspotX: 64, hotspotY: 64,
        pixels: pixels(tealish, count: 128 * 128)
    )
    reject(
        "empty-payload",
        "No bytes at all.",
        "", "truncatedMessage"
    )
    reject(
        "truncated-header",
        "Type byte plus half a header (5 of 9 bytes).",
        "2401000100", "truncatedMessage"
    )
    reject(
        "foreign-type",
        "A repair-refusal type byte (0x23) wearing a cursor header.",
        "230000000000000000", "unexpectedType"
    )
    reject(
        "lone-zero-side",
        "width 0 with height 2 — zero is all-or-nothing.",
        "240000020000000000", "invalidDimensions"
    )
    reject(
        "side-over-cap",
        "width 257 (0101 LE) — one past the DRM cursor cap.",
        "240101010000000000", "invalidDimensions"
    )
    reject(
        "image-over-budget",
        "256×256 = 262,144 B — dims legal per side, area past the 65,536 B ceiling (judged before the count, so no pixel bytes are needed to pin it).",
        "240001000100000000", "imageOverBudget"
    )
    reject(
        "pixel-count-short",
        "1×1 claiming 4 bytes, carrying 3.",
        "240100010000000000ff0000", "pixelCountMismatch"
    )
    reject(
        "pixel-count-long",
        "1×1 claiming 4 bytes, carrying 5.",
        "240100010000000000ff0000ff00", "pixelCountMismatch"
    )
    reject(
        "hotspot-at-edge",
        "2×2 with hotspot (2,0) — the hotspot must be strictly inside the image.",
        "240200020002000000102030ff102030ff102030ff102030ff", "hotspotOutsideImage"
    )
    reject(
        "hidden-nonzero-hotspot",
        "Hidden (0×0) with hotspot (1,0) — a hidden cursor has no image to click in.",
        "240000000001000000", "hotspotOutsideImage"
    )
    try capabilities(
        "capability-key13-declared",
        "wireDefault's frozen encoding plus exactly the appended `0D F5` entry (map head 0xA8 → 0xA9): the cursorShape accessor must read true and the set must re-encode byte-exactly — the \"no frozen bytes moved\" claim as data.",
        .wireDefault.declaringCursorShape()
    )
    try capabilities(
        "capability-key13-absent",
        "wireDefault's frozen encoding unchanged: absence reads false — \"not supported\", never an error.",
        .wireDefault
    )
    try capabilities(
        "capability-key10-and-key13",
        "Clipboard and cursor spine keys together: map head 0xAA with `0A F5 0D F5` trailing in canonical order — the two features compose without moving each other's bytes.",
        .wireDefault.declaringClipboardText().declaringCursorShape()
    )

    return CursorVectorFile(vectors: vectors)
}
