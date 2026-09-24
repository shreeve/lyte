// The one shared SHA-256 implementation. Streaming is the primitive so
// large file-transfer payloads never require a whole-file allocation;
// one-shot hashing is only a convenience over the same state machine.

/// FIPS 180-4 SHA-256, sans IO and byte-exact on every Swift platform.
///
/// Every input is borrowed contiguously and compressed by one non-generic
/// raw-pointer loop compiled inside LyteCore: no allocation per block, no
/// bounds-checked schedule, and callers in other modules never run an
/// unspecialized generic path. A non-contiguous collection is copied once.
public struct Sha256: Sendable {
    private var h0: UInt32 = 0x6A09_E667
    private var h1: UInt32 = 0xBB67_AE85
    private var h2: UInt32 = 0x3C6E_F372
    private var h3: UInt32 = 0xA54F_F53A
    private var h4: UInt32 = 0x510E_527F
    private var h5: UInt32 = 0x9B05_688C
    private var h6: UInt32 = 0x1F83_D9AB
    private var h7: UInt32 = 0x5BE0_CD19
    /// Bytes of an incomplete block, always fewer than 64 between calls.
    private var buffer: [UInt8] = []
    private var totalByteCount: UInt64 = 0

    private static let roundConstants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5,
        0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3,
        0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC,
        0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
        0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13,
        0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3,
        0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5,
        0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208,
        0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    public init() {}

    /// Feeds bytes without copying complete 64-byte blocks.
    @inlinable
    public mutating func update<Bytes: RandomAccessCollection>(
        _ bytes: Bytes
    ) where Bytes.Element == UInt8 {
        let borrowed: Void? = bytes.withContiguousStorageIfAvailable {
            update(raw: UnsafeRawBufferPointer($0))
        }
        if borrowed == nil {
            Array(bytes).withUnsafeBytes { update(raw: $0) }
        }
    }

    /// Pads and consumes this stream. Use a fresh instance for another blob.
    public mutating func finalized() -> [UInt8] {
        let bitLength = totalByteCount &* 8
        buffer.append(0x80)
        let padding = (64 + 56 - buffer.count % 64) % 64
        buffer.append(contentsOf: repeatElement(0, count: padding))
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        buffer.withUnsafeBytes { tail in
            compress(tail.baseAddress!, blocks: tail.count / 64)
        }
        buffer.removeAll(keepingCapacity: false)

        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            for shift in stride(from: 24, through: 0, by: -8) {
                digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return digest
    }

    @inlinable
    public static func digest<Bytes: RandomAccessCollection>(
        _ bytes: Bytes
    ) -> [UInt8] where Bytes.Element == UInt8 {
        var sha256 = Sha256()
        sha256.update(bytes)
        return sha256.finalized()
    }

    @usableFromInline
    mutating func update(raw bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        totalByteCount &+= UInt64(bytes.count)
        var offset = 0

        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: UnsafeRawBufferPointer(
                start: base, count: take))
            offset = take
            guard buffer.count == 64 else { return }
            buffer.withUnsafeBytes { block in
                compress(block.baseAddress!, blocks: 1)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        let blocks = (bytes.count - offset) / 64
        if blocks > 0 {
            compress(base + offset, blocks: blocks)
            offset += blocks * 64
        }
        if offset < bytes.count {
            buffer.append(contentsOf: UnsafeRawBufferPointer(
                start: base + offset, count: bytes.count - offset))
        }
    }

    /// Compresses `blocks` consecutive 64-byte blocks starting at `data`.
    /// The state lives in locals for the whole run and the message schedule
    /// in one stack allocation.
    private mutating func compress(_ data: UnsafeRawPointer, blocks: Int) {
        var (s0, s1, s2, s3, s4, s5, s6, s7) = (h0, h1, h2, h3, h4, h5, h6, h7)
        Self.roundConstants.withUnsafeBufferPointer { k in
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
                for block in 0..<blocks {
                    let p = data + block * 64
                    for t in 0..<16 {
                        w[t] = UInt32(bigEndian: p.loadUnaligned(
                            fromByteOffset: t * 4, as: UInt32.self))
                    }
                    for t in 16..<64 {
                        let x = w[t - 15], y = w[t - 2]
                        let sigma0 = x.rotatedRight(7) ^ x.rotatedRight(18) ^ (x >> 3)
                        let sigma1 = y.rotatedRight(17) ^ y.rotatedRight(19) ^ (y >> 10)
                        w[t] = w[t - 16] &+ sigma0 &+ w[t - 7] &+ sigma1
                    }
                    var (a, b, c, d, e, f, g, h) = (s0, s1, s2, s3, s4, s5, s6, s7)
                    for t in 0..<64 {
                        let sum1 = e.rotatedRight(6) ^ e.rotatedRight(11)
                            ^ e.rotatedRight(25)
                        let choice = (e & f) ^ (~e & g)
                        let t1 = h &+ sum1 &+ choice &+ k[t] &+ w[t]
                        let sum0 = a.rotatedRight(2) ^ a.rotatedRight(13)
                            ^ a.rotatedRight(22)
                        let majority = (a & b) ^ (a & c) ^ (b & c)
                        (h, g, f, e, d, c, b, a) = (
                            g, f, e, d &+ t1, c, b, a, t1 &+ sum0 &+ majority)
                    }
                    s0 &+= a; s1 &+= b; s2 &+= c; s3 &+= d
                    s4 &+= e; s5 &+= f; s6 &+= g; s7 &+= h
                }
            }
        }
        (h0, h1, h2, h3, h4, h5, h6, h7) = (s0, s1, s2, s3, s4, s5, s6, s7)
    }
}

private extension UInt32 {
    @inline(__always)
    func rotatedRight(_ amount: UInt32) -> UInt32 {
        (self >> amount) | (self << (32 - amount))
    }
}
