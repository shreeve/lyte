import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// The typed capability set: the hand-computed CBOR anchor (breaking
// the vector file's circularity), the forward-compat rules no vector
// pins, the rejects' associated values, the keys 9–16 flag spine, and
// the intersect algebra as seeded properties (commutative, idempotent,
// associative, absorbing).

final class CapabilitiesTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        Hex.bytes(s)!
    }

    /// wireDefault's map, walked by hand: 8 entries (0xA8), keys 1–8,
    /// minor 0, codecs [hevc]=[1], chroma [4:2:0]=[1], idle-silence
    /// true, features [], audio-express false, resume false, ceiling
    /// 1152 (0x0480, two-byte argument).
    static let wireDefaultHex =
        "a8010002810103810104f5058006f407f408190480"

    func testHandComputedWireDefaultAnchor() throws {
        XCTAssertEqual(
            try Capabilities.wireDefault.encodeCbor(),
            hex(Self.wireDefaultHex)
        )
        XCTAssertEqual(
            try Capabilities.decodeCbor(hex(Self.wireDefaultHex)),
            Capabilities.wireDefault
        )
    }

    // MARK: - Forward compatibility

    func testNonIntegerKeysAreForeignToo() throws {
        // Text key "zz" (0x627a7a) sorts after every integer key.
        let foreign = "a9" + Self.wireDefaultHex.dropFirst(2)
            + "627a7af5"
        let decoded = try Capabilities.decodeCbor(hex(foreign))
        XCTAssertEqual(decoded.unknownEntries, [
            CborMapEntry(key: .text("zz"), value: .bool(true))
        ])
        XCTAssertEqual(try decoded.encodeCbor(), hex(foreign))
    }

    // MARK: - Rejects

    /// The rejects whose associated values capabilities-v1.json cannot
    /// pin (its vectors compare error case names only).
    func testDecodeRejects() throws {
        // Missing each required key in turn.
        for missing in [CapabilityKey.wireMinor,
                        CapabilityKey.videoCodecs,
                        CapabilityKey.chromaModes] {
            let entries: [CborMapEntry] = [
                .init(key: .unsigned(1), value: .unsigned(0)),
                .init(key: .unsigned(2), value: .array([.unsigned(1)])),
                .init(key: .unsigned(3), value: .array([.unsigned(1)])),
            ].filter {
                if case .unsigned(let k) = $0.key { return k != missing }
                return true
            }
            assertThrows(CapabilityError.missingKey(missing)) {
                try Capabilities.decodeCbor(try Cbor.encode(.map(entries)))
            }
        }
        // Wrong registered types.
        let wrongTypes: [(UInt64, CborValue)] = [
            (CapabilityKey.wireMinor, .text("1")),
            (CapabilityKey.wireMinor, .unsigned(0x1_0000)),
            (CapabilityKey.videoCodecs, .unsigned(1)),
            (CapabilityKey.videoCodecs, .array([.text("hevc")])),
            (CapabilityKey.idleSilence, .unsigned(1)),
            (CapabilityKey.maxDatagramBytes, .bool(true)),
            (CapabilityKey.maxDatagramBytes, .unsigned(0x1_0000_0000)),
        ]
        for (key, value) in wrongTypes {
            var entries: [CborMapEntry] = [
                .init(key: .unsigned(1), value: .unsigned(0)),
                .init(key: .unsigned(2), value: .array([.unsigned(1)])),
                .init(key: .unsigned(3), value: .array([.unsigned(1)])),
            ].filter {
                if case .unsigned(let k) = $0.key { return k != key }
                return true
            }
            entries.append(.init(key: .unsigned(key), value: value))
            assertThrows(
                CapabilityError.wrongValueType(key: key), "key \(key)"
            ) {
                try Capabilities.decodeCbor(try Cbor.encode(.map(entries)))
            }
        }
        // Malformed CBOR wraps the inner error.
        assertThrows(CapabilityError.malformedCbor(.truncatedItem)) {
            try Capabilities.decodeCbor(hex("a2"))
        }
    }

    func testEncodeRejectsNonCanonicalConstruction() {
        var bad = Capabilities.wireDefault
        bad.chromaModes = [2, 1]
        assertThrows(CapabilityError.nonCanonicalIdList) {
            try bad.encodeCbor()
        }
        var low = Capabilities.wireDefault
        low.maxDatagramBytes = 100
        assertThrows(CapabilityError.datagramCeilingBelowFloor(100)) {
            try low.encodeCbor()
        }
    }

    // MARK: - Intersect algebra

    func testIntersectHandExample() {
        let host = Capabilities(
            wireMinor: 2,
            videoCodecs: [1, 2],
            chromaModes: [1, 2],
            idleSilence: true,
            featureChannels: [1, 2, 3],
            audioExpress: true,
            resume: true,
            maxDatagramBytes: 1500
        )
        let client = Capabilities(
            wireMinor: 0,
            videoCodecs: [1],
            chromaModes: [1],
            idleSilence: true,
            featureChannels: [1],
            audioExpress: false,
            resume: true,
            maxDatagramBytes: 1400
        )
        let agreed = host.intersecting(client)
        XCTAssertEqual(agreed.wireMinor, 0)
        XCTAssertEqual(agreed.videoCodecs, [1])
        XCTAssertEqual(agreed.chromaModes, [1])
        XCTAssertTrue(agreed.idleSilence)
        XCTAssertEqual(agreed.featureChannels, [1])
        XCTAssertFalse(agreed.audioExpress)
        XCTAssertTrue(agreed.resume)
        XCTAssertEqual(agreed.maxDatagramBytes, 1400)
    }

    func testUnknownEntriesSurviveOnlyByteEqualAgreement() {
        let shared = CborMapEntry(key: .unsigned(100), value: .unsigned(7))
        let aOnly = CborMapEntry(key: .unsigned(101), value: .text("a"))
        let conflicting = CborMapEntry(
            key: .unsigned(102), value: .unsigned(1)
        )
        let conflicted = CborMapEntry(
            key: .unsigned(102), value: .unsigned(2)
        )
        var a = Capabilities.wireDefault
        a.unknownEntries = [shared, aOnly, conflicting]
        var b = Capabilities.wireDefault
        b.unknownEntries = [shared, conflicted]
        XCTAssertEqual(a.intersecting(b).unknownEntries, [shared])
        XCTAssertEqual(b.intersecting(a).unknownEntries, [shared])
    }

    /// Flag declarations land in canonical key order whatever order the
    /// shells declare them in, so sets built differently but meaning the
    /// same compare equal — and intersection is commutative as a value,
    /// not only as encoded bytes.
    func testFlagDeclarationOrderIsCanonical() throws {
        let a = Capabilities.wireDefault
            .declaringCursorShape()
            .declaringClipboardText()
            .declaringBulkTransfer()
        let b = Capabilities.wireDefault
            .declaringBulkTransfer()
            .declaringCursorShape()
            .declaringClipboardText()
        XCTAssertEqual(a, b)
        XCTAssertEqual(
            a.unknownEntries.map(\.key),
            [CapabilityKey.clipboardText, CapabilityKey.bulkTransfer,
             CapabilityKey.cursorShape].map { CborValue.unsigned($0) }
        )
        let c = Capabilities.wireDefault
            .declaringCursorShape()
            .declaringBulkTransfer()
        XCTAssertEqual(a.intersecting(c), c.intersecting(a))
        XCTAssertEqual(try Capabilities.decodeCbor(a.encodeCbor()), a)
    }

    /// Keys 9–16 each ride `unknownEntries` as one canonical `key F5`
    /// entry: the frozen v1 bytes plus exactly that entry, read back by
    /// the v1 decoder, declared idempotently, surviving intersection only
    /// on mutual declaration, and replacing a peer's `false` (which reads
    /// as absent) rather than duplicating the key.
    func testFlagKeysRideTheSpineWithoutMovingFrozenBytes() throws {
        typealias Flag = (
            key: UInt8, declare: (Capabilities) -> Capabilities,
            read: (Capabilities) -> Bool
        )
        let flags: [Flag] = [
            (9, { $0.declaringHostAudioRouting() }, \.hostAudioRouting),
            (10, { $0.declaringClipboardText() }, \.clipboardText),
            (11, { $0.declaringBulkTransfer() }, \.bulkTransfer),
            (12, { $0.declaringClipboardImages() }, \.clipboardImages),
            (13, { $0.declaringCursorShape() }, \.cursorShape),
            (14, { $0.declaringAudioStreamOff() }, \.audioStreamOff),
            (15, { $0.declaringAudioQuietPosture() }, \.audioQuietPosture),
            (16, { $0.declaringVideoQuietPosture() }, \.videoQuietPosture),
        ]
        let base = hex(Self.wireDefaultHex)
        for (key, declare, read) in flags {
            let label = "key \(key)"
            let declared = declare(.wireDefault)
            let expected: [UInt8] = [0xA9] + base.dropFirst() + [key, 0xF5]
            XCTAssertEqual(try declared.encodeCbor(), expected, label)
            XCTAssertEqual(try Capabilities.decodeCbor(expected), declared, label)
            XCTAssertTrue(read(declared), label)
            XCTAssertFalse(read(.wireDefault), label)
            XCTAssertEqual(declare(declared), declared, label)

            XCTAssertTrue(read(declared.intersecting(declared)), label)
            XCTAssertFalse(read(declared.intersecting(.wireDefault)), label)
            XCTAssertFalse(read(Capabilities.wireDefault.intersecting(declared)), label)

            var refusing = Capabilities.wireDefault
            refusing.unknownEntries = [CborMapEntry(
                key: .unsigned(UInt64(key)), value: .bool(false)
            )]
            XCTAssertFalse(read(refusing), label)
            XCTAssertFalse(read(declared.intersecting(refusing)), label)
            XCTAssertEqual(try declare(refusing).encodeCbor(), expected, label)
        }
    }

    func testIntersectAlgebraProperties() {
        var rng = SplitMix64(seed: 0x57C0_DE03)
        for iteration in 0..<500 {
            let a = Self.randomCapabilities(rng: &rng)
            let b = Self.randomCapabilities(rng: &rng)
            let c = Self.randomCapabilities(rng: &rng)
            XCTAssertEqual(
                a.intersecting(b), b.intersecting(a),
                "commutative, iteration \(iteration)"
            )
            XCTAssertEqual(
                a.intersecting(a), a,
                "idempotent, iteration \(iteration)"
            )
            XCTAssertEqual(
                a.intersecting(b).intersecting(c),
                a.intersecting(b.intersecting(c)),
                "associative, iteration \(iteration)"
            )
            // Absorption: the agreed set re-intersected with either
            // declaration is itself.
            let agreed = a.intersecting(b)
            XCTAssertEqual(
                agreed.intersecting(a), agreed,
                "absorbing, iteration \(iteration)"
            )
        }
    }

    private static func randomCapabilities(
        rng: inout SplitMix64
    ) -> Capabilities {
        func idSubset(of pool: [UInt64]) -> [UInt64] {
            pool.filter { _ in rng.next() & 1 == 0 }
        }
        // Unknown-entry pool with per-key value variants so byte-equal
        // agreement is possible but not guaranteed.
        var unknowns: [CborMapEntry] = []
        for key: UInt64 in [100, 101, 102] where rng.next() & 1 == 0 {
            unknowns.append(CborMapEntry(
                key: .unsigned(key),
                value: .unsigned(rng.next() % 2)
            ))
        }
        return Capabilities(
            wireMinor: UInt16(rng.next() % 6),
            videoCodecs: idSubset(of: [1, 2, 3]),
            chromaModes: idSubset(of: [1, 2]),
            idleSilence: rng.next() & 1 == 0,
            featureChannels: idSubset(of: [1, 2, 3]),
            audioExpress: rng.next() & 1 == 0,
            resume: rng.next() & 1 == 0,
            maxDatagramBytes: 1152 + UInt32(rng.next() % 400),
            unknownEntries: unknowns
        )
    }
}
