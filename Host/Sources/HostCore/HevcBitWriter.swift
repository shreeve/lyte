// The E6b pen: an H.265 RBSP bit writer (§7.2's u(n)/ue(v)/se(v)
// descriptors) plus the NAL wrapper that adds the two-byte header and
// the emulation-prevention bytes (§7.4.2: no 00 00 0x with x ≤ 3 may
// appear inside a NAL). This is the machinery under
// HevcParameterSets — the serializer that retires libavcodec's
// header writing on the VAAPI path.

/// Accumulates bits MSB-first into bytes — the bitstream order every
/// H.26x syntax table assumes.
public struct HevcBitWriter: Sendable {
    private var bytes: [UInt8] = []
    /// Bits used in the trailing partial byte (0 = byte-aligned).
    private var bitCount = 0

    public init() {}

    /// u(n): `value`'s low `width` bits, MSB first.
    public mutating func u(_ value: UInt32, _ width: Int) {
        for shift in stride(from: width - 1, through: 0, by: -1) {
            let bit = (value >> UInt32(shift)) & 1
            if bitCount == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8(bit) << (7 - bitCount)
            bitCount = (bitCount + 1) & 7
        }
    }

    /// ue(v): Exp-Golomb — codeNum+1's bit length minus one leading
    /// zeros, then codeNum+1 itself.
    public mutating func ue(_ value: UInt32) {
        let codePlusOne = value &+ 1
        let length = 32 - codePlusOne.leadingZeroBitCount
        u(0, length - 1)
        u(codePlusOne, length)
    }

    /// se(v): signed Exp-Golomb — positive v maps to 2v−1, negative
    /// to −2v (§9.2's mapping, inverted).
    public mutating func se(_ value: Int32) {
        ue(value > 0 ? UInt32(value) * 2 - 1 : UInt32(-value) * 2)
    }

    /// rbsp_trailing_bits(): the stop bit, then zeros to alignment.
    public mutating func rbspTrailingBits() {
        u(1, 1)
        if bitCount != 0 { u(0, 8 - bitCount) }
    }

    /// The accumulated RBSP. Call after rbspTrailingBits — a partial
    /// trailing byte here is a serializer bug (padded as-is, loudly
    /// visible in any byte-diff).
    public var rbsp: [UInt8] { bytes }

    /// Wraps an RBSP as one NAL unit: forbidden_zero(1) ‖ type(6) ‖
    /// nuh_layer_id(6)=0 ‖ nuh_temporal_id_plus1(3)=1, then the RBSP
    /// with emulation-prevention 0x03 inserted wherever 00 00 0x
    /// (x ≤ 3) would otherwise appear.
    public static func nal(type: UInt8, rbsp: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [type << 1, 0x01]
        var zeroRun = 0
        for byte in rbsp {
            if zeroRun >= 2 && byte <= 0x03 {
                out.append(0x03)
                zeroRun = 0
            }
            out.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }
        return out
    }
}
