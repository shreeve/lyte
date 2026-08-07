// The host clipboard seam (CL-15, design doc
// docs/20260722-231500-lyte-clipboard.md §7): the Swift-side boundary
// the future Wayland/portal C leaf drives. The session core is already
// complete against this seam — a `.clipboardSetReceived` event is the
// shell's cue to call `apply(text:)`, and every leaf-reported change
// (genuine host copies AND the echoes of our own applies — the
// session's sync book tells them apart) flows back through
// `Session.noteHostClipboardChanged`.
//
// The real leaf EXISTS as of HS-19 (`MutterClipboardLeaf` in
// lyte-host, Linux-only): the RemoteDesktop-session clipboard API of
// host build plan §6 — selection-change signals + fd-based transfer
// both directions — driven on a Mutter-internal RemoteDesktop session
// (org.gnome.Mutter.RemoteDesktop). Portal RD Start still auto-denies
// headless on GNOME; a Wayland-helper / data-control leaf is blocked
// there — docs/20260807-015743-wayland-clipboard-gnome-blocker.md.
// The gate tests still run a scripted implementation of this protocol
// everywhere; lyte-host wires the real one behind `--clipboard` and
// declares capability key 10 only when the leaf came up (the
// key-9/--no-audio precedent — declaration follows the leaf).

import LyteWire

/// The v1 text-flavor policy the Linux leaf runs (HS-19) — pure and
/// platform-neutral so the seam tests pin it everywhere. Selection
/// owners advertise mime types; v1 syncs UTF-8 text only, so the leaf
/// reads exactly one flavor (the most faithful one offered) and offers
/// the standard trio when it owns the selection. `UTF8_STRING` is the
/// X11-era target Xwayland clients still speak; matching is
/// case-insensitive (mime types compare that way), and the OFFERED
/// spelling is returned so the read request echoes the owner's own
/// words.
public enum ClipboardTextMime {
    /// The canonical v1 flavor: whole UTF-8, no transcoding guesswork.
    public static let utf8 = "text/plain;charset=utf-8"

    /// What the leaf advertises when a client 0x1A makes it the
    /// selection owner — faithful flavor first.
    public static let offered = [utf8, "text/plain", "UTF8_STRING"]

    /// Read preference against a foreign owner's advertisement:
    /// explicit UTF-8, then the UTF-8-by-convention X11 target, then
    /// bare text/plain (read as UTF-8; a lossy decode is the honest
    /// remainder).
    public static let readPreference = [utf8, "UTF8_STRING", "text/plain"]

    /// The flavor to SelectionRead from `offeredByOwner`, or nil when
    /// the owner holds nothing v1 can carry (images, rich flavors —
    /// ignored, never an error).
    public static func pickForRead(
        fromOffered offeredByOwner: [String]
    ) -> String? {
        for want in readPreference {
            let lowered = want.lowercased()
            if let hit = offeredByOwner.first(
                where: { $0.lowercased() == lowered }
            ) {
                return hit
            }
        }
        return nil
    }
}

/// The v2 image-flavor policy (P-1, clipboard v2) — pure and
/// platform-neutral like the text policy above. v2 carries PNG only
/// (`ClipboardImageWire.acceptedMimes`); TEXT ALWAYS WINS when an
/// owner offers both (a spreadsheet cell copy advertises text and an
/// image render — the text is what the human copied; a screenshot
/// offers image/png alone and lands here). Formats append in Wire's
/// list and this policy follows with zero change.
public enum ClipboardImageFlavor {
    /// What the leaf advertises when it owns the selection with image
    /// cargo (a client image landing).
    public static let offered = [ClipboardImageWire.pngMime]

    /// The flavor to SelectionRead from `offeredByOwner`, or nil when
    /// the owner holds no image v2 can carry. Only consulted AFTER
    /// the text policy answered nil, and only when the images tier is
    /// on. Case-insensitive; the OFFERED spelling is returned (the
    /// read request echoes the owner's own words).
    public static func pickForRead(
        fromOffered offeredByOwner: [String]
    ) -> String? {
        for want in ClipboardImageWire.acceptedMimes {
            if let hit = offeredByOwner.first(
                where: { $0.lowercased() == want }
            ) {
                return hit
            }
        }
        return nil
    }
}

/// What a host clipboard leaf owes the shell. Threading is the
/// shell's concern (the leaf's signals arrive on its own loop; the
/// shell marshals onto the session's), text is always whole UTF-8 —
/// text sync never carries clearing. P-1 adds the image half: a
/// text-only tier simply never fires the image signal and never
/// receives an image apply (the session's keys-10∧12 gate holds
/// upstream either way).
public protocol HostClipboardLeaf: AnyObject {
    /// Fired for every OS clipboard TEXT change the leaf observes,
    /// including the ones `apply(text:)` itself causes — the session's
    /// sync book suppresses those; the leaf stays dumb by design.
    var onLocalChange: ((String) -> Void)? { get set }

    /// P-1: fired for every OS clipboard IMAGE change the leaf
    /// observes (whole PNG bytes — the one v2 read flavor), echoes of
    /// `apply(imageData:)` included; the same book suppresses those.
    var onLocalImageChange: (([UInt8]) -> Void)? { get set }

    /// Make `text` the OS clipboard's content (a client 0x1A landing).
    func apply(text: String)

    /// P-1: make the PNG bytes the OS clipboard's content (a
    /// sha-verified client image landing).
    func apply(imageData: [UInt8])

    /// Begin observing (the portal selection-change subscription).
    func start() throws

    /// Stop observing and release the OS resources.
    func stop()
}
