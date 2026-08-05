import LyteWire

/// One local clipboard change's policy outcome. Platform shells add
/// `sendRefused` only when executing an otherwise-admitted wire decision.
public enum ClipboardShareOutcome: Hashable, Sendable {
    case shared
    case suppressedEcho
    case suppressedDuplicate
    case suppressedBusy
    case sharingDisabled
    case notNegotiated
    case overBudget(Int)
    case sendRefused(String)
}

/// A client-role clipboard fact for a platform shell to project. Image-channel
/// `.send` events never appear here; they are separated into `outboundBulk`.
public enum ClientClipboardSessionEvent: Hashable, Sendable {
    case textChanged(String)
    case malformedTextAnnounce
    case unnegotiatedTextAnnounce
    case textIgnoredDisabled(byteCount: Int)
    case roleConfusedTextSet
    case malformedImageCargo(byteCount: Int)
    case unnegotiatedImageCargo
    case image(ClipboardImageEvent)
}

/// One IO-free clipboard decision. Reliable bytes ride CTRL; bulk bytes ride
/// the clipboard/file channel. The shell performs those sends and applies only
/// the typed events returned here.
public struct ClientClipboardSessionDecision: Hashable, Sendable {
    public let outboundReliable: [[UInt8]]
    public let outboundBulk: [[UInt8]]
    public let events: [ClientClipboardSessionEvent]
    public let shareOutcome: ClipboardShareOutcome?

    public init(
        outboundReliable: [[UInt8]] = [],
        outboundBulk: [[UInt8]] = [],
        events: [ClientClipboardSessionEvent] = [],
        shareOutcome: ClipboardShareOutcome? = nil
    ) {
        self.outboundReliable = outboundReliable
        self.outboundBulk = outboundBulk
        self.events = events
        self.shareOutcome = shareOutcome
    }
}

/// IO-free client clipboard policy shared by every platform shell. It owns
/// consent, capability gates, text and image echo suppression, bounded image
/// lane state, role direction, and wire encoding. Randomness and hashing enter
/// as value inputs; pasteboards and ordered-stream sends remain shell IO.
public struct ClientClipboardSession: Sendable {
    private var textSharingOn: Bool
    private var imageSharingOn: Bool
    private var book = ClipboardSyncBook()
    private var imageChannel: ClipboardImageChannel

    public init(
        textSharingAtStart: Bool,
        imageSharingAtStart: Bool,
        imageByteCeiling: Int = ClipboardImageWire.maxImageByteCount
    ) {
        textSharingOn = textSharingAtStart
        imageSharingOn = imageSharingAtStart
        imageChannel = ClipboardImageChannel(
            imageByteCeiling: imageByteCeiling)
    }

    public var isTextSharingEnabled: Bool { textSharingOn }
    public var isImageSharingEnabled: Bool {
        textSharingOn && imageSharingOn
    }
    public var imageCounters: ClipboardImageChannelCounters {
        imageChannel.counters
    }

    public mutating func setTextSharing(_ enabled: Bool) {
        textSharingOn = enabled
    }

    public mutating func setImageSharing(_ enabled: Bool) {
        imageSharingOn = enabled
    }

    /// Judges and encodes one local text change. The shell must call
    /// `noteLocalTextSent` only after the returned word was accepted by its
    /// reliable endpoint.
    public mutating func shareLocalText(
        _ text: String,
        agreed: Capabilities?
    ) -> ClientClipboardSessionDecision {
        guard agreed?.clipboardText == true else {
            return ClientClipboardSessionDecision(
                shareOutcome: .notNegotiated)
        }
        guard textSharingOn else {
            return ClientClipboardSessionDecision(
                shareOutcome: .sharingDisabled)
        }
        switch book.admitLocalChange(text) {
        case .suppressEcho:
            return ClientClipboardSessionDecision(
                shareOutcome: .suppressedEcho)
        case .suppressDuplicate:
            return ClientClipboardSessionDecision(
                shareOutcome: .suppressedDuplicate)
        case .share:
            break
        }
        guard let bytes = try? ClipboardSet(text: text).encode() else {
            return ClientClipboardSessionDecision(
                shareOutcome: .overBudget(text.utf8.count))
        }
        return ClientClipboardSessionDecision(
            outboundReliable: [bytes],
            shareOutcome: .shared)
    }

    public mutating func noteLocalTextSent(_ text: String) {
        book.noteShared(text)
    }

    /// Handles only the two reliable clipboard-text words. A client-bound set
    /// is role confusion regardless of whether its body would decode.
    public mutating func receiveReliable(
        _ bytes: [UInt8],
        agreed: Capabilities?
    ) -> ClientClipboardSessionEvent? {
        switch bytes.first {
        case CtrlMessageType.clipboardSet:
            return .roleConfusedTextSet

        case CtrlMessageType.clipboardAnnounce:
            guard let announce = try? ClipboardAnnounce.decode(bytes) else {
                return .malformedTextAnnounce
            }
            guard agreed?.clipboardText == true else {
                return .unnegotiatedTextAnnounce
            }
            guard textSharingOn else {
                return .textIgnoredDisabled(
                    byteCount: announce.text.utf8.count)
            }
            book.noteRemoteApplied(announce.text)
            return .textChanged(announce.text)

        default:
            return nil
        }
    }

    /// Judges one local PNG copy and advances the bounded image lane. The
    /// caller supplies the digest and transfer-id randomness.
    public mutating func shareLocalImage(
        _ data: [UInt8],
        sha256: [UInt8],
        rng: inout some RandomNumberGenerator,
        agreed: Capabilities?
    ) -> ClientClipboardSessionDecision {
        guard agreed?.clipboardImagesAgreed == true else {
            return ClientClipboardSessionDecision(
                shareOutcome: .notNegotiated)
        }
        guard textSharingOn, imageSharingOn else {
            return ClientClipboardSessionDecision(
                shareOutcome: .sharingDisabled)
        }
        return interpretImageEvents(imageChannel.shareLocalImage(
            data, sha256: sha256, book: &book, rng: &rng
        ))
    }

    /// Routes a clipboard-image marker through capability, consent, MIME, and
    /// receive-lane policy. The following offer remains claimed even when the
    /// marker is declined, so it cannot leak into the file-transfer lane.
    public mutating func receiveImageCargo(
        _ bytes: [UInt8],
        agreed: Capabilities?
    ) -> ClientClipboardSessionDecision {
        guard let cargo = try? ClipboardImageCargo.decode(bytes) else {
            return ClientClipboardSessionDecision(events: [
                .malformedImageCargo(byteCount: bytes.count),
            ])
        }
        guard agreed?.clipboardImagesAgreed == true else {
            return ClientClipboardSessionDecision(events: [
                .unnegotiatedImageCargo,
            ])
        }
        let events = textSharingOn && imageSharingOn
            ? imageChannel.ingestCargo(cargo)
            : imageChannel.declineCargo(cargo)
        return interpretImageEvents(events)
    }

    public func claimsBulk(_ message: BulkMessage) -> Bool {
        imageChannel.claims(message)
    }

    /// Advances one already-claimed image-lane message. Hashing is injected so
    /// the session package remains mechanism-free and deterministic in tests.
    public mutating func receiveBulk(
        _ message: BulkMessage,
        sha256: ([UInt8]) -> [UInt8]
    ) -> ClientClipboardSessionDecision {
        interpretImageEvents(imageChannel.ingest(
            message, book: &book, sha256: sha256))
    }

    private func interpretImageEvents(
        _ imageEvents: [ClipboardImageEvent]
    ) -> ClientClipboardSessionDecision {
        var outboundBulk: [[UInt8]] = []
        var events: [ClientClipboardSessionEvent] = []
        var outcome: ClipboardShareOutcome?
        for event in imageEvents {
            switch event {
            case .send(let bytes):
                outboundBulk.append(bytes)
            case .shareStarted:
                outcome = .shared
                events.append(.image(event))
            case .suppressed(let reason):
                switch reason {
                case .loopEcho: outcome = .suppressedEcho
                case .duplicate: outcome = .suppressedDuplicate
                case .sendBusy: outcome = .suppressedBusy
                case .overBudget(let count): outcome = .overBudget(count)
                case .emptyImage: outcome = .overBudget(0)
                }
                events.append(.image(event))
            default:
                events.append(.image(event))
            }
        }
        return ClientClipboardSessionDecision(
            outboundBulk: outboundBulk,
            events: events,
            shareOutcome: outcome)
    }
}
