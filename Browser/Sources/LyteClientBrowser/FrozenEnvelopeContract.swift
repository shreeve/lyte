import LyteCore
import LyteWire

/// Exercises the frozen envelope vector `nominal-video-shard` from
/// `Wire/Vectors/envelope-v1.json` (byte-identical to the hand-computed
/// anchor in `EnvelopeTests`). Decode → field check → re-encode → hex
/// compare. This is the datagram framing contract every Lyte channel rides.
enum FrozenEnvelopeContract {
    static let vectorName = "envelope-v1/nominal-video-shard"

    /// Committed datagram hex from envelope-v1.json.
    static let datagramHex =
        "020034120d0c0b0a080706050403020188776655443322116c797465"

    static let expected = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 0x1234),
        frame: FrameNumber(rawValue: 0x0A0B_0C0D),
        timestamp: 0x0102_0304_0506_0708,
        fec: 0x1122_3344_5566_7788
    )

    static let expectedPayload = Array("lyte".utf8)

    static func verify() -> ContractResult {
        guard let datagram = Hex.bytes(datagramHex) else {
            return ContractResult(
                name: vectorName,
                passed: false,
                detail: "malformed committed hex"
            )
        }
        do {
            let (envelope, payload) = try Envelope.decode(datagram)
            guard envelope == expected else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "decoded fields diverged from the frozen vector"
                )
            }
            guard Array(payload) == expectedPayload else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "payload diverged from the frozen vector"
                )
            }
            let reencoded = try envelope.encode(payload: Array(payload))
            let reencodedHex = Hex.string(reencoded)
            guard reencodedHex == datagramHex else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "re-encode hex mismatch: \(reencodedHex)"
                )
            }
            return ContractResult(
                name: vectorName,
                passed: true,
                detail: "decode + re-encode matched \(datagram.count) B datagram"
            )
        } catch {
            return ContractResult(
                name: vectorName,
                passed: false,
                detail: "codec threw: \(error)"
            )
        }
    }
}
