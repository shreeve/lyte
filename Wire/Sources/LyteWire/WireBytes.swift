// Little-endian primitives shared by the W4a codecs (ClockBeacon,
// FeedbackReport). Envelope keeps its own private copies from W0 —
// deliberately untouched, its bytes are frozen contract.

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
