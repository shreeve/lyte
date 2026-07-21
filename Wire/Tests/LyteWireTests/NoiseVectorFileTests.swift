import XCTest
import LyteWire
import LyteWireTestKit

// Gate W-G6's crux: the committed Vectors/noise-v1.json, byte-for-byte.
//
// The handshakeVectors section is EXTERNAL — published vectors from two
// independent implementations (snow and cacophony) of
// Noise_IK_25519_ChaChaPoly_SHA256. Every handshake byte, every
// transport-message byte, and (where the source carries it) the
// handshake hash must match exactly; a mismatch is an implementation
// bug, never a vector to regenerate.
//
// The transportVectors section is the Lyte nonce/rekey extension —
// pinned self-consistent (see the file and Vectors/README.md for the
// honesty note) — replayed here against both ends of the session.

final class NoiseVectorFileTests: XCTestCase {

    private static let vectorsPath = packageRoot + "/Vectors/noise-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> NoiseVectorFile {
        try NoiseVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, NoiseVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertEqual(
            file.handshakeVectors.count, 2,
            "both external sources (snow, cacophony) must be present"
        )
        XCTAssertFalse(file.transportVectors.isEmpty)
        for vector in file.handshakeVectors {
            XCTAssertEqual(vector.protocolName, "Noise_IK_25519_ChaChaPoly_SHA256")
            XCTAssertTrue(
                vector.source.hasPrefix("https://"),
                "\(vector.name): external provenance required"
            )
            XCTAssertGreaterThanOrEqual(
                vector.messages.count, 3,
                "\(vector.name): need handshake + at least one transport message"
            )
        }
        for vector in file.transportVectors {
            XCTAssertEqual(
                vector.provenance, "pinned-self-consistent",
                "\(vector.name): transport vectors must be honestly labeled"
            )
        }
    }

    // MARK: External handshake vectors

    func testExternalHandshakeVectors() throws {
        for vector in try loadFile().handshakeVectors {
            try runHandshakeVector(vector)
        }
    }

    private func runHandshakeVector(_ vector: NoiseHandshakeVector) throws {
        guard
            let initPrologue = Hex.bytes(vector.initPrologueHex),
            let initStatic = Hex.bytes(vector.initStaticHex),
            let initEphemeral = Hex.bytes(vector.initEphemeralHex),
            let initRemoteStatic = Hex.bytes(vector.initRemoteStaticHex),
            let respPrologue = Hex.bytes(vector.respPrologueHex),
            let respStatic = Hex.bytes(vector.respStaticHex),
            let respEphemeral = Hex.bytes(vector.respEphemeralHex)
        else {
            return XCTFail("\(vector.name): malformed hex")
        }

        let initStaticKeys = try NoiseKeyPair(privateKey: initStatic)
        let respStaticKeys = try NoiseKeyPair(privateKey: respStatic)
        // The vector's own consistency: the initiator's pinned remote
        // static must be the responder's actual public key.
        XCTAssertEqual(
            Hex.string(respStaticKeys.publicKey),
            Hex.string(initRemoteStatic),
            "\(vector.name): init_remote_static mismatch"
        )

        var initiator = try NoiseHandshake(
            role: .initiator,
            staticKeys: initStaticKeys,
            remoteStaticPublicKey: initRemoteStatic,
            prologue: initPrologue,
            fixedEphemeral: try NoiseKeyPair(privateKey: initEphemeral)
        )
        var responder = try NoiseHandshake(
            role: .responder,
            staticKeys: respStaticKeys,
            prologue: respPrologue,
            fixedEphemeral: try NoiseKeyPair(privateKey: respEphemeral)
        )

        let messages = try vector.messages.map { message in
            guard
                let payload = Hex.bytes(message.payloadHex),
                let ciphertext = Hex.bytes(message.ciphertextHex)
            else {
                throw VectorFileError.malformedField("\(vector.name) message hex")
            }
            return (payload: payload, ciphertext: ciphertext)
        }

        // Handshake message 1 (initiator → responder): byte-exact write,
        // and the read recovers the payload and the initiator identity.
        let message1 = try initiator.writeMessage1(payload: messages[0].payload[...])
        XCTAssertEqual(
            Hex.string(message1), Hex.string(messages[0].ciphertext),
            "\(vector.name): message 1 bytes diverge from the published vector"
        )
        let payload1 = try responder.readMessage1(messages[0].ciphertext[...])
        XCTAssertEqual(payload1, messages[0].payload, vector.name)
        XCTAssertEqual(
            responder.remoteStaticPublicKey.map(Hex.string),
            Hex.string(initStaticKeys.publicKey),
            "\(vector.name): responder must learn the initiator static"
        )

        // Handshake message 2 (responder → initiator).
        let message2 = try responder.writeMessage2(payload: messages[1].payload[...])
        XCTAssertEqual(
            Hex.string(message2), Hex.string(messages[1].ciphertext),
            "\(vector.name): message 2 bytes diverge from the published vector"
        )
        let payload2 = try initiator.readMessage2(messages[1].ciphertext[...])
        XCTAssertEqual(payload2, messages[1].payload, vector.name)

        XCTAssertTrue(initiator.isComplete)
        XCTAssertTrue(responder.isComplete)

        // Transcript agreement — the W6 PAKE binding hook.
        XCTAssertEqual(initiator.handshakeHash, responder.handshakeHash, vector.name)
        if let expectedHash = vector.handshakeHashHex {
            XCTAssertEqual(
                Hex.string(initiator.handshakeHash), expectedHash,
                "\(vector.name): handshake hash diverges from the published vector"
            )
        }

        // Transport messages: alternating directions starting with the
        // initiator, sequential Noise nonces, empty AAD — the published
        // convention. This externally verifies Split and the AEAD.
        var (initSend, initRecv) = try initiator.splitCipherStates()
        var (respSend, respRecv) = try responder.splitCipherStates()
        for (i, message) in messages.dropFirst(2).enumerated() {
            let initiatorSends = i % 2 == 0
            if initiatorSends {
                let sealed = try initSend.encryptWithAd([][...], message.payload[...])
                XCTAssertEqual(
                    Hex.string(sealed), Hex.string(message.ciphertext),
                    "\(vector.name): transport message \(i) diverges"
                )
                let opened = try respRecv.decryptWithAd([][...], message.ciphertext[...])
                XCTAssertEqual(opened, message.payload, vector.name)
            } else {
                let sealed = try respSend.encryptWithAd([][...], message.payload[...])
                XCTAssertEqual(
                    Hex.string(sealed), Hex.string(message.ciphertext),
                    "\(vector.name): transport message \(i) diverges"
                )
                let opened = try initRecv.decryptWithAd([][...], message.ciphertext[...])
                XCTAssertEqual(opened, message.payload, vector.name)
            }
        }
    }

    // MARK: Pinned transport vectors

    func testPinnedTransportVectors() throws {
        for vector in try loadFile().transportVectors {
            try runTransportVector(vector)
        }
    }

    private func runTransportVector(_ vector: NoiseTransportVector) throws {
        guard
            let initStatic = Hex.bytes(vector.initStaticHex),
            let initEphemeral = Hex.bytes(vector.initEphemeralHex),
            let respStatic = Hex.bytes(vector.respStaticHex),
            let respEphemeral = Hex.bytes(vector.respEphemeralHex),
            let prologue = Hex.bytes(vector.prologueHex)
        else {
            return XCTFail("\(vector.name): malformed key hex")
        }

        let respStaticKeys = try NoiseKeyPair(privateKey: respStatic)
        var client = try NoiseSession(
            role: .initiator,
            staticKeys: try NoiseKeyPair(privateKey: initStatic),
            remoteStaticPublicKey: respStaticKeys.publicKey,
            prologue: prologue,
            fixedEphemeral: try NoiseKeyPair(privateKey: initEphemeral)
        )
        var host = try NoiseSession(
            role: .responder,
            staticKeys: respStaticKeys,
            prologue: prologue,
            fixedEphemeral: try NoiseKeyPair(privateKey: respEphemeral)
        )

        let message1 = try client.writeMessage1()
        XCTAssertEqual(Hex.string(message1), vector.message1Hex, vector.name)
        XCTAssertEqual(try host.readMessage1(message1[...]), [], vector.name)
        let message2 = try host.writeMessage2()
        XCTAssertEqual(Hex.string(message2), vector.message2Hex, vector.name)
        XCTAssertEqual(try client.readMessage2(message2[...]), [], vector.name)
        XCTAssertEqual(client.negotiatedVersion, WireVersion.major)
        XCTAssertEqual(host.negotiatedVersion, WireVersion.major)
        XCTAssertEqual(
            Hex.string(client.handshakeHash), vector.handshakeHashHex, vector.name
        )
        XCTAssertEqual(client.handshakeHash, host.handshakeHash, vector.name)

        var clientTransport = try client.makeTransport()
        var hostTransport = try host.makeTransport()

        for (index, step) in vector.steps.enumerated() {
            switch step.kind {
            case .rekey:
                switch step.direction {
                case .clientToHost:
                    try clientTransport.rekeySend()
                    try hostTransport.rekeyReceive()
                case .hostToClient:
                    try hostTransport.rekeySend()
                    try clientTransport.rekeyReceive()
                }
            case .seal:
                guard
                    let plaintextHex = step.plaintextHex,
                    let plaintext = Hex.bytes(plaintextHex),
                    let expectedHex = step.wirePayloadHex,
                    let expected = Hex.bytes(expectedHex)
                else {
                    return XCTFail("\(vector.name) step \(index): malformed seal")
                }
                let envelope = try step.makeEnvelope()
                let aad = try envelope.encode(payload: [])
                let sealed: [UInt8]
                let opened: [UInt8]
                switch step.direction {
                case .clientToHost:
                    sealed = try clientTransport.seal(
                        plaintext: plaintext[...], aad: aad[...], envelope: envelope
                    )
                    opened = try hostTransport.unseal(
                        wirePayload: expected[...], aad: aad[...], envelope: envelope
                    )
                case .hostToClient:
                    sealed = try hostTransport.seal(
                        plaintext: plaintext[...], aad: aad[...], envelope: envelope
                    )
                    opened = try clientTransport.unseal(
                        wirePayload: expected[...], aad: aad[...], envelope: envelope
                    )
                }
                XCTAssertEqual(
                    Hex.string(sealed), expectedHex,
                    "\(vector.name) step \(index): wire payload diverges from the pin"
                )
                XCTAssertEqual(opened, plaintext, "\(vector.name) step \(index)")
                XCTAssertEqual(
                    sealed.count, plaintext.count + WireBudget.aeadTagByteCount,
                    "\(vector.name) step \(index): tag overhead must be exactly 16 B"
                )
                XCTAssertLessThanOrEqual(
                    sealed.count, WireBudget.maxWirePayloadByteCount,
                    "\(vector.name) step \(index)"
                )
            }
        }
    }
}
