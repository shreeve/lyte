// The one shared SHA-256 implementation. Streaming is the primitive so
// large file-transfer payloads never require a whole-file allocation;
// one-shot hashing is only a convenience over the same state machine.

/// FIPS 180-4 SHA-256, sans IO and byte-exact on every Swift platform.
public struct Sha256: Sendable {
    private var state: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
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
    public mutating func update<Bytes: RandomAccessCollection>(
        _ bytes: Bytes
    ) where Bytes.Element == UInt8 {
        totalByteCount &+= UInt64(bytes.count)
        var index = bytes.startIndex

        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            let end = bytes.index(index, offsetBy: take)
            buffer.append(contentsOf: bytes[index..<end])
            index = end
            guard buffer.count == 64 else { return }
            compress(buffer[...])
            buffer.removeAll(keepingCapacity: true)
        }

        while bytes.distance(from: index, to: bytes.endIndex) >= 64 {
            let end = bytes.index(index, offsetBy: 64)
            compress(bytes[index..<end])
            index = end
        }
        buffer.append(contentsOf: bytes[index..<bytes.endIndex])
    }

    /// Pads and consumes this stream. Use a fresh instance for another blob.
    public mutating func finalized() -> [UInt8] {
        let bitLength = totalByteCount &* 8
        var tail: [UInt8] = [0x80]
        while (buffer.count + tail.count) % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        buffer.append(contentsOf: tail)
        for start in stride(from: 0, to: buffer.count, by: 64) {
            compress(buffer[start..<start + 64])
        }
        buffer.removeAll(keepingCapacity: false)

        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in state {
            for shift in stride(from: 24, through: 0, by: -8) {
                digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return digest
    }

    public static func digest<Bytes: RandomAccessCollection>(
        _ bytes: Bytes
    ) -> [UInt8] where Bytes.Element == UInt8 {
        var sha256 = Sha256()
        sha256.update(bytes)
        return sha256.finalized()
    }

    private mutating func compress<Bytes: RandomAccessCollection>(
        _ block: Bytes
    ) where Bytes.Element == UInt8 {
        precondition(block.count == 64)
        var words = [UInt32](repeating: 0, count: 64)
        var index = block.startIndex
        for round in 0..<16 {
            let b0 = UInt32(block[index])
            index = block.index(after: index)
            let b1 = UInt32(block[index])
            index = block.index(after: index)
            let b2 = UInt32(block[index])
            index = block.index(after: index)
            let b3 = UInt32(block[index])
            index = block.index(after: index)
            words[round] = b0 << 24 | b1 << 16 | b2 << 8 | b3
        }
        for round in 16..<64 {
            let s0 = rotateRight(words[round - 15], 7)
                ^ rotateRight(words[round - 15], 18)
                ^ (words[round - 15] >> 3)
            let s1 = rotateRight(words[round - 2], 17)
                ^ rotateRight(words[round - 2], 19)
                ^ (words[round - 2] >> 10)
            words[round] = words[round - 16] &+ s0
                &+ words[round - 7] &+ s1
        }

        var (a, b, c, d, e, f, g, h) = (
            state[0], state[1], state[2], state[3],
            state[4], state[5], state[6], state[7]
        )
        for round in 0..<64 {
            let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11)
                ^ rotateRight(e, 25)
            let choice = (e & f) ^ (~e & g)
            let temporary1 = h &+ sum1 &+ choice
                &+ Self.roundConstants[round] &+ words[round]
            let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13)
                ^ rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = sum0 &+ majority
            (h, g, f, e, d, c, b, a) = (
                g, f, e, d &+ temporary1, c, b, a,
                temporary1 &+ temporary2
            )
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
