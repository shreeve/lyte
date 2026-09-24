// Little-endian primitives and the bounds-checked reader every codec
// shares. Wire bytes are pinned by the frozen vectors, not by which
// helper writes them, so codecs use these rather than private copies.

@inline(__always)
func wireAppendLE(_ value: UInt16, to out: inout [UInt8]) {
    out.append(UInt8(truncatingIfNeeded: value))
    out.append(UInt8(truncatingIfNeeded: value >> 8))
}

@inline(__always)
func wireAppendLE(_ value: UInt32, to out: inout [UInt8]) {
    for shift in stride(from: 0, to: 32, by: 8) {
        out.append(UInt8(truncatingIfNeeded: value >> shift))
    }
}

@inline(__always)
func wireAppendLE(_ value: UInt64, to out: inout [UInt8]) {
    for shift in stride(from: 0, to: 64, by: 8) {
        out.append(UInt8(truncatingIfNeeded: value >> shift))
    }
}

/// Appends the low 24 bits, little-endian (the u24 convention the fec
/// field's groupByteCount established).
@inline(__always)
func wireAppendLE24(_ value: UInt32, to out: inout [UInt8]) {
    out.append(UInt8(truncatingIfNeeded: value))
    out.append(UInt8(truncatingIfNeeded: value >> 8))
    out.append(UInt8(truncatingIfNeeded: value >> 16))
}

/// Reads a little-endian integer at an absolute slice index. The caller
/// has already checked `index + T.bitWidth / 8 <= bytes.endIndex`.
@inline(__always)
func wireReadLE<T: FixedWidthInteger & UnsignedInteger>(
    _ bytes: ArraySlice<UInt8>, at index: Int
) -> T {
    var value: T = 0
    for i in 0..<(T.bitWidth / 8) {
        value |= T(bytes[index + i]) << (8 * i)
    }
    return value
}

@inline(__always)
func wireReadLE24(_ bytes: ArraySlice<UInt8>, at index: Int) -> UInt32 {
    UInt32(bytes[index])
        | UInt32(bytes[index + 1]) << 8
        | UInt32(bytes[index + 2]) << 16
}

/// A forward cursor over received bytes in which every read is bounds-
/// checked: it returns the field or throws the codec's own truncation
/// error, so a decoder built on it cannot index past its input.
struct WireReader {
    private(set) var remaining: ArraySlice<UInt8>
    private let truncated: any Error

    /// `truncated` is what every short read throws.
    init(_ bytes: ArraySlice<UInt8>, truncated: any Error) {
        remaining = bytes
        self.truncated = truncated
    }

    var isAtEnd: Bool { remaining.isEmpty }

    mutating func u8() throws -> UInt8 {
        guard let byte = remaining.first else { throw truncated }
        remaining = remaining.dropFirst()
        return byte
    }

    mutating func u16() throws -> UInt16 { try littleEndian() }
    mutating func u32() throws -> UInt32 { try littleEndian() }
    mutating func u64() throws -> UInt64 { try littleEndian() }

    /// The next `count` bytes, as a slice of the input.
    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining.count else { throw truncated }
        let field = remaining.prefix(count)
        remaining = remaining.dropFirst(count)
        return field
    }

    /// Everything not yet read.
    mutating func rest() -> ArraySlice<UInt8> {
        defer { remaining = remaining.suffix(0) }
        return remaining
    }

    private mutating func littleEndian<T: FixedWidthInteger & UnsignedInteger>(
    ) throws -> T {
        let width = T.bitWidth / 8
        guard remaining.count >= width else { throw truncated }
        let value: T = wireReadLE(remaining, at: remaining.startIndex)
        remaining = remaining.dropFirst(width)
        return value
    }
}

extension WireExtension {
    /// The value of the one extension of `type`: nil when absent,
    /// `duplicate` thrown when it appears more than once (reserved TLVs
    /// are single-valued; a repeat is a peer bug to surface).
    static func uniqueValue(
        ofType type: UInt8, in extensions: [WireExtension],
        duplicate: @autoclosure () -> any Error
    ) throws -> [UInt8]? {
        var found: [UInt8]?
        for ext in extensions where ext.type == type {
            guard found == nil else { throw duplicate() }
            found = ext.value
        }
        return found
    }
}
