import XCTest
import LyteWire
import LyteWireTestKit

// The typed capability set: the hand-computed CBOR anchor (breaking
// the vector file's circularity), the unknown-key/unknown-id
// forward-compat rules, the decode rejects, and the W-G8 intersect
// algebra as seeded properties (commutative, idempotent — plus
// associative, free from the same construction).

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

    func testRicherSetRoundTrips() throws {
        let set = Capabilities(
            wireMinor: 3,
            videoCodecs: [CapabilityCodec.hevc, 2],
            chromaModes: [CapabilityChroma.yuv420, CapabilityChroma.yuv444],
            idleSilence: true,
            featureChannels: [
                CapabilityFeature.clipboard,
                CapabilityFeature.fileTransfer,
                CapabilityFeature.printing,
            ],
            audioExpress: true,
            resume: true,
            maxDatagramBytes: 1500
        )
        let encoded = try set.encodeCbor()
        XCTAssertEqual(try Capabilities.decodeCbor(encoded), set)
    }

    // MARK: - Forward compatibility

    func testUnknownKeysArePreservedNotRejected() throws {
        // wireDefault plus a foreign key 100 → text "x": one more map
        // entry (0xA9), 0x1864 sorting after 0x08 bytewise.
        let foreign = "a9" + Self.wireDefaultHex.dropFirst(2)
            + "18646178"
        let decoded = try Capabilities.decodeCbor(hex(foreign))
        XCTAssertEqual(decoded.unknownEntries, [
            CborMapEntry(key: .unsigned(100), value: .text("x"))
        ])
        XCTAssertEqual(decoded.wireMinor, 0)
        // Preservation is byte-exact through re-encode.
        XCTAssertEqual(try decoded.encodeCbor(), hex(foreign))
    }

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

    func testUnknownIdsInsideListsCarryNotReject() throws {
        var set = Capabilities.wireDefault
        set.videoCodecs = [CapabilityCodec.hevc, 200]
        let decoded = try Capabilities.decodeCbor(try set.encodeCbor())
        XCTAssertEqual(decoded.videoCodecs, [1, 200])
        // Intersection with a v1-only peer drops the foreign id.
        XCTAssertEqual(
            decoded.intersecting(.wireDefault).videoCodecs,
            [CapabilityCodec.hevc]
        )
    }

    func testOmittedOptionalKeysDefaultToUnsupported() throws {
        // A lean future declaration: only the three required keys.
        let lean = try Cbor.encode(.map([
            .init(key: .unsigned(1), value: .unsigned(0)),
            .init(key: .unsigned(2), value: .array([.unsigned(1)])),
            .init(key: .unsigned(3), value: .array([.unsigned(1)])),
        ]))
        let decoded = try Capabilities.decodeCbor(lean)
        XCTAssertFalse(decoded.idleSilence)
        XCTAssertEqual(decoded.featureChannels, [])
        XCTAssertFalse(decoded.audioExpress)
        XCTAssertFalse(decoded.resume)
        XCTAssertEqual(
            decoded.maxDatagramBytes,
            UInt32(WireBudget.maxDatagramByteCount)
        )
    }

    // MARK: - Rejects

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
            XCTAssertThrowsError(
                try Capabilities.decodeCbor(try Cbor.encode(.map(entries)))
            ) { error in
                XCTAssertEqual(
                    error as? CapabilityError, .missingKey(missing)
                )
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
            XCTAssertThrowsError(
                try Capabilities.decodeCbor(try Cbor.encode(.map(entries))),
                "key \(key)"
            ) { error in
                XCTAssertEqual(
                    error as? CapabilityError,
                    .wrongValueType(key: key), "key \(key)"
                )
            }
        }
        // Non-canonical id list (descending).
        let descending = try Cbor.encode(.map([
            .init(key: .unsigned(1), value: .unsigned(0)),
            .init(
                key: .unsigned(2),
                value: .array([.unsigned(2), .unsigned(1)])
            ),
            .init(key: .unsigned(3), value: .array([.unsigned(1)])),
        ]))
        XCTAssertThrowsError(
            try Capabilities.decodeCbor(descending)
        ) { error in
            XCTAssertEqual(error as? CapabilityError, .nonCanonicalIdList)
        }
        // Ceiling below the 1152 B protocol floor.
        let lowCeiling = try Cbor.encode(.map([
            .init(key: .unsigned(1), value: .unsigned(0)),
            .init(key: .unsigned(2), value: .array([.unsigned(1)])),
            .init(key: .unsigned(3), value: .array([.unsigned(1)])),
            .init(key: .unsigned(8), value: .unsigned(1151)),
        ]))
        XCTAssertThrowsError(
            try Capabilities.decodeCbor(lowCeiling)
        ) { error in
            XCTAssertEqual(
                error as? CapabilityError, .datagramCeilingBelowFloor(1151)
            )
        }
        // Not a map at the top level.
        XCTAssertThrowsError(
            try Capabilities.decodeCbor(hex("810a"))
        ) { error in
            XCTAssertEqual(error as? CapabilityError, .notAMap)
        }
        // Malformed CBOR wraps the inner error.
        XCTAssertThrowsError(
            try Capabilities.decodeCbor(hex("a2"))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityError, .malformedCbor(.truncatedItem)
            )
        }
    }

    func testEncodeRejectsNonCanonicalConstruction() {
        var bad = Capabilities.wireDefault
        bad.chromaModes = [2, 1]
        XCTAssertThrowsError(try bad.encodeCbor()) { error in
            XCTAssertEqual(error as? CapabilityError, .nonCanonicalIdList)
        }
        var low = Capabilities.wireDefault
        low.maxDatagramBytes = 100
        XCTAssertThrowsError(try low.encodeCbor()) { error in
            XCTAssertEqual(
                error as? CapabilityError, .datagramCeilingBelowFloor(100)
            )
        }
    }

    // MARK: - Intersect algebra (gate W-G8)

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
