// Clipboard text sync (CL-15, the first H3 feature —
// docs/20260722-231500-lyte-clipboard.md): the wire shapes of "copy on
// one machine, paste on the other", v1 scoped to UTF-8 text both ways.
// Both messages ride the ARQ ordered CTRL stream (group 0) — reliable,
// exactly-once, in-order, the input/audio-routing carriage argument
// verbatim; the ARQ sublayer segments and reassembles whole messages,
// so no clipboard-layer chunking exists.
//
// CAPABILITY CARRIAGE — the W7 forward-compat spine, the key-9
// precedent repeated: key 10 (CapabilityKey.clipboardText, bool) rides
// the declaration through `Capabilities.unknownEntries` as one
// canonical `0A F5` map entry and survives intersection only on mutual
// byte-equal declaration. ZERO frozen bytes move. Deliberately NOT the
// featureChannels list (key 5, id 1): that id promises the transport
// pillar's chan ≥ 8 feature-channel architecture, which v1 does not
// build — new semantics, new key (rule 3 as designed).
//
// ClipboardSet (0x1A), client→host: "make this the host clipboard."
// ClipboardAnnounce (0x1B), host→client: "the host clipboard changed;
// this is its content." Same body, two types — direction-typed keeps
// the role-confusion drop loud (the 0x18/0x19 precedent). Layout:
//
//   offset size field
//   0      1    type   0x1A / 0x1B
//   1      …    text   UTF-8 bytes, the sole trailing field
//                      (self-delimiting — the ARQ message boundary is
//                      the length, the RetryHandshake1 precedent)
//
// Validation at encode AND decode: ≤ 65,536 UTF-8 bytes (the ARQ
// receive window and the shared-with-input ordered stream size the
// ceiling — design doc §3), valid UTF-8 (byte-exact re-encode, the
// CBOR text rule), non-empty (v1 does not sync clearing; a bare type
// byte is a zero-fill-adjacent bug to surface). Truncation and foreign
// type bytes reject with what they found. Never traps on hostile bytes.

/// The clipboard sync layer's fixed numbers (wire v1).
public enum ClipboardWire {
    /// The v1 text ceiling, UTF-8 bytes. Over-ceiling LOCAL copies are
    /// suppressed and counted, never sent (routine weather);
    /// over-ceiling WIRE bytes reject (the peer broke the contract).
    public static let maxTextByteCount = 65_536
}

// MARK: - The capability spine helpers

extension Capabilities {
    /// The key-10 entry as it rides the wire: CBOR bool under unsigned
    /// key 10 (`0A F5` inside the map) — one canonical byte image is
    /// what makes the intersection's byte-equal rule an exact AND.
    private static var clipboardTextEntry: CborMapEntry {
        CborMapEntry(
            key: .unsigned(CapabilityKey.clipboardText),
            value: .bool(true)
        )
    }

    /// True when this set (a declaration or an agreed intersection)
    /// carries `clipboardText: true`. On a v1 build the key lives in
    /// `unknownEntries` — which is exactly what makes it survive
    /// intersection only on mutual declaration. A `false` or
    /// wrongly-typed value reads as absent: absence and refusal are
    /// the same posture ("not supported"), per the spine's rule 3.
    public var clipboardText: Bool {
        unknownEntries.contains(Self.clipboardTextEntry)
    }

    /// A copy of this set declaring clipboard-text support.
    /// Idempotent; the CBOR encoder owns canonical key order, so the
    /// entry may append here regardless of surrounding keys.
    public func declaringClipboardText() -> Capabilities {
        guard !clipboardText else { return self }
        var declared = self
        declared.unknownEntries.append(Self.clipboardTextEntry)
        return declared
    }
}

// MARK: - The CTRL codecs

/// The client's clipboard push (type 0x1A).
public struct ClipboardSet: Hashable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }

    /// Throws on empty or over-ceiling text — a value that cannot
    /// encode is the caller's suppression verdict, not wire input.
    public func encode() throws -> [UInt8] {
        try encodeClipboardBody(
            type: CtrlMessageType.clipboardSet, text: text
        )
    }

    /// Decodes a whole ARQ-delivered message (type byte first). Throws
    /// on the wrong type, truncation, empty text, an over-ceiling
    /// body, and invalid UTF-8; never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> ClipboardSet {
        ClipboardSet(text: try decodeClipboardBody(
            payload, type: CtrlMessageType.clipboardSet
        ))
    }

    public static func decode(_ payload: [UInt8]) throws -> ClipboardSet {
        try decode(payload[...])
    }
}

/// The host's clipboard-change report (type 0x1B).
public struct ClipboardAnnounce: Hashable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public func encode() throws -> [UInt8] {
        try encodeClipboardBody(
            type: CtrlMessageType.clipboardAnnounce, text: text
        )
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> ClipboardAnnounce {
        ClipboardAnnounce(text: try decodeClipboardBody(
            payload, type: CtrlMessageType.clipboardAnnounce
        ))
    }

    public static func decode(_ payload: [UInt8]) throws -> ClipboardAnnounce {
        try decode(payload[...])
    }
}

public enum ClipboardMessageError: Error, Equatable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    /// v1 does not sync clearing — an empty body is a bug to surface.
    case emptyText
    /// UTF-8 byte count past the 65,536 B ceiling.
    case textOverBudget(Int)
    /// Bytes that are not valid UTF-8 (detected by byte-exact
    /// re-encode of the decoded string — the CBOR text rule).
    case invalidUtf8
}

/// Both messages share the `type ‖ utf8` shape.
private func encodeClipboardBody(
    type: UInt8, text: String
) throws -> [UInt8] {
    let utf8 = Array(text.utf8)
    guard !utf8.isEmpty else {
        throw ClipboardMessageError.emptyText
    }
    guard utf8.count <= ClipboardWire.maxTextByteCount else {
        throw ClipboardMessageError.textOverBudget(utf8.count)
    }
    return [type] + utf8
}

private func decodeClipboardBody(
    _ payload: ArraySlice<UInt8>, type: UInt8
) throws -> String {
    guard let first = payload.first else {
        throw ClipboardMessageError.truncatedMessage
    }
    guard first == type else {
        throw ClipboardMessageError.unexpectedType(first)
    }
    let body = payload.dropFirst()
    guard !body.isEmpty else {
        throw ClipboardMessageError.emptyText
    }
    guard body.count <= ClipboardWire.maxTextByteCount else {
        throw ClipboardMessageError.textOverBudget(body.count)
    }
    let text = String(decoding: body, as: UTF8.self)
    guard text.utf8.count == body.count,
          text.utf8.elementsEqual(body) else {
        throw ClipboardMessageError.invalidUtf8
    }
    return text
}

// MARK: - Loop prevention: the sync book

/// A local clipboard change's verdict (design doc §5).
public enum ClipboardLocalChangeVerdict: Equatable, Sendable {
    /// A genuine local change — share it (and call `noteShared` once
    /// it actually left).
    case share
    /// The OS reporting our own remote apply back — suppressed, the
    /// matching ring entry consumed (a deliberate later re-copy of the
    /// same text still syncs).
    case suppressEcho
    /// Identical to the last text we shared — the peer already holds
    /// it (dedupe).
    case suppressDuplicate
}

/// The loop-prevention/dedupe books both ends run identically (LYTE-PLAN
/// §5's content-suppression discipline as one sans-IO value type): a
/// remote set applied to the OS clipboard fires the OS's own change
/// signal, and without these books each end would announce the peer's
/// write back forever. The proof obligation — "a set must not
/// boomerang" — is pinned by tests on all three levels.
public struct ClipboardSyncBook: Hashable, Sendable {
    /// Recently-applied remote texts whose OS change signal has not
    /// fired yet (UTF-8 bytes; newest last, oldest evicted).
    private var appliedFromRemote: [[UInt8]] = []
    /// The last text we genuinely shared — the dedupe slot.
    private var lastShared: [UInt8]?
    /// Ring capacity: rapid successive remote applies each owe one
    /// echo suppression; 8 covers any realistic pileup between OS
    /// change signals.
    public let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    /// A remote set/announce was accepted for application. Remembers
    /// it for echo suppression and clears the dedupe slot — the peer's
    /// clipboard has moved past whatever we last sent, so re-sharing
    /// that text later is legitimate again.
    public mutating func noteRemoteApplied(_ text: String) {
        appliedFromRemote.append(Array(text.utf8))
        if appliedFromRemote.count > capacity {
            appliedFromRemote.removeFirst(
                appliedFromRemote.count - capacity
            )
        }
        lastShared = nil
    }

    /// The watcher's verdict for one local clipboard change.
    /// Echo matches consume their ring entry (consume-once).
    public mutating func admitLocalChange(
        _ text: String
    ) -> ClipboardLocalChangeVerdict {
        let bytes = Array(text.utf8)
        if let index = appliedFromRemote.firstIndex(of: bytes) {
            appliedFromRemote.remove(at: index)
            return .suppressEcho
        }
        if bytes == lastShared {
            return .suppressDuplicate
        }
        return .share
    }

    /// A local change actually left on the wire. Sets the dedupe slot
    /// and clears the echo ring: once the local clipboard genuinely
    /// moved on, no earlier apply can echo anymore — and keeping stale
    /// entries would wrongly suppress a deliberate future re-copy.
    public mutating func noteShared(_ text: String) {
        lastShared = Array(text.utf8)
        appliedFromRemote.removeAll()
    }
}
