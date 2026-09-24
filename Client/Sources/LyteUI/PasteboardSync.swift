// The NSPasteboard glue (docs/decisions/20260722-231500-lyte-clipboard.md
// §8), deliberately thin: a ~200 ms `changeCount` poll watches for local
// copies while active, and `apply` writes host content and swallows its
// own bump. All policy lives in the sans-IO session core. Payloads never
// appear in logs.
//
// Images: text wins when a change carries both flavors; an image-only
// change is read as PNG (transcoded from TIFF outside the lock when
// needed). `apply(imageData:)` writes the host's PNG and promises a TIFF
// rendition, rendered only if a paste target asks.

import AppKit

public final class PasteboardSync: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let intervalMilliseconds: Int
    private let onLocalChange: @Sendable (String) -> Void
    /// Fired on the poll queue with PNG bytes when the user copies an
    /// image while the watcher is active and the images rung is on.
    public var onLocalImageChange: (@Sendable ([UInt8]) -> Void)?

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// While false the poll never reads image flavors at all.
    private var imagesOn = false
    /// The last changeCount this class has accounted for — poll
    /// baseline AND the self-write swallow.
    private var lastChangeCount: Int
    /// The TIFF promise behind the last applied image; held so the
    /// promise outlives the pasteboard item's own bookkeeping.
    private var tiffPromise: TiffRendition?

    /// - Parameter onLocalChange: fired on the poll queue with the
    ///   pasteboard's string whenever the user copies while active.
    public init(
        pasteboard: NSPasteboard = .general,
        intervalMilliseconds: Int = 200,
        onLocalChange: @escaping @Sendable (String) -> Void
    ) {
        self.pasteboard = pasteboard
        self.intervalMilliseconds = intervalMilliseconds
        self.onLocalChange = onLocalChange
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.cancel()
    }

    /// Begins polling. Consent-shaped: the baseline resets to NOW, so
    /// whatever sat on the pasteboard from before sharing was enabled
    /// is never read, let alone sent.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let source = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility))
        source.schedule(
            deadline: .now() + .milliseconds(intervalMilliseconds),
            repeating: .milliseconds(intervalMilliseconds))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    /// True while the watcher polls.
    public var isWatching: Bool { lock.withLock { timer != nil } }

    /// Stops polling. The pasteboard is never read again until the
    /// next `start()` re-baselines.
    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Flips the images rung's local mirror; only changes after the
    /// flip are read as images.
    public func setImagesEnabled(_ enabled: Bool) {
        lock.lock()
        imagesOn = enabled
        lock.unlock()
    }

    /// Applies host text and swallows the resulting changeCount bump —
    /// the local half of loop prevention (the session core's book is the
    /// second guard). A user copy racing this apply inside one poll
    /// window is superseded at the OS clipboard.
    public func apply(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    /// Applies a host clipboard image (sha-verified PNG) and swallows
    /// its bump. The TIFF rendition is promised, not rendered.
    public func apply(imageData: [UInt8]) {
        let png = Data(imageData)
        let promise = TiffRendition(png: png)
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setDataProvider(promise, forTypes: [.tiff])
        lock.lock()
        defer { lock.unlock() }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        tiffPromise = promise
        lastChangeCount = pasteboard.changeCount
    }

    /// One watcher tick; the timer drives it, tests call it directly.
    func poll() {
        lock.lock()
        let count = pasteboard.changeCount
        guard count != lastChangeCount else {
            lock.unlock()
            return
        }
        // A writer clears (bumping the count) and then writes under that
        // same count: an empty pasteboard is a write in progress, so look
        // again next poll instead of consuming the count.
        guard let types = pasteboard.types, !types.isEmpty else {
            lock.unlock()
            return
        }
        lastChangeCount = count
        // Password managers and secure-input apps mark what must not
        // travel (nspasteboard.org); consent to share the clipboard is
        // never consent to ship those.
        if types.contains(where: Self.privateMarkers.contains) {
            lock.unlock()
            return
        }
        // Read under the lock so an `apply` racing this poll cannot
        // interleave between the count check and the content read.
        let text = pasteboard.string(forType: .string)
        var image: ImageFlavor?
        if imagesOn, text?.isEmpty != false {
            if let png = pasteboard.data(forType: .png) {
                image = .png(png)
            } else if let tiff = pasteboard.data(forType: .tiff) {
                image = .tiff(tiff)
            }
        }
        // The count cannot see a rewrite under the same count; a marker
        // that appeared while reading still vetoes what was read.
        if pasteboard.changeCount != count
            || pasteboard.types?.contains(where: Self.privateMarkers.contains)
                == true
        {
            lock.unlock()
            return
        }
        lock.unlock()
        if let text, !text.isEmpty {
            onLocalChange(text)
        } else if let png = image?.pngBytes, !png.isEmpty {
            onLocalImageChange?(png)
        }
    }

    /// The nspasteboard.org markers for concealed (passwords), transient
    /// and auto-generated content. A change carrying any of them is never
    /// read.
    static let privateMarkers: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    /// The pasteboard's image as read: public.png verbatim when the
    /// copying app provided it (screenshots do), else TIFF (app-internal
    /// copies often give only that), transcoded after the lock is gone.
    private enum ImageFlavor {
        case png(Data)
        case tiff(Data)

        var pngBytes: [UInt8]? {
            switch self {
            case .png(let data):
                return Array(data)
            case .tiff(let data):
                return NSBitmapImageRep(data: data)?
                    .representation(using: .png, properties: [:])
                    .map(Array.init)
            }
        }
    }
}

/// Renders a PNG's TIFF flavor only when a paste target asks for it.
private final class TiffRendition: NSObject, NSPasteboardItemDataProvider,
    @unchecked Sendable
{
    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .tiff,
              let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation
        else { return }
        item.setData(tiff, forType: .tiff)
    }
}
