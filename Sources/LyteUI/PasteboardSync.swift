// The NSPasteboard glue (CL-15, design doc
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
// P-1 (clipboard v2): the poll now sees IMAGES too, when the images
// rung is on. Text wins when a change carries both flavors (the host
// leaf's read order, mirrored); an image-only change (a screenshot,
// a "Copy Image") is read as PNG — transcoded from TIFF through
// NSBitmapImageRep when the promising app never provided public.png —
// and handed to the image callback. `apply(imageData:)` writes the
// host's PNG plus a TIFF rendition (older AppKit paste targets ask
// for TIFF first) and swallows the bump the same way text does.

import AppKit

public final class PasteboardSync: @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
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

    /// - Parameter onLocalChange: fired (on the poll queue) with the
    ///   pasteboard's string whenever the user copies while the
    ///   watcher is active. The session core judges it; this class
    ///   never does.
    public init(
        intervalMilliseconds: Int = 200,
        onLocalChange: @escaping @Sendable (String) -> Void
    ) {
        self.intervalMilliseconds = intervalMilliseconds
        self.onLocalChange = onLocalChange
        self.lastChangeCount = pasteboard.changeCount
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

    /// P-1: applies a host clipboard image (sha-verified PNG bytes)
    /// and swallows its bump. A TIFF rendition rides along so paste
    /// targets that never ask for public.png still see the image.
    public func apply(imageData: [UInt8]) {
        let png = Data(imageData)
        let tiff = NSBitmapImageRep(data: png)?
            .tiffRepresentation
        lock.lock()
        defer { lock.unlock() }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff {
            pasteboard.setData(tiff, forType: .tiff)
        }
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
        var image: [UInt8]?
        if imagesOn, text?.isEmpty != false {
            image = Self.readPngBytes(from: pasteboard)
        }
        lock.unlock()
        if let text, !text.isEmpty {
            onLocalChange(text)
        } else if let image, !image.isEmpty {
            onLocalImageChange?(image)
        }
    }

    /// The pasteboard's image as PNG bytes: public.png verbatim when
    /// the promising app provided it, else the TIFF flavor transcoded
    /// (screenshots give PNG; app-internal copies often give TIFF
    /// only). Nil when no image flavor is present at all.
    private static func readPngBytes(
        from pasteboard: NSPasteboard
    ) -> [UInt8]? {
        if let png = pasteboard.data(forType: .png) {
            return Array(png)
        }
        guard
            let tiff = pasteboard.data(forType: .tiff),
            let png = NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:])
        else { return nil }
        return Array(png)
    }
}
