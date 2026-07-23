// The NSPasteboard glue (CL-15, design doc
// docs/20260722-231500-lyte-clipboard.md §8) — deliberately thin:
// NSPasteboard has no change notification, so a ~200 ms `changeCount`
// poll watches for local copies while active, and `apply` writes host
// text and swallows its own bump. ALL policy (the negotiated/enabled
// gates, the loop-prevention book, the ceiling, the counters) lives in
// the sans-IO session core; this class only reads strings, applies
// strings, and keeps quiet about its own writes. Shared by the app's
// ConnectionModel and wire-view's --clipboard leg. Payloads never
// appear in logs here or anywhere.

import AppKit

public final class PasteboardSync: @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
    private let intervalMilliseconds: Int
    private let onLocalChange: @Sendable (String) -> Void

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
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

    private func poll() {
        lock.lock()
        let count = pasteboard.changeCount
        guard count != lastChangeCount else {
            lock.unlock()
            return
        }
        lastChangeCount = count
        // Read under the lock so an `apply` racing this poll cannot
        // interleave between the count check and the string read.
        let text = pasteboard.string(forType: .string)
        lock.unlock()
        guard let text, !text.isEmpty else { return }
        onLocalChange(text)
    }
}
