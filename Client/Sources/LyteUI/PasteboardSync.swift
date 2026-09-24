// The NSPasteboard glue (design doc
// docs/20260722-231500-lyte-clipboard.md §8) — deliberately thin:
// NSPasteboard has no change notification, so a ~200 ms `changeCount`
// poll watches for local copies while active, and `apply` writes host
// content and swallows its own bump. ALL policy (the negotiated/
// enabled gates, the loop-prevention book, the ceilings, the counters)
// lives in the sans-IO session core; this class only reads content,
// applies content, and keeps quiet about its own writes. Shared by the
// app's ConnectionModel and wire-view's --clipboard leg. Payloads
// never appear in logs here or anywhere.
//
// Images, when the images rung is on: text wins when a change carries
// both flavors (the host leaf's read order, mirrored); an image-only
// change (a screenshot, a "Copy Image") is read as PNG — transcoded from
// TIFF when the copying app never provided public.png, outside the lock
// — and handed to the image callback. `apply(imageData:)` writes the
// host's PNG and PROMISES a TIFF rendition (older AppKit paste targets
// ask for TIFF first), rendered only if a paste target asks, so a large
// host image never decodes on the caller's thread.

import AppKit

public final class PasteboardSync: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let intervalMilliseconds: Int
    private let onLocalChange: @Sendable (String) -> Void
    /// P-1: fired (on the poll queue) with PNG bytes when the user
    /// copies an image while the watcher is active AND the images
    /// rung is on. The session core judges it; this class never does.
    public var onLocalImageChange: (@Sendable ([UInt8]) -> Void)?

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    /// The images rung's local mirror: while false the poll never
    /// reads image flavors at all (consent-shaped, like `start`'s
    /// re-baseline — content the user never opted into sharing is
    /// never even read).
    private var imagesOn = false
    /// The last changeCount this class has accounted for — poll
    /// baseline AND the self-write swallow.
    private var lastChangeCount: Int
    /// The TIFF promise behind the last applied image; held so the
    /// promise outlives the pasteboard item's own bookkeeping.
    private var tiffPromise: TiffRendition?

    /// - Parameter onLocalChange: fired (on the poll queue) with the
    ///   pasteboard's string whenever the user copies while the
    ///   watcher is active. The session core judges it; this class
    ///   never does.
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

    /// Stops polling. The pasteboard is never read again until the
    /// next `start()` re-baselines.
    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Flips the images rung's local mirror (P-1). Consent-shaped
    /// like `start`: enabling re-baselines nothing — only changes
    /// AFTER the flip are read as images.
    public func setImagesEnabled(_ enabled: Bool) {
        lock.lock()
        imagesOn = enabled
        lock.unlock()
    }

    /// Applies host text to the pasteboard and swallows the resulting
    /// changeCount bump — the local half of loop prevention (the
    /// session core's book is the authoritative second guard). Known
    /// v1 gap, accepted in the design doc: a user copy racing this
    /// apply inside one poll window is superseded at the OS clipboard.
    public func apply(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    /// Applies a host clipboard image (sha-verified PNG bytes) and
    /// swallows its bump. The TIFF rendition is promised, not rendered:
    /// paste targets that never ask for public.png still get the image.
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

    private func poll() {
        lock.lock()
        let count = pasteboard.changeCount
        guard count != lastChangeCount else {
            lock.unlock()
            return
        }
        lastChangeCount = count
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
        lock.unlock()
        if let text, !text.isEmpty {
            onLocalChange(text)
        } else if let png = image?.pngBytes, !png.isEmpty {
            onLocalImageChange?(png)
        }
    }

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
