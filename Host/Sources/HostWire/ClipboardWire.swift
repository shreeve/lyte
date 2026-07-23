// The host clipboard seam (CL-15, design doc
// docs/20260722-231500-lyte-clipboard.md §7): the Swift-side boundary
// the future Wayland/portal C leaf drives. The session core is already
// complete against this seam — a `.clipboardSetReceived` event is the
// shell's cue to call `apply(text:)`, and every leaf-reported change
// (genuine host copies AND the echoes of our own applies — the
// session's sync book tells them apart) flows back through
// `Session.noteHostClipboardChanged`.
//
// The real leaf is Linux-only, out of this slice's scope, and QUEUED
// as follow-up work (HANDOFF): the primary plan is the portal
// Clipboard API attached to the existing RemoteDesktop session (host
// build plan §6 — selection-change signals + fd-based transfer both
// directions; `wl-clipboard` is NOT a real fallback on GNOME, no
// wlr-data-control). The gate tests run a scripted implementation of
// this protocol; lyte-host wires the real one when it exists and
// declares capability key 10 only when the leaf is enabled (the
// key-9/--no-audio precedent — declaration follows the leaf).

/// What a host clipboard leaf owes the shell. Threading is the
/// shell's concern (the leaf's signals arrive on its own loop; the
/// shell marshals onto the session's), text is always whole UTF-8 —
/// v1 syncs text only, and never clearing.
public protocol HostClipboardLeaf: AnyObject {
    /// Fired for every OS clipboard change the leaf observes,
    /// including the ones `apply(text:)` itself causes — the session's
    /// sync book suppresses those; the leaf stays dumb by design.
    var onLocalChange: ((String) -> Void)? { get set }

    /// Make `text` the OS clipboard's content (a client 0x1A landing).
    func apply(text: String)

    /// Begin observing (the portal selection-change subscription).
    func start() throws

    /// Stop observing and release the OS resources.
    func stop()
}
