// Authors Vectors/noise-v1.json (W5, gate W-G6). Two provenances,
// deliberately separate:
//
// EXTERNAL HANDSHAKE VECTORS — copied verbatim from the two independent
// published Noise vector sets that carry Noise_IK_25519_ChaChaPoly_SHA256:
//
// - snow (Rust, github.com/mcginty/snow), tests/vectors/snow.txt at
//   master on 2026-07-21, file sha256
//   69da433305fd045f6c9f01b656662a389d022688986fd39fbe7af009cd402fd3
// - cacophony (Haskell, github.com/haskell-cryptography/cacophony),
//   vectors/cacophony.txt at master on 2026-07-21, file sha256
//   3bde7c09a6f349ee11c825c50fcc02649f8f02a47c857a459206b357f9386cae
//
// The hex below is transcribed from those files, not computed here —
// NoiseVectorFileTests must reproduce every byte, or the implementation
// is wrong (never the vector). Two independent implementations agreeing
// is the point of carrying both.
//
// PINNED TRANSPORT VECTORS — the Lyte extension (extended-counter nonce
// from (chan, seq), epoch rekey) has no published vectors because the
// nonce discipline is ours. These are generated HERE, by the very
// implementation under test, and frozen: a self-consistency pin against
// regression, honestly weaker than an external oracle. The primitives
// and handshake beneath them are covered by the external section.

import LyteWire
import LyteWireTestKit

func makeNoiseVectorFile() throws -> NoiseVectorFile {
    NoiseVectorFile(
        format: NoiseVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        handshakeVectors: [snowVector, cacophonyVector],
        transportVectors: [try makeTransportVector()]
    )
}

// MARK: - External vectors (transcribed, never regenerated)

private let snowVector = NoiseHandshakeVector(
    name: "snow-ik-25519-chachapoly-sha256",
    source: "https://raw.githubusercontent.com/mcginty/snow/master/tests/vectors/snow.txt",
    sourceSha256: "69da433305fd045f6c9f01b656662a389d022688986fd39fbe7af009cd402fd3",
    protocolName: "Noise_IK_25519_ChaChaPoly_SHA256",
    initPrologueHex: "5468657265206973206e6f20726967687420616e642077726f6e672e2054686572652773206f6e6c792066756e20616e6420626f72696e672e",
    initStaticHex: "f49f93c5112c0787acc808d61716d7e090e076a58f15a3f78d92773f8dcb473b",
    initEphemeralHex: "dae68498c41315cff7e4a34dded8d973199d8f0cf3fcb8b6651c169de77de8be",
    initRemoteStaticHex: "2ea5942829bac414e25aa4cbb1bcc43394816ebb1bd12550d7d0eb4415e42951",
    respPrologueHex: "5468657265206973206e6f20726967687420616e642077726f6e672e2054686572652773206f6e6c792066756e20616e6420626f72696e672e",
    respStaticHex: "b790546f98b1e933c48cd01f17e7b281469d46fcacc9a3b584ae65b1d6272e8e",
    respEphemeralHex: "c0875a5b59c8492bd2135e5432d7d484f938e0a1f5009428c4bcb70b2f69f69f",
    handshakeHashHex: nil,
    messages: [
        .init(
            payloadHex: "95a8f51c435a9530ff1f30868ed7b23ec952eb513c26a0774fed82d2978a8c81",
            ciphertextHex: "6d21fec9141f3f37cc464e936a48b2d9521b5a44e0f3d960895d3c3fba30282f731f445c25e898e2534ac0536715b24308c108fc46bd260c887b36c3f68e3a05654fc8295c068ed53fb2022560961224e0b10b0835e1efc82fc587cd50f7178fe3d9eb06e0351c6e7334162c10bed670bfa2a105f7b2768a140b3fd597782601"
        ),
        .init(
            payloadHex: "b866b807a6d8b83182b884dbfedc861843c5082bd6e480cb54e4245a72083041",
            ciphertextHex: "e64e1fb8701c4f4bc3850b255fea657d4d835338b059c89acc99628fbe52473b41a4e79e3c1e6abc46bf80f078a005e15d8a3e04f989af3e6cb99b52031165006163ac3e17b928af8c116009d7bf4fb2"
        ),
        .init(
            payloadHex: "e3a4937faef391028f759758b428b57652e0069a8dee64dfed01b60846938740",
            ciphertextHex: "2bebe19102169cdfe79cf41e38930bfd20a5b2fc78ccf33e853ddd939c0983174656eb27b61464a607762848892ca1c0"
        ),
        .init(
            payloadHex: "693972f27b0cb98aeac1fb54d782125431e7540e0cb2fa882cf51a8184d724fd",
            ciphertextHex: "c7c56da33b45d12f4754e17978bd49999c9c8f51d00db460f902aba2e6e245d0c46662f507915de8596f43b1d175f1db"
        ),
    ]
)

private let cacophonyVector = NoiseHandshakeVector(
    name: "cacophony-ik-25519-chachapoly-sha256",
    source: "https://raw.githubusercontent.com/haskell-cryptography/cacophony/master/vectors/cacophony.txt",
    sourceSha256: "3bde7c09a6f349ee11c825c50fcc02649f8f02a47c857a459206b357f9386cae",
    protocolName: "Noise_IK_25519_ChaChaPoly_SHA256",
    initPrologueHex: "4a6f686e2047616c74",
    initStaticHex: "e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1",
    initEphemeralHex: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a",
    initRemoteStaticHex: "31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62",
    respPrologueHex: "4a6f686e2047616c74",
    respStaticHex: "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893",
    respEphemeralHex: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b",
    handshakeHashHex: "0b0f68fb0c27e03ce9b97565995ed4838cc0581b762ef72b062f6a546419fad7",
    messages: [
        .init(
            payloadHex: "4c756477696720766f6e204d69736573",
            ciphertextHex: "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944718da798efbcd91528520204f904b9bd6c7413dccdc214d951e15253e39987f18146e8cd0873654207148333479d4d16c289f0294b29960a72f48e0b7bba2e89083169825e59642148d492020664ccf7"
        ),
        .init(
            payloadHex: "4d757272617920526f746862617264",
            ciphertextHex: "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088435361e70b2ed446e6c9ec387d1d6b3b840f194e373979d241b203c4acafccf5"
        ),
        .init(
            payloadHex: "462e20412e20486179656b",
            ciphertextHex: "050e9f3c8fac16b68dbce8f8c4bfbf6617c897f9ada4aa29aa19c8"
        ),
        .init(
            payloadHex: "4361726c204d656e676572",
            ciphertextHex: "344233a6cabb7141d80f3da2fedc311d9646bbb0f505afe403a667"
        ),
        .init(
            payloadHex: "4a65616e2d426170746973746520536179",
            ciphertextHex: "62cdeeb172ad7ade7aa7d9e069da5790f12331bfa00177787a1d0810c67dc3b2b4"
        ),
        .init(
            payloadHex: "457567656e2042f6686d20766f6e2042617765726b",
            ciphertextHex: "029bead1b40992327044d409d9a1f3ad8f36c3c452775d557e18bbeb2e8dfcead32d514024"
        ),
    ]
)

// MARK: - Pinned transport vector (generated, frozen)

/// Counting-pattern keys so a hex dump is auditable by eye; X25519
/// clamping makes any 32 bytes a valid private key.
private func makeTransportVector() throws -> NoiseTransportVector {
    let initStatic = try NoiseKeyPair(privateKey: counting(from: 0x10, count: 32))
    let initEphemeral = try NoiseKeyPair(privateKey: counting(from: 0x20, count: 32))
    let respStatic = try NoiseKeyPair(privateKey: counting(from: 0x30, count: 32))
    let respEphemeral = try NoiseKeyPair(privateKey: counting(from: 0x40, count: 32))
    let prologue = Array("lyte-udp".utf8)

    var client = try NoiseSession(
        role: .initiator,
        staticKeys: initStatic,
        remoteStaticPublicKey: respStatic.publicKey,
        prologue: prologue,
        fixedEphemeral: initEphemeral
    )
    var host = try NoiseSession(
        role: .responder,
        staticKeys: respStatic,
        prologue: prologue,
        fixedEphemeral: respEphemeral
    )

    let message1 = try client.writeMessage1()
    _ = try host.readMessage1(message1[...])
    let message2 = try host.writeMessage2()
    _ = try client.readMessage2(message2[...])

    var clientTransport = try client.makeTransport()
    var hostTransport = try host.makeTransport()

    // The script: CTRL and video traffic both ways, a 1112 B max-budget
    // shard, a u16 seq wrap entered near the top of the space (audio
    // channel anchors at 65534), a client→host rekey, and post-rekey
    // sends proving the epoch key change while the other direction stays
    // on epoch 0.
    var plan: [NoiseTransportVector.Step] = []

    func seal(
        _ direction: NoiseTransportVector.Step.Direction,
        chan: UInt8, seq: UInt16, frame: UInt32,
        timestamp: UInt64, fec: UInt64, plaintext: [UInt8]
    ) throws {
        let envelope = Envelope(
            channel: ChannelId(rawValue: chan),
            seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: frame),
            timestamp: timestamp,
            fec: fec
        )
        let aad = try envelope.encode(payload: [])
        let wirePayload: [UInt8]
        switch direction {
        case .clientToHost:
            wirePayload = try clientTransport.seal(
                plaintext: plaintext[...], aad: aad[...], envelope: envelope
            )
            let opened = try hostTransport.unseal(
                wirePayload: wirePayload[...], aad: aad[...], envelope: envelope
            )
            precondition(opened == plaintext, "transport self-check failed")
        case .hostToClient:
            wirePayload = try hostTransport.seal(
                plaintext: plaintext[...], aad: aad[...], envelope: envelope
            )
            let opened = try clientTransport.unseal(
                wirePayload: wirePayload[...], aad: aad[...], envelope: envelope
            )
            precondition(opened == plaintext, "transport self-check failed")
        }
        plan.append(.init(
            kind: .seal,
            direction: direction,
            channel: chan,
            seq: seq,
            frame: frame,
            timestampHex: Hex.uint64String(timestamp),
            fecHex: Hex.uint64String(fec),
            plaintextHex: Hex.string(plaintext),
            wirePayloadHex: Hex.string(wirePayload)
        ))
    }

    try seal(.clientToHost, chan: 0, seq: 0, frame: 0,
             timestamp: 0x0102_0304, fec: 0, plaintext: counting(from: 0, count: 16))
    try seal(.hostToClient, chan: 2, seq: 0, frame: 1,
             timestamp: 0x1122_3344, fec: 0, plaintext: counting(from: 0x80, count: 48))
    try seal(.clientToHost, chan: 0, seq: 1, frame: 0,
             timestamp: 0x0102_0405, fec: 0, plaintext: counting(from: 3, count: 24))
    try seal(.hostToClient, chan: 2, seq: 1, frame: 2,
             timestamp: 0x1122_4455, fec: 0,
             plaintext: counting(from: 0x40, count: 1112))
    // The u16 wrap: audio anchors at 65534 and walks through 0.
    for (i, seq) in [65534, 65535, 0, 1].enumerated() {
        try seal(.hostToClient, chan: 1, seq: UInt16(seq), frame: UInt32(i),
                 timestamp: 0x2000 + UInt64(i), fec: 0,
                 plaintext: counting(from: i, count: 20))
    }
    // Client→host rekey; the reverse direction stays on epoch 0.
    try clientTransport.rekeySend()
    try hostTransport.rekeyReceive()
    plan.append(.init(kind: .rekey, direction: .clientToHost))
    try seal(.clientToHost, chan: 0, seq: 2, frame: 0,
             timestamp: 0x0102_0506, fec: 0, plaintext: counting(from: 7, count: 32))
    try seal(.hostToClient, chan: 2, seq: 2, frame: 3,
             timestamp: 0x1122_5566, fec: 0, plaintext: counting(from: 0x90, count: 40))

    return NoiseTransportVector(
        name: "ik-transport-nominal",
        description: "Fixed-key IK session, both directions, max-budget shard, u16 seq wrap on chan 1, client→host rekey to epoch 1",
        provenance: "pinned-self-consistent",
        initStaticHex: Hex.string(initStatic.privateKey),
        initEphemeralHex: Hex.string(initEphemeral.privateKey),
        respStaticHex: Hex.string(respStatic.privateKey),
        respEphemeralHex: Hex.string(respEphemeral.privateKey),
        prologueHex: Hex.string(prologue),
        message1Hex: Hex.string(message1),
        message2Hex: Hex.string(message2),
        handshakeHashHex: Hex.string(clientTransport.handshakeHash),
        steps: plan
    )
}
