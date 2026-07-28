// The typed capability set (W7) — the transport pillar §4's
// "superpowers handshake" as data. Each end declares one of these right
// after establishment (the first ARQ-carried messages both ways); the
// session's effective capabilities are the INTERSECTION, computed
// identically on both ends from the same two declarations.
//
// Wire form: a deterministic CBOR map (Cbor.swift's profile) with
// UNSIGNED INTEGER keys from the registry below. Forward compatibility
// is the design's spine, in three rules:
//
//  1. Unknown KEYS are ignored (never a decode error) and preserved
//     verbatim — a v1.0 end reads a v1.2 declaration fine.
//  2. Unknown VALUES inside id lists (codecs, chroma, features) are
//     carried, not rejected — a future codec id must not break v1
//     ends; intersection with the local set drops it naturally.
//  3. New semantics ship as new keys gated by intersection, so a
//     capability is enabled only when BOTH ends declare it — absence
//     is always "not supported", never an error.
//
// Intersection algebra (gate W-G8: commutative, idempotent):
//   wireMinor            min
//   id lists             set intersection (canonical ascending order)
//   booleans             logical AND
//   maxDatagramBytes     min
//   unknown entries      kept only when present in BOTH declarations
//                        with byte-equal values, dropped otherwise —
//                        the one rule that keeps the algebra idempotent
//                        (intersect(a, a) == a) without pretending to
//                        understand foreign semantics. In practice a
//                        local declaration never carries entries
//                        unknown to its own build, so foreign keys
//                        simply vanish from the agreed set.
//
// Capabilities are session-scoped and fixed after the exchange except
// where the registry marks a key renegotiable (transport pillar §4;
// overview §2's session-parameter-renegotiation row: chroma/codec are
// connect-time only, geometry may move). v1 marks exactly one key
// renegotiable: maxDatagramBytes — the DPLPMTUD seam, raised on direct
// paths only, applied at an IDR boundary, never past either end's
// declared ceiling.

/// The capability key registry (wire v1). Keys are CBOR unsigned map
/// keys; the numbers are wire contract. New keys append; a key's type
/// and meaning never change once assigned.
public enum CapabilityKey {
    /// u16 — the wire MINOR version (the major rides in the Noise
    /// handshake payload, W5). Agreed = min. Minors are always
    /// compatible by the unknown-key rule; this is information, not a
    /// gate.
    public static let wireMinor: UInt64 = 1
    /// Ascending id list — video codecs (CapabilityCodec). Empty
    /// intersection is negotiation failure: no session without video.
    public static let videoCodecs: UInt64 = 2
    /// Ascending id list — chroma modes (CapabilityChroma). Empty
    /// intersection is negotiation failure.
    public static let chromaModes: UInt64 = 3
    /// bool — damage-driven idle silence (no idle-floor datagrams).
    public static let idleSilence: UInt64 = 4
    /// Ascending id list — feature channels (CapabilityFeature):
    /// clipboard (H3), files/printing (H5). Empty is fine.
    public static let featureChannels: UInt64 = 5
    /// bool — the reserved audio-express escape hatch (transport §2):
    /// a second DSCP-48 audio-only association. Declared, never yet
    /// built.
    public static let audioExpress: UInt64 = 6
    /// bool — session resume support (opaque resume tokens).
    public static let resume: UInt64 = 7
    /// u32 ≥ 1152 — the largest datagram this end can handle
    /// (geometry ceiling). Agreed = min; the session STARTS at the
    /// 1152 B default regardless and may be renegotiated up to the
    /// agreed ceiling (the DPLPMTUD raise), at an IDR boundary only.
    public static let maxDatagramBytes: UInt64 = 8
    /// bool — the host can route desktop audio to a virtual sink and
    /// mute its own speakers for the session, honoring 0x18 flips
    /// (HS-18 → CL-13, promoted by the second codec-promotion slice).
    /// DELIBERATELY not a typed field of `Capabilities` in wire v1:
    /// key 9 rides the forward-compat spine through `unknownEntries`
    /// exactly as it shipped (one canonical `09 F5` map entry appended
    /// to the frozen v1 encoding — capabilities-v1.json never moves),
    /// surviving intersection only on mutual byte-equal declaration.
    /// Accessors in AudioRouting.swift; folding it into the typed
    /// fields is a wire-version discussion (the TLV fold-into-v2
    /// precedent), not a promotion.
    public static let hostAudioRouting: UInt64 = 9
    /// bool — this end speaks the v1 clipboard-text sync (CTRL
    /// 0x1A/0x1B on the ordered stream, CL-15 — the first H3
    /// feature). Rides the forward-compat spine through
    /// `unknownEntries` like key 9 (one canonical `0A F5` entry;
    /// capabilities-v1.json never moves), surviving intersection only
    /// on mutual byte-equal declaration. Deliberately NOT the
    /// featureChannels list (key 5, id 1) — that id promises the
    /// chan ≥ 8 feature-channel architecture, which v1 does not
    /// build. Accessors in Clipboard.swift. Declaration is dialect,
    /// not consent: sharing is gated locally on each end (design doc
    /// §6).
    public static let clipboardText: UInt64 = 10
    /// bool — this end speaks the v1 bulk-transfer channel (chan 8's
    /// ARQ ordered stream carrying the 0x1C–0x21 sextet, W10 / F-2 —
    /// the H3 file-transfer mechanism). Rides the forward-compat
    /// spine through `unknownEntries` like keys 9 and 10 (one
    /// canonical `0B F5` entry; capabilities-v1.json never moves),
    /// surviving intersection only on mutual byte-equal declaration.
    /// Deliberately NOT the featureChannels list (key 5, id 2): key
    /// 5's ids are typed-set members whose fold-in belongs to the D-5
    /// wire-version discussion, and this key gates the MECHANISM —
    /// features riding it (file drop now, clipboard-v2 images later)
    /// gate at the ends. Declaration is dialect, not consent: v1
    /// direction (client→host only) and the standing per-host toggle
    /// live in the end shells (design record 20260728-053300 §6).
    /// Accessors in BulkMessages.swift.
    public static let bulkTransfer: UInt64 = 11

    /// The renegotiable subset (transport pillar §4: "fixed after
    /// exchange except where a capability itself declares
    /// renegotiability"). Everything else is connect-time only and a
    /// CapabilityUpdate naming it rejects.
    public static let renegotiableKeys: Set<UInt64> = [maxDatagramBytes]
}

/// Video codec ids for the `videoCodecs` list. Only HEVC is assigned
/// in wire v1 — AV1 lands as a new id when it lands, and the list
/// carries unknown ids rather than rejecting them.
public enum CapabilityCodec {
    public static let hevc: UInt64 = 1
}

/// Chroma mode ids for the `chromaModes` list.
public enum CapabilityChroma {
    public static let yuv420: UInt64 = 1
    public static let yuv444: UInt64 = 2
}

/// Feature channel ids for the `featureChannels` list.
public enum CapabilityFeature {
    public static let clipboard: UInt64 = 1
    public static let fileTransfer: UInt64 = 2
    public static let printing: UInt64 = 3
}

/// One end's declared capability set, or the agreed intersection of
/// two. The typed fields are the v1 registry; `unknownEntries` carry
/// foreign keys verbatim (preserved through decode/encode, surviving
/// intersection only on byte-equal agreement).
public struct Capabilities: Hashable, Sendable {
    public var wireMinor: UInt16
    /// Canonical form for all three id lists: strictly ascending, no
    /// duplicates. Encode enforces it; decode rejects violations.
    public var videoCodecs: [UInt64]
    public var chromaModes: [UInt64]
    public var idleSilence: Bool
    public var featureChannels: [UInt64]
    public var audioExpress: Bool
    public var resume: Bool
    public var maxDatagramBytes: UInt32
    /// Registry-unknown map entries, key-ascending (the map's
    /// canonical order guarantees it). Every key here is outside the
    /// v1 registry.
    public var unknownEntries: [CborMapEntry]

    public init(
        wireMinor: UInt16,
        videoCodecs: [UInt64],
        chromaModes: [UInt64],
        idleSilence: Bool,
        featureChannels: [UInt64],
        audioExpress: Bool,
        resume: Bool,
        maxDatagramBytes: UInt32,
        unknownEntries: [CborMapEntry] = []
    ) {
        self.wireMinor = wireMinor
        self.videoCodecs = videoCodecs
        self.chromaModes = chromaModes
        self.idleSilence = idleSilence
        self.featureChannels = featureChannels
        self.audioExpress = audioExpress
        self.resume = resume
        self.maxDatagramBytes = maxDatagramBytes
        self.unknownEntries = unknownEntries
    }

    /// What this build of LyteWire declares: wire minor 0, HEVC,
    /// 4:2:0, idle silence on, no feature channels yet, no
    /// audio-express, no resume yet, the 1152 B bridge-safe ceiling.
    /// Shells extend from here as slices land.
    public static let wireDefault = Capabilities(
        wireMinor: 0,
        videoCodecs: [CapabilityCodec.hevc],
        chromaModes: [CapabilityChroma.yuv420],
        idleSilence: true,
        featureChannels: [],
        audioExpress: false,
        resume: false,
        maxDatagramBytes: UInt32(WireBudget.maxDatagramByteCount)
    )

    // MARK: - CBOR mapping

    /// The deterministic CBOR map. Throws on a non-canonical id list
    /// or a below-floor datagram ceiling — a Capabilities value that
    /// cannot encode is a construction bug, not wire input.
    public func encodeCbor() throws -> [UInt8] {
        for list in [videoCodecs, chromaModes, featureChannels] {
            guard isCanonicalIdList(list) else {
                throw CapabilityError.nonCanonicalIdList
            }
        }
        guard maxDatagramBytes >= UInt32(WireBudget.maxDatagramByteCount)
        else {
            throw CapabilityError.datagramCeilingBelowFloor(maxDatagramBytes)
        }
        var entries: [CborMapEntry] = [
            .init(
                key: .unsigned(CapabilityKey.wireMinor),
                value: .unsigned(UInt64(wireMinor))
            ),
            .init(
                key: .unsigned(CapabilityKey.videoCodecs),
                value: .array(videoCodecs.map(CborValue.unsigned))
            ),
            .init(
                key: .unsigned(CapabilityKey.chromaModes),
                value: .array(chromaModes.map(CborValue.unsigned))
            ),
            .init(
                key: .unsigned(CapabilityKey.idleSilence),
                value: .bool(idleSilence)
            ),
            .init(
                key: .unsigned(CapabilityKey.featureChannels),
                value: .array(featureChannels.map(CborValue.unsigned))
            ),
            .init(
                key: .unsigned(CapabilityKey.audioExpress),
                value: .bool(audioExpress)
            ),
            .init(
                key: .unsigned(CapabilityKey.resume),
                value: .bool(resume)
            ),
            .init(
                key: .unsigned(CapabilityKey.maxDatagramBytes),
                value: .unsigned(UInt64(maxDatagramBytes))
            ),
        ]
        entries.append(contentsOf: unknownEntries)
        return try Cbor.encode(.map(entries))
    }

    /// Decodes a peer declaration. Registry keys must carry their
    /// registered types (wrong type = the peer is broken, reject);
    /// wireMinor, videoCodecs, and chromaModes are REQUIRED (v1 always
    /// sends all eight; the other five default to "not supported" so a
    /// leaner future minor may omit them); unknown keys are preserved,
    /// never rejected.
    public static func decodeCbor(
        _ bytes: ArraySlice<UInt8>
    ) throws -> Capabilities {
        let value: CborValue
        do {
            value = try Cbor.decode(bytes)
        } catch let error as CborError {
            throw CapabilityError.malformedCbor(error)
        }
        guard case .map(let entries) = value else {
            throw CapabilityError.notAMap
        }

        var wireMinor: UInt16?
        var videoCodecs: [UInt64]?
        var chromaModes: [UInt64]?
        var idleSilence = false
        var featureChannels: [UInt64] = []
        var audioExpress = false
        var resume = false
        var maxDatagramBytes = UInt32(WireBudget.maxDatagramByteCount)
        var unknownEntries: [CborMapEntry] = []

        for entry in entries {
            guard case .unsigned(let key) = entry.key else {
                // Non-integer keys are outside the registry by
                // construction — foreign, preserved, ignored.
                unknownEntries.append(entry)
                continue
            }
            switch key {
            case CapabilityKey.wireMinor:
                guard case .unsigned(let v) = entry.value,
                      let minor = UInt16(exactly: v) else {
                    throw CapabilityError.wrongValueType(key: key)
                }
                wireMinor = minor
            case CapabilityKey.videoCodecs:
                videoCodecs = try decodeIdList(entry.value, key: key)
            case CapabilityKey.chromaModes:
                chromaModes = try decodeIdList(entry.value, key: key)
            case CapabilityKey.idleSilence:
                idleSilence = try decodeBool(entry.value, key: key)
            case CapabilityKey.featureChannels:
                featureChannels = try decodeIdList(entry.value, key: key)
            case CapabilityKey.audioExpress:
                audioExpress = try decodeBool(entry.value, key: key)
            case CapabilityKey.resume:
                resume = try decodeBool(entry.value, key: key)
            case CapabilityKey.maxDatagramBytes:
                guard case .unsigned(let v) = entry.value,
                      let ceiling = UInt32(exactly: v) else {
                    throw CapabilityError.wrongValueType(key: key)
                }
                guard ceiling >= UInt32(WireBudget.maxDatagramByteCount)
                else {
                    throw CapabilityError.datagramCeilingBelowFloor(ceiling)
                }
                maxDatagramBytes = ceiling
            default:
                unknownEntries.append(entry)
            }
        }

        guard let wireMinor else {
            throw CapabilityError.missingKey(CapabilityKey.wireMinor)
        }
        guard let videoCodecs else {
            throw CapabilityError.missingKey(CapabilityKey.videoCodecs)
        }
        guard let chromaModes else {
            throw CapabilityError.missingKey(CapabilityKey.chromaModes)
        }
        return Capabilities(
            wireMinor: wireMinor,
            videoCodecs: videoCodecs,
            chromaModes: chromaModes,
            idleSilence: idleSilence,
            featureChannels: featureChannels,
            audioExpress: audioExpress,
            resume: resume,
            maxDatagramBytes: maxDatagramBytes,
            unknownEntries: unknownEntries
        )
    }

    public static func decodeCbor(_ bytes: [UInt8]) throws -> Capabilities {
        try decodeCbor(bytes[...])
    }

    // MARK: - Intersection

    /// The agreed set: min/AND/set-∩ per field, unknown entries only
    /// on byte-equal agreement. Commutative and idempotent by
    /// construction (the W-G8 algebra); whether the result can carry a
    /// session is `CapabilityNegotiator`'s call, not this function's.
    public func intersecting(_ other: Capabilities) -> Capabilities {
        Capabilities(
            wireMinor: min(wireMinor, other.wireMinor),
            videoCodecs: intersectIdLists(videoCodecs, other.videoCodecs),
            chromaModes: intersectIdLists(chromaModes, other.chromaModes),
            idleSilence: idleSilence && other.idleSilence,
            featureChannels: intersectIdLists(
                featureChannels, other.featureChannels
            ),
            audioExpress: audioExpress && other.audioExpress,
            resume: resume && other.resume,
            maxDatagramBytes: min(maxDatagramBytes, other.maxDatagramBytes),
            unknownEntries: unknownEntries.filter {
                other.unknownEntries.contains($0)
            }
        )
    }
}

/// Everything the capability layer can refuse. Hostile bytes throw,
/// never trap.
public enum CapabilityError: Error, Hashable, Sendable {
    case malformedCbor(CborError)
    case notAMap
    case missingKey(UInt64)
    case wrongValueType(key: UInt64)
    /// An id list not strictly ascending / duplicate-free.
    case nonCanonicalIdList
    /// maxDatagramBytes below the 1152 B protocol floor.
    case datagramCeilingBelowFloor(UInt32)
}

// MARK: - Id-list helpers

private func isCanonicalIdList(_ ids: [UInt64]) -> Bool {
    zip(ids, ids.dropFirst()).allSatisfy { $0 < $1 }
}

private func decodeIdList(
    _ value: CborValue, key: UInt64
) throws -> [UInt64] {
    guard case .array(let items) = value else {
        throw CapabilityError.wrongValueType(key: key)
    }
    let ids = try items.map { item -> UInt64 in
        guard case .unsigned(let id) = item else {
            throw CapabilityError.wrongValueType(key: key)
        }
        return id
    }
    guard isCanonicalIdList(ids) else {
        throw CapabilityError.nonCanonicalIdList
    }
    return ids
}

private func decodeBool(_ value: CborValue, key: UInt64) throws -> Bool {
    guard case .bool(let b) = value else {
        throw CapabilityError.wrongValueType(key: key)
    }
    return b
}

/// Both inputs canonical ascending, so a linear merge-intersect keeps
/// the output canonical.
private func intersectIdLists(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    var out: [UInt64] = []
    var i = a.startIndex
    var j = b.startIndex
    while i < a.endIndex && j < b.endIndex {
        if a[i] == b[j] {
            out.append(a[i])
            i += 1
            j += 1
        } else if a[i] < b[j] {
            i += 1
        } else {
            j += 1
        }
    }
    return out
}
