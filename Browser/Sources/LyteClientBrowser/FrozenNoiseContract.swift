import LyteCore
import LyteWire

/// Exercises the published Noise IK vector
/// `snow-ik-25519-chachapoly-sha256` from `Wire/Vectors/noise-v1.json`.
/// Fixed ephemerals produce byte-exact handshake messages — the same
/// bytes the wasmtime Wire suite and native platforms already gate.
enum FrozenNoiseContract {
    static let vectorName = "noise-v1/snow-ik-25519-chachapoly-sha256"

    /// Committed IK message-1 ciphertext hex from noise-v1.json — reused as
    /// an opaque sealed payload for the B-2 WebTransport carrier proof.
    static let msg1CiphertextHex =
        "6d21fec9141f3f37cc464e936a48b2d9521b5a44e0f3d960895d3c3fba30282f731f445c25e898e2534ac0536715b24308c108fc46bd260c887b36c3f68e3a05654fc8295c068ed53fb2022560961224e0b10b0835e1efc82fc587cd50f7178fe3d9eb06e0351c6e7334162c10bed670bfa2a105f7b2768a140b3fd597782601"

    static func verify() -> ContractResult {
        do {
            let initStatic = try key(
                "f49f93c5112c0787acc808d61716d7e090e076a58f15a3f78d92773f8dcb473b",
                "init static"
            )
            let initEphemeral = try key(
                "dae68498c41315cff7e4a34dded8d973199d8f0cf3fcb8b6651c169de77de8be",
                "init ephemeral"
            )
            let initRemoteStatic = try bytes(
                "2ea5942829bac414e25aa4cbb1bcc43394816ebb1bd12550d7d0eb4415e42951",
                "init remote static"
            )
            let respStatic = try key(
                "b790546f98b1e933c48cd01f17e7b281469d46fcacc9a3b584ae65b1d6272e8e",
                "resp static"
            )
            let respEphemeral = try key(
                "c0875a5b59c8492bd2135e5432d7d484f938e0a1f5009428c4bcb70b2f69f69f",
                "resp ephemeral"
            )
            let prologue = try bytes(
                "5468657265206973206e6f20726967687420616e642077726f6e672e2054686572652773206f6e6c792066756e20616e6420626f72696e672e",
                "prologue"
            )
            let msg1Payload = try bytes(
                "95a8f51c435a9530ff1f30868ed7b23ec952eb513c26a0774fed82d2978a8c81",
                "msg1 payload"
            )
            let msg1Ciphertext = try bytes(msg1CiphertextHex, "msg1 ciphertext")
            let msg2Payload = try bytes(
                "b866b807a6d8b83182b884dbfedc861843c5082bd6e480cb54e4245a72083041",
                "msg2 payload"
            )
            let msg2Ciphertext = try bytes(
                "e64e1fb8701c4f4bc3850b255fea657d4d835338b059c89acc99628fbe52473b41a4e79e3c1e6abc46bf80f078a005e15d8a3e04f989af3e6cb99b52031165006163ac3e17b928af8c116009d7bf4fb2",
                "msg2 ciphertext"
            )

            var initiator = try NoiseHandshake(
                role: .initiator,
                staticKeys: initStatic,
                remoteStaticPublicKey: initRemoteStatic,
                prologue: prologue,
                fixedEphemeral: initEphemeral
            )
            var responder = try NoiseHandshake(
                role: .responder,
                staticKeys: respStatic,
                prologue: prologue,
                fixedEphemeral: respEphemeral
            )

            let written1 = try initiator.writeMessage1(payload: msg1Payload[...])
            guard written1 == msg1Ciphertext else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "message 1 bytes diverged from the published vector"
                )
            }
            let read1 = try responder.readMessage1(msg1Ciphertext[...])
            guard read1 == msg1Payload else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "responder recovered the wrong message-1 payload"
                )
            }
            guard responder.remoteStaticPublicKey == initStatic.publicKey else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "responder did not learn the initiator static"
                )
            }

            let written2 = try responder.writeMessage2(payload: msg2Payload[...])
            guard written2 == msg2Ciphertext else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "message 2 bytes diverged from the published vector"
                )
            }
            let read2 = try initiator.readMessage2(msg2Ciphertext[...])
            guard read2 == msg2Payload else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "initiator recovered the wrong message-2 payload"
                )
            }
            guard initiator.isComplete, responder.isComplete else {
                return ContractResult(
                    name: vectorName,
                    passed: false,
                    detail: "handshake did not complete"
                )
            }

            return ContractResult(
                name: vectorName,
                passed: true,
                detail: "IK message 1+2 matched published snow vector bytes"
            )
        } catch {
            return ContractResult(
                name: vectorName,
                passed: false,
                detail: "handshake threw: \(error)"
            )
        }
    }

    private static func bytes(_ hex: String, _ label: String) throws -> [UInt8] {
        guard let value = Hex.bytes(hex) else {
            throw ContractHexError.malformed(label)
        }
        return value
    }

    private static func key(_ hex: String, _ label: String) throws -> NoiseKeyPair {
        try NoiseKeyPair(privateKey: bytes(hex, label))
    }
}

private enum ContractHexError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String {
        switch self {
        case .malformed(let label): return "malformed hex: \(label)"
        }
    }
}
