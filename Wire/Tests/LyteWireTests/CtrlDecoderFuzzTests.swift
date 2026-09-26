import XCTest
import LyteWire
import LyteWireTestKit

// Never-trap sweeps for peer-controlled decoders: the envelope, ARQ
// frames, the lifecycle pair, the bulk sextet's dispatcher, the capability
// messages, the repair refusal, the path pair, the IDR request, input
// events and echoes, and the audio-routing pair. Each
// codec sees seeded garbage (half of it with the codec's gate byte set, to
// get past it), every truncation of a valid message, and every
// single-byte substitution of one. A decoder may throw or succeed; it may
// never trap. A successful decode re-encodes to a fixpoint, and to exactly
// the input where the encoding is canonical.

final class CtrlDecoderFuzzTests: XCTestCase {

    private struct Codec {
        let name: String
        /// The gate byte garbage trials plant at `typeOffset`.
        let type: UInt8
        var typeOffset = 0
        let samples: [[UInt8]]
        /// Decodes and re-encodes; throws on a refused input.
        let roundTrip: ([UInt8]) throws -> [UInt8]
        /// False where decode accepts more than one spelling: the
        /// envelope, ARQ frames and path pair ignore reserved flag bits,
        /// and a declaration may omit the keys that default to "not
        /// supported".
        var canonical = true
    }

    private func codecs() throws -> [Codec] {
        let sha = [UInt8](repeating: 0xA5, count: 32)
        let map = try BulkChunkMap(contiguousCount: 7, bitmap: [0x05, 0x80])
        let offer = try BulkOffer(
            transferId: 9, totalByteCount: 10_000, chunkByteCount: 4_096,
            sha256: sha, name: "notes.txt", mimeHint: "text/plain"
        )
        let bulk: [BulkMessage] = [
            .offer(offer),
            .accept(try BulkAccept(
                transferId: 9, creditTotal: 256, possession: map
            )),
            .chunk(try BulkChunk(
                transferId: 9, chunkIndex: 2, data: [1, 2, 3, 4, 5, 6, 7, 8]
            )),
            .ack(try BulkAck(transferId: 9, creditTotal: 300, possession: map)),
            .complete(try BulkComplete(transferId: 9)),
            .abort(try BulkAbort(transferId: 9, reason: .cancelled)),
        ]
        var codecs = bulk.map { message in
            Codec(
                name: "bulk \(message.encode()[0])",
                type: message.encode()[0],
                samples: [message.encode()],
                roundTrip: { try BulkMessage.decode($0[...]).encode() }
            )
        }
        let capabilities = Capabilities.wireDefault.declaringFlag(
            CapabilityKey.clipboardText
        )
        let parameters = [
            CapabilityParameter(
                key: CapabilityKey.maxDatagramBytes, value: .unsigned(1_280)
            ),
        ]
        codecs += [
            Codec(
                name: "CapabilityDeclaration",
                type: CtrlMessageType.capabilityDeclaration,
                samples: [try CapabilityDeclaration(
                    capabilities: capabilities
                ).encode()],
                roundTrip: { try CapabilityDeclaration.decode($0).encode() },
                canonical: false
            ),
            Codec(
                name: "CapabilityUpdate", type: CtrlMessageType.capabilityUpdate,
                samples: [try CapabilityUpdate(parameters: parameters).encode()],
                roundTrip: { try CapabilityUpdate.decode($0[...]).encode() }
            ),
            Codec(
                name: "CapabilityUpdateAck",
                type: CtrlMessageType.capabilityUpdateAck,
                samples: [try CapabilityUpdateAck(
                    status: .accepted, parameters: parameters
                ).encode()],
                roundTrip: { try CapabilityUpdateAck.decode($0).encode() }
            ),
            Codec(
                name: "RepairRefusal", type: CtrlMessageType.repairRefused,
                samples: [RepairRefusal(
                    frame: FrameNumber(rawValue: 0x0102_0304), reason: .superseded
                ).encode()],
                roundTrip: { try RepairRefusal.decode($0[...]).encode() }
            ),
            Codec(
                name: "PathChallenge", type: CtrlMessageType.pathChallenge,
                samples: [PathChallenge(token: 0x1122_3344_5566_7788).encode()],
                roundTrip: { try PathChallenge.decode($0).encode() },
                canonical: false
            ),
            Codec(
                name: "PathResponse", type: CtrlMessageType.pathResponse,
                samples: [PathResponse(token: 0x8877_6655_4433_2211).encode()],
                roundTrip: { try PathResponse.decode($0).encode() },
                canonical: false
            ),
            Codec(
                name: "IdrRequest", type: CtrlMessageType.idrRequest,
                samples: [IdrRequest(
                    requestSeq: 5, frame: FrameNumber(rawValue: 77),
                    coalescedCount: 3
                ).encode()],
                roundTrip: { try IdrRequest.decode($0[...]).encode() }
            ),
            Codec(
                name: "InputEvent", type: CtrlMessageType.inputEvent,
                samples: try [
                    .keyKeycode(keycode: 30, pressed: true),
                    .pointerMotionAbsolute(x: 1_919.5, y: 0),
                    .pointerMotionRelative(dx: -3.25, dy: 7),
                    .pointerButton(button: 0x110, pressed: false),
                    .pointerAxis(dx: 0, dy: -120, finish: true),
                ].enumerated().map {
                    try InputEvent(
                        seq: UInt32($0.offset), clientMicroseconds: 9_000,
                        body: $0.element
                    ).encode()
                },
                roundTrip: { try InputEvent.decode($0[...]).encode() }
            ),
            Codec(
                name: "InputEcho", type: CtrlMessageType.inputEcho,
                samples: [InputEcho(tuples: [
                    InputEchoTuple(
                        seq: 4, receivedMicroseconds: 10,
                        injectedMicroseconds: 12),
                    InputEchoTuple(
                        seq: 5, receivedMicroseconds: 20,
                        injectedMicroseconds: 25),
                ]).encode()],
                roundTrip: { try InputEcho.decode($0[...]).encode() }
            ),
            Codec(
                name: "AudioRoutingRequest",
                type: CtrlMessageType.audioRoutingRequest,
                samples: [AudioRoutingRequest(mode: .hostMuted).encode()],
                roundTrip: { try AudioRoutingRequest.decode($0[...]).encode() }
            ),
            Codec(
                name: "AudioRoutingStatus",
                type: CtrlMessageType.audioRoutingStatus,
                samples: [AudioRoutingStatus(mode: .streamOff).encode()],
                roundTrip: { try AudioRoutingStatus.decode($0[...]).encode() }
            ),
        ]

        let envelope = try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0x0102),
            frame: FrameNumber(rawValue: 0x0304_0506), timestamp: 7, fec: 9,
            extensions: [WireExtension(type: 0x7F, value: [0xEE, 0xFF])]
        ).encode(payload: [1, 2, 3, 4])
        let segment = try ArqSegment(
            group: ArqGroupId(rawValue: 3), seq: ArqSegmentSeq(rawValue: 9),
            endOfMessage: true, body: [1, 2, 3, 4, 5]
        )
        let ack = try ArqAck(blocks: [ArqAck.Block(
            channel: .ctrl, group: ArqGroupId(rawValue: 3),
            cumulative: ArqSegmentSeq(rawValue: 8), receivedBitmap: [0xFF, 0x01]
        )])
        codecs += [
            Codec(
                name: "Envelope", type: 0x01, typeOffset: 1,
                samples: [envelope],
                roundTrip: {
                    let (envelope, payload) = try Envelope.decode($0)
                    return try envelope.encode(payload: payload)
                },
                canonical: false
            ),
            Codec(
                name: "ArqFrame", type: CtrlMessageType.arqSegment,
                samples: [ack.encode() + segment.encode()],
                roundTrip: { try ArqFrame.decodeAll($0).flatMap { $0.encode() } },
                canonical: false
            ),
            Codec(
                name: "ModeTransition", type: CtrlMessageType.modeTransition,
                samples: [ModeTransition(mode: .idle).encode()],
                roundTrip: { try ModeTransition.decode($0).encode() }
            ),
            Codec(
                name: "SessionTeardown", type: CtrlMessageType.sessionTeardown,
                samples: [SessionTeardown(reason: .shuttingDown).encode()],
                roundTrip: { try SessionTeardown.decode($0).encode() }
            ),
        ]
        return codecs
    }

    private func check(_ codec: Codec, _ input: [UInt8], _ label: String) {
        guard let output = try? codec.roundTrip(input) else { return }
        if codec.canonical {
            XCTAssertEqual(output, input, "\(codec.name) \(label)")
        } else {
            XCTAssertEqual(try codec.roundTrip(output), output,
                           "\(codec.name) \(label)")
        }
    }

    func testSamplesRoundTrip() throws {
        for codec in try codecs() {
            for sample in codec.samples {
                XCTAssertEqual(try codec.roundTrip(sample), sample, codec.name)
            }
        }
    }

    func testArbitraryBytesNeverTrap() throws {
        var rng = SplitMix64(seed: 0xC7_12_F0_22)
        for codec in try codecs() {
            for trial in 0..<600 {
                var bytes = rng.bytes(rng.int(in: 0...1_300))
                if bytes.count > codec.typeOffset, trial % 2 == 0 {
                    bytes[codec.typeOffset] = codec.type
                }
                check(codec, bytes, "garbage trial \(trial)")
            }
        }
    }

    func testEveryTruncationNeverTraps() throws {
        for codec in try codecs() {
            for sample in codec.samples {
                for length in 0..<sample.count {
                    check(codec, Array(sample.prefix(length)),
                          "cut to \(length)")
                }
                check(codec, sample + [0], "one trailing byte")
            }
        }
    }

    func testEverySingleByteSubstitutionNeverTraps() throws {
        for codec in try codecs() {
            for sample in codec.samples {
                for offset in sample.indices {
                    for value: UInt8 in [0x00, 0x01, 0x7F, 0x80, 0xFF,
                                         sample[offset] ^ 0x01] {
                        var mutated = sample
                        mutated[offset] = value
                        check(codec, mutated, "byte \(offset) = \(value)")
                    }
                }
            }
        }
    }
}
