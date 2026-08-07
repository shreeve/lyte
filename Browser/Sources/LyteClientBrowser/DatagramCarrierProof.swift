import LyteCore
import LyteWire

/// WASM-side checks for B-2 opaque carrier echoes. The browser JavaScript
/// owns WebTransport; this verifies that bytes which crossed the sidecar
/// are still the Lyte envelopes / sealed ciphertext the page claimed to send.
enum DatagramCarrierProof {
    static let wireBudgetBytes = WireBudget.maxDatagramByteCount

    /// Published Noise IK message-1 ciphertext from the frozen snow vector —
    /// sealed bytes the sidecar must treat as opaque.
    static var noiseMsg1CiphertextHex: String {
        FrozenNoiseContract.msg1CiphertextHex
    }

    static func verifyEcho(kind: String, sentHex: String, recvHex: String) -> ContractResult {
        let name: String
        switch kind {
        case "envelope":
            name = "wt-carrier/envelope-echo"
        case "noise-msg1":
            name = "wt-carrier/noise-msg1-echo"
        default:
            name = "wt-carrier/\(kind)"
        }

        let sent = sentHex.filter { !$0.isWhitespace }.lowercased()
        let recv = recvHex.filter { !$0.isWhitespace }.lowercased()
        guard !sent.isEmpty else {
            return ContractResult(name: name, passed: false, detail: "empty sent hex")
        }
        guard sent == recv else {
            return ContractResult(
                name: name,
                passed: false,
                detail: "echo diverged (sent \(sent.count / 2) B, recv \(recv.count / 2) B)"
            )
        }
        guard let bytes = Hex.bytes(sent) else {
            return ContractResult(name: name, passed: false, detail: "malformed hex")
        }

        switch kind {
        case "envelope":
            do {
                let (envelope, payload) = try Envelope.decode(bytes)
                let reencoded = try envelope.encode(payload: Array(payload))
                guard Hex.string(reencoded) == sent else {
                    return ContractResult(
                        name: name,
                        passed: false,
                        detail: "echo matched but envelope re-encode diverged"
                    )
                }
                return ContractResult(
                    name: name,
                    passed: true,
                    detail: "opaque envelope \(bytes.count) B survived WT↔UDP (chan=\(envelope.channel.rawValue))"
                )
            } catch {
                return ContractResult(
                    name: name,
                    passed: false,
                    detail: "echo matched but Envelope.decode failed: \(error)"
                )
            }
        case "noise-msg1":
            guard sent == FrozenNoiseContract.msg1CiphertextHex else {
                return ContractResult(
                    name: name,
                    passed: false,
                    detail: "bytes are not the frozen IK message-1 ciphertext"
                )
            }
            return ContractResult(
                name: name,
                passed: true,
                detail: "opaque Noise IK msg1 ciphertext \(bytes.count) B survived WT↔UDP"
            )
        default:
            return ContractResult(
                name: name,
                passed: true,
                detail: "opaque \(bytes.count) B echo matched"
            )
        }
    }
}
