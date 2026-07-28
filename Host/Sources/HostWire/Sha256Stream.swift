// Streaming SHA-256 for the bulk receive shell (F-3): the completion
// contract is a digest of the ASSEMBLED blob (design record
// 20260728-053300 §5), and a 100 MB staging file deserves a streaming
// hash, not a whole-file allocation. Implemented here rather than
// imported — the TestKit precedent verbatim: CryptoKit is Apple-only,
// swift-crypto is a dependency HostWire does not otherwise need
// (Wire's is lint-confined to its Crypto/), and the digest must match
// byte-exactly on macOS and Linux. FIPS 180-4, pinned in
// BulkReceiveGateTests against the published empty-string/"abc"
// digests AND cross-checked against TestKit's one-shot Sha256, so the
// implementation never grades its own homework.

public struct Sha256Stream: Sendable {
    private var h: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    /// A partial block awaiting its remainder (always < 64 bytes).
    private var buffer: [UInt8] = []
    private var totalByteCount: UInt64 = 0

    private static let k: [UInt32] = [
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

    public mutating func update(_ bytes: ArraySlice<UInt8>) {
        totalByteCount &+= UInt64(bytes.count)
        var input = bytes
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, input.count)
            buffer.append(contentsOf: input.prefix(take))
            input = input.dropFirst(take)
            guard buffer.count == 64 else { return }
            compress(buffer[...])
            buffer.removeAll(keepingCapacity: true)
        }
        while input.count >= 64 {
            compress(input.prefix(64))
            input = input.dropFirst(64)
        }
        buffer.append(contentsOf: input)
    }

    public mutating func update(_ bytes: [UInt8]) {
        update(bytes[...])
    }

    /// Pads and produces the digest. The stream is consumed: feed a
    /// fresh instance for the next blob.
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
        buffer = []
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in h {
            for shift in stride(from: 24, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return out
    }

    /// One-shot convenience (small inputs; the shell streams).
    public static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var stream = Sha256Stream()
        stream.update(bytes[...])
        return stream.finalized()
    }

    /// One 64-byte block into the state.
    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for t in 0..<16 {
            let i = base + t * 4
            w[t] = UInt32(block[i]) << 24 | UInt32(block[i + 1]) << 16
                | UInt32(block[i + 2]) << 8 | UInt32(block[i + 3])
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
        for t in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = hh &+ s1 &+ ch &+ Self.k[t] &+ w[t]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            (hh, g, f, e, d, c, b, a) =
                (g, f, e, d &+ temp1, c, b, a, temp1 &+ temp2)
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    private func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
