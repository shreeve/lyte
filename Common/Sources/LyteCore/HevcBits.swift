// Shared H.265 bit vocabulary: MSB-first fixed-width fields, unsigned and
// signed Exp-Golomb codes, RBSP trailing bits, and the inverse emulation-
// prevention transform. Pure Swift and sans-IO.

public enum HevcRbsp {
    /// Inserts emulation-prevention bytes so no `00 00 00...03` sequence
    /// can be mistaken for an Annex-B start code inside a NAL payload.
    public static func escaped(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeroRun = 0
        for byte in bytes {
            if zeroRun >= 2, byte <= 0x03 {
                output.append(0x03)
                zeroRun = 0
            }
            output.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }
        return output
    }

    /// Removes emulation-prevention bytes: a 0x03 after two zeros that is
    /// followed by a byte <= 0x03. This is narrower than H.265 §7.3.1.1,
    /// which drops the 0x03 of every 0x000003; the two agree on every
    /// conforming RBSP whose last byte is non-zero (every parameter set and
    /// slice header this module parses), since an encoder only inserts the
    /// byte before 0x00...0x03 or at the end.
    public static func unescaped(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeroRun = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if zeroRun >= 2,
               byte == 0x03,
               index + 1 < bytes.count,
               bytes[index + 1] <= 0x03 {
                zeroRun = 0
                index += 1
                continue
            }
            output.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
            index += 1
        }
        return output
    }
}

/// Accumulates H.265 syntax bits MSB-first.
public struct HevcBitWriter: Sendable {
    private var bytes: [UInt8] = []
    private var bitCount = 0

    public init() {}

    /// u(n): writes `value`'s low `width` bits, MSB first.
    public mutating func u(_ value: UInt32, _ width: Int) {
        guard width > 0 else { return }
        for shift in stride(from: width - 1, through: 0, by: -1) {
            let bit = (value >> UInt32(shift)) & 1
            if bitCount == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8(bit) << (7 - bitCount)
            bitCount = (bitCount + 1) & 7
        }
    }

    /// ue(v) for 0 ... 2^32 − 2, the range HevcBitReader.readUe decodes.
    public mutating func ue(_ value: UInt32) {
        precondition(value < UInt32.max, "ue(v) is limited to 32-bit codes")
        let codePlusOne = value + 1
        let length = 32 - codePlusOne.leadingZeroBitCount
        u(0, length - 1)
        u(codePlusOne, length)
    }

    /// se(v) for −(2^31 − 1) ... 2^31 − 1; Int32.min has no 32-bit code.
    public mutating func se(_ value: Int32) {
        precondition(value != .min, "se(v) is limited to 32-bit codes")
        let magnitude = UInt32(value.magnitude)
        ue(value > 0 ? magnitude * 2 - 1 : magnitude * 2)
    }

    public mutating func rbspTrailingBits() {
        u(1, 1)
        if bitCount != 0 { u(0, 8 - bitCount) }
    }

    public var rbsp: [UInt8] { bytes }

    public static func nal(type: UInt8, rbsp: [UInt8]) -> [UInt8] {
        [type << 1, 0x01] + HevcRbsp.escaped(rbsp)
    }
}

/// Bounds-checked MSB-first reader. Hostile or truncated input returns nil
/// or false and never indexes beyond the supplied RBSP.
public struct HevcBitReader: Sendable {
    private let bytes: [UInt8]
    private var bitIndex = 0

    public init(rbsp: [UInt8]) {
        self.bytes = rbsp
    }

    public init(nal: [UInt8]) {
        self.bytes = HevcRbsp.unescaped(Array(nal.dropFirst(2)))
    }

    private var bitsRemaining: Int { bytes.count * 8 - bitIndex }

    public mutating func read(bits count: Int) -> UInt32? {
        guard count >= 0, count <= 32, bitsRemaining >= count else {
            return nil
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[bitIndex >> 3]
            let bit = (byte >> (7 - UInt8(bitIndex & 7))) & 1
            value = (value << 1) | UInt32(bit)
            bitIndex += 1
        }
        return value
    }

    public mutating func skip(bits count: Int) -> Bool {
        guard count >= 0, bitsRemaining >= count else { return false }
        bitIndex += count
        return true
    }

    public mutating func readUe() -> UInt32? {
        var leadingZeros = 0
        while true {
            guard let bit = read(bits: 1) else { return nil }
            if bit == 1 { break }
            leadingZeros += 1
            guard leadingZeros <= 31 else { return nil }
        }
        guard leadingZeros > 0 else { return 0 }
        guard let suffix = read(bits: leadingZeros) else { return nil }
        return (1 << UInt32(leadingZeros)) - 1 + suffix
    }

    public mutating func readSe() -> Int32? {
        guard let code = readUe() else { return nil }
        let magnitude = Int32((code + 1) >> 1)
        return code & 1 == 0 ? -magnitude : magnitude
    }
}
