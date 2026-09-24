// Clipboard text sync (docs/decisions/20260722-231500-lyte-clipboard.md):
// UTF-8 text both ways on the ARQ ordered CTRL stream, which segments and
// reassembles whole messages, so there is no clipboard-layer chunking.
// Gated by capability key 10 (clipboardText) through `unknownEntries`.
//
// ClipboardSet (0x1A), client→host: "make this the host clipboard."
// ClipboardAnnounce (0x1B), host→client: "the host clipboard changed;
// this is its content." Same body, two types, so a role-confused message
// is dropped loudly. Layout:
//
//   offset size field
//   0      1    type   0x1A / 0x1B
//   1      …    text   UTF-8 bytes, the sole trailing field (the ARQ
//                      message boundary is the length)
//
// Encode and decode both enforce ≤ 65,536 UTF-8 bytes, valid UTF-8 and
// non-empty (clearing is not synced). Truncation and foreign type bytes
// throw with what they found. Never traps on hostile bytes.

/// The clipboard sync layer's fixed numbers (wire v1).
public enum ClipboardWire {
    /// The text ceiling, UTF-8 bytes. Over-ceiling LOCAL copies are
    /// suppressed and counted, never sent (routine weather);
    /// over-ceiling WIRE bytes reject (the peer broke the contract).
    public static let maxTextByteCount = 65_536
}

// MARK: - The capability spine helpers

extension Capabilities {
    /// True when this set carries `clipboardText: true` (key 10) — see
    /// `declaresFlag(_:)`.
    public var clipboardText: Bool {
        declaresFlag(CapabilityKey.clipboardText)
    }

    /// A copy of this set declaring `clipboardText`.
    public func declaringClipboardText() -> Capabilities {
        declaringFlag(CapabilityKey.clipboardText)
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
    /// Bytes that are not valid UTF-8.
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
    guard let text = String(validating: body, as: UTF8.self) else {
        throw ClipboardMessageError.invalidUtf8
    }
    return text
}

// MARK: - Loop prevention: the sync book

/// A local clipboard change's verdict.
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

/// The loop-prevention/dedupe books both ends run identically: a remote
/// set applied to the OS clipboard fires the OS's own change signal, and
/// without these books each end would announce the peer's write back
/// forever.
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
        noteRemoteApplied(bytes: Array(text.utf8))
    }

    /// The watcher's verdict for one local clipboard change.
    /// Echo matches consume their ring entry (consume-once).
    public mutating func admitLocalChange(
        _ text: String
    ) -> ClipboardLocalChangeVerdict {
        admitLocalChange(bytes: Array(text.utf8))
    }

    /// A local change actually left on the wire. Sets the dedupe slot
    /// and clears the echo ring: once the local clipboard genuinely
    /// moved on, no earlier apply can echo anymore — and keeping stale
    /// entries would wrongly suppress a deliberate future re-copy.
    public mutating func noteShared(_ text: String) {
        noteShared(bytes: Array(text.utf8))
    }

    // MARK: Byte-keyed entries

    // One book serves text AND images, so a remote image apply clears the
    // text dedupe slot too. Text keys are the UTF-8 bytes; image keys are
    // `ClipboardImageWire.bookKey(sha256:)` = 0xFF ‖ digest, and 0xFF is
    // never valid UTF-8, so the key spaces cannot collide.

    /// The byte-keyed form of `noteRemoteApplied`.
    public mutating func noteRemoteApplied(bytes: [UInt8]) {
        appliedFromRemote.append(bytes)
        if appliedFromRemote.count > capacity {
            appliedFromRemote.removeFirst(
                appliedFromRemote.count - capacity
            )
        }
        lastShared = nil
    }

    /// The byte-keyed form of `admitLocalChange`.
    public mutating func admitLocalChange(
        bytes: [UInt8]
    ) -> ClipboardLocalChangeVerdict {
        if let index = appliedFromRemote.firstIndex(of: bytes) {
            appliedFromRemote.remove(at: index)
            return .suppressEcho
        }
        if bytes == lastShared {
            return .suppressDuplicate
        }
        return .share
    }

    /// The byte-keyed form of `noteShared`.
    public mutating func noteShared(bytes: [UInt8]) {
        lastShared = bytes
        appliedFromRemote.removeAll()
    }
}
