import Foundation
import LyteClientCore
import LyteTransport
import LyteUI
import LyteWire
import Synchronization
import UniformTypeIdentifiers

/// What the current wire session's capability agreement made available;
/// each control it gates exists exactly while its flag holds. Reset
/// whenever the session goes away.
struct NegotiatedFeatures: Equatable {
    /// Key 9: the host-speaker mute control.
    var hostAudioRouting = false
    /// Key 14 (mode 0x03): the wire audio-off control.
    var audioStreamOff = false
    /// Key 10: clipboard text sharing.
    var clipboardText = false
    /// Keys 10∧12: the clipboard images rung (a text-only host never
    /// declares key 12).
    var clipboardImages = false
    /// Key 11: the host's standing consent to receive dropped files.
    var bulkTransfer = false

    static let none = NegotiatedFeatures()
}

extension NegotiatedFeatures {
    init(_ agreed: Capabilities) {
        hostAudioRouting = agreed.hostAudioRouting
        audioStreamOff = agreed.audioStreamOff
        clipboardText = agreed.clipboardText
        clipboardImages = agreed.clipboardImagesAgreed
        bulkTransfer = agreed.bulkTransfer
    }
}

extension ConnectionModel {
    // MARK: - Host audio routing

    /// True when the 0x19-confirmed posture says the host's speakers are
    /// silent. The strip and the Actions menu render THIS — never the ask.
    var hostMuted: Bool { hostAudioPosture == .hostMuted }

    /// The wire is currently carrying no audio track at all.
    var hostAudioOff: Bool { hostAudioPosture == .streamOff }

    /// Asks the host to flip its own speakers (0x18). The toggle stays
    /// where the last 0x19 put it until the next one answers, so a failed
    /// flip visibly snaps back. A refusal is a teardown race — weather.
    func setHostMuted(_ muted: Bool) {
        guard negotiated.hostAudioRouting else { return }
        try? lyteSession?.core?.requestHostAudioRouting(muted ? .hostMuted : .hostAudible)
    }

    /// Mute-at-source: off → 0x03, the whole track leaves the wire; on →
    /// back to the last confirmed STREAMING posture. Same contract as
    /// setHostMuted — the button renders the 0x19 answer, never the ask.
    func setHostAudioOff(_ off: Bool) {
        guard negotiated.audioStreamOff else { return }
        try? lyteSession?.core?.requestHostAudioRouting(
            off ? .streamOff : lastStreamingAudioPosture)
    }

    // MARK: - Clipboard sharing

    /// The live consent toggle: flips the core's gate (nothing leaves,
    /// nothing lands, while off) and the watcher.
    func setClipboardSharing(_ enabled: Bool) {
        guard negotiated.clipboardText else { return }
        clipboardSharing = enabled
        lyteSession?.core?.setClipboardSharing(enabled)
        updatePasteboardWatcher()
    }

    /// The images rung's live toggle; images move only while text
    /// sharing is ALSO on — a tier, not a second channel.
    func setClipboardImageSharing(_ enabled: Bool) {
        guard negotiated.clipboardImages else { return }
        clipboardImageSharing = enabled
        lyteSession?.core?.setClipboardImageSharing(enabled)
        updatePasteboardWatcher()
    }

    /// The watcher polls exactly while consent AND capability hold — while
    /// off, the pasteboard is never even read; the images rung gates the
    /// watcher's image reads the same way.
    func updatePasteboardWatcher() {
        pasteboardSync?.setImagesEnabled(
            negotiated.clipboardImages && clipboardImageSharing)
        if negotiated.clipboardText, clipboardSharing, lyteSession != nil {
            pasteboardSync?.start()
        } else {
            pasteboardSync?.stop()
        }
    }

    /// One watcher per session, both flavors funneled into the core's
    /// judges.
    func makePasteboardSync(for lyte: LyteUdpSession) -> PasteboardSync {
        let sync = PasteboardSync(onLocalChange: { [weak lyte] text in
            lyte?.core?.shareLocalClipboard(text)
        })
        sync.onLocalImageChange = { [weak lyte] data in
            lyte?.core?.shareLocalClipboardImage(data)
        }
        return sync
    }

    // MARK: - Per-host preferences

    /// Start sessions with the host's speakers muted. Unset means muted
    /// (sound follows the viewer), so this reads `!= false` and writes
    /// both directions explicitly — unchecking is the "start audible"
    /// opt-out. Applied at the next connect; the live toggle overrides.
    var startHostMutedPreference: Bool {
        get { pinnedHost?.startHostAudioMuted != false }
        set {
            updatePin { $0.setStartHostAudioMuted(publicKeyHash: $1, muted: newValue) }
        }
    }

    /// Share the clipboard with this host by default (default off).
    var shareClipboardPreference: Bool {
        get { pinnedHost?.shareClipboard == true }
        set {
            updatePin {
                $0.setShareClipboard(publicKeyHash: $1, share: newValue ? true : nil)
            }
        }
    }

    /// Share clipboard images with this host by default.
    var shareClipboardImagesPreference: Bool {
        get { pinnedHost?.shareClipboardImages == true }
        set {
            updatePin {
                $0.setShareClipboardImages(publicKeyHash: $1, share: newValue ? true : nil)
            }
        }
    }

    /// Load–mutate–save against the pinned store for the streaming host,
    /// then refresh the in-memory snapshot. `mutate` returns false when
    /// nothing changed (the host is no longer pinned).
    func updatePin(_ mutate: (inout PinnedHostStore, String) -> Bool) {
        guard let pkh = hostPublicKeyHash else { return }
        var store = services.loadPins()
        guard mutate(&store, pkh) else { return }
        try? services.savePins(store)
        pinnedHost = store.host(publicKeyHash: pkh)
    }

    // MARK: - Chroma tier

    /// The Chroma control's verb: persist the per-host preference and
    /// reconnect cleanly with the new declaration — chroma is
    /// connect-time only, so a flip IS a re-dial. The dormant Better tier
    /// is refused here too (the control disables it; this is the model's
    /// own gate).
    func setChromaTier(_ tier: ChromaTier) {
        guard tier.isSelectable, tier != chromaTier else { return }
        chromaTier = tier
        updatePin { $0.setChromaTier(publicKeyHash: $1, tier: tier) }
        reconnectNow()
    }

    /// The typed negotiation failure's fate: `noCommonChromaMode` on a
    /// non-Good declaration re-dials at Good with the banner (the named
    /// degradation — never silent, never a hang); everything else stays
    /// the failure it is.
    func handleCapabilitiesFailure(_ failure: CapabilityNegotiationError) {
        let declared = chromaTier
        switch ChromaFallbackPolicy.verdict(declaredTier: declared, failure: failure) {
        case .redialAtGood where roaming != nil:
            // Live downgrade only — the per-host preference stands (the
            // host may gain the tier; the user said Best).
            chromaTier = .good
            showChromaNotice(
                "\(hostName ?? "The host") doesn't offer "
                    + "\(declared.displayName) (\(declared.samplingLabel)) "
                    + "— reconnecting at Good (4:2:0)")
            reconnectNow()
        case .redialAtGood, .fail:
            endLyteSession(reason: "capabilities failed: \(failure)")
        }
    }

    /// The non-modal fallback banner; fades on its own (longer than the
    /// bulk notice — it explains a whole reconnect).
    private func showChromaNotice(_ text: String) {
        chromaNotice = text
        chromaNoticeTask?.cancel()
        chromaNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.chromaNotice = nil
        }
    }

    // MARK: - Bulk transfer

    /// True while a transfer (or its queue) is worth a pill.
    var bulkActive: Bool { !bulkStatus.isIdle }

    /// One coordinator per HOST: reconnects to the same host keep it
    /// (resume); a different host abandons everything first (a dropped
    /// file's consent was for that host, nobody else).
    func prepareBulkCoordinator(hostKey: String) {
        if bulkCoordinatorHostKey == hostKey, bulkCoordinator != nil {
            return
        }
        bulkCoordinator?.abandonAll()
        bulkCoordinatorHostKey = hostKey
        // The coordinator reports every chunk ack; the pill needs at most
        // ten refreshes a second, and one pending hop at a time.
        let refresh = CoalescedMainActorHop(interval: .milliseconds(100)) {
            [weak self] in
            guard let self else { return }
            let snapshot = self.bulkCoordinator?.snapshot() ?? .idle
            if snapshot != self.bulkStatus { self.bulkStatus = snapshot }
        }
        bulkCoordinator = BulkSendCoordinator(
            onChange: { refresh.schedule() },
            onNotice: { [weak self] notice in
                Task { @MainActor [weak self] in self?.showBulkNotice(notice) }
            })
        bulkStatus = .idle
    }

    /// The stream view's drop handler: extract file URLs off the item
    /// providers (async), then judge. Returns whether the drag is worth
    /// accepting at all (any file-URL candidate while streaming); the
    /// capability verdict surfaces as a NOTICE after the drop — never a
    /// silent nothing.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !candidates.isEmpty, lyteSession != nil else { return false }
        Task { @MainActor [weak self] in
            var urls: [URL] = []
            for provider in candidates {
                if let url = await Self.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            self?.dropFiles(urls)
        }
        return true
    }

    /// The gating verdicts, spoken (multi-file drops queue and send
    /// serially — the coordinator's policy).
    func dropFiles(_ urls: [URL]) {
        guard !urls.isEmpty, let coordinator = bulkCoordinator else { return }
        switch coordinator.drop(urls: urls) {
        case .accepted:
            break   // the pill takes over
        case .hostNotAccepting:
            showBulkNotice(
                "\(hostName ?? "The host") isn't accepting files — "
                    + "enable file drops on the host")
        case .notConnected:
            showBulkNotice("Not connected — file not sent")
        }
    }

    /// The pill's × and the Actions menu item: cancel the active transfer
    /// AND the queue (cancel means stop sending).
    func cancelBulkTransfers() {
        bulkCoordinator?.cancelAll()
    }

    /// The pill's line for a chan-8 message the session refused to queue.
    nonisolated static func bulkSendRefusalNotice(_ error: any Error) -> String {
        switch error {
        case ArqSendError.queueFull:
            return "File transfer stalled — the send queue is full"
        case BulkChannelError.notNegotiated:
            return "File transfer stopped — the host no longer accepts files"
        default:
            return "File transfer stalled — send refused (\(error))"
        }
    }

    /// Transient verdict line under the pill; fades after a beat.
    func showBulkNotice(_ text: String) {
        bulkNotice = text
        bulkNoticeTask?.cancel()
        bulkNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.bulkNotice = nil
        }
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

/// Runs `body` on the MainActor at most once per `interval`, however
/// often `schedule()` is called from any thread: one hop is pending at a
/// time, and it reads the latest state when it runs.
final class CoalescedMainActorHop: Sendable {
    private let pending = Mutex(false)
    private let interval: Duration
    private let body: @MainActor @Sendable () -> Void

    init(interval: Duration, body: @escaping @MainActor @Sendable () -> Void) {
        self.interval = interval
        self.body = body
    }

    func schedule() {
        let alreadyPending = pending.withLock { pending in
            defer { pending = true }
            return pending
        }
        guard !alreadyPending else { return }
        Task { @MainActor [self] in
            try? await Task.sleep(for: interval)
            pending.withLock { $0 = false }
            body()
        }
    }
}
