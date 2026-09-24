// The host clipboard seam. A `.clipboardSetReceived` event is the shell's
// cue to call `apply(text:)`; every leaf-reported change (genuine host
// copies AND echoes of our own applies — the session's sync book tells
// them apart) flows back through `Session.noteHostClipboardChanged`.
//
// The Linux leaf is `MutterClipboardLeaf` in lyte-host, over a
// Mutter-internal RemoteDesktop session: the portal and Wayland
// data-control routes are unavailable headless on GNOME
// (docs/decisions/20260807-015743-wayland-clipboard-gnome-blocker.md).
// lyte-host declares capability key 10 only when the leaf came up.

import LyteWire

/// The text-flavor policy the leaf runs. It reads exactly one flavor (the
/// most faithful one offered) and offers the standard trio when it owns
/// the selection. `UTF8_STRING` is the X11 target Xwayland clients still
/// speak. Matching is case-insensitive and the OFFERED spelling is
/// returned, so the read request echoes the owner's own words.
public enum ClipboardTextMime {
    public static let utf8 = "text/plain;charset=utf-8"

    /// What the leaf advertises when a client 0x1A makes it the
    /// selection owner — faithful flavor first.
    public static let offered = [utf8, "text/plain", "UTF8_STRING"]

    /// Read preference: explicit UTF-8, then the UTF-8-by-convention X11
    /// target, then bare text/plain (read as UTF-8, lossily).
    public static let readPreference = [utf8, "UTF8_STRING", "text/plain"]

    /// The flavor to SelectionRead from `offeredByOwner`, or nil when
    /// the owner holds no text (ignored, never an error).
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

/// The image-flavor policy: `ClipboardImageWire.acceptedMimes` only.
/// TEXT ALWAYS WINS when an owner offers both (a spreadsheet cell copy
/// advertises text and an image render; the text is what was copied).
public enum ClipboardImageFlavor {
    /// What the leaf advertises when it owns the selection with image
    /// cargo (a client image landing).
    public static let offered = [ClipboardImageWire.pngMime]

    /// The flavor to SelectionRead from `offeredByOwner`, or nil. Only
    /// consulted after the text policy answered nil, on the images tier.
    /// Case-insensitive; the OFFERED spelling is returned.
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

/// What a host clipboard leaf does with one selection-owner change. The
/// host clipboard is a session's only while that session is live: a copy
/// made before any session, or between two, is never read, let alone
/// announced to the next client (clipboards carry passwords). The leaf
/// outlives sessions, so it judges every change against a live one now.
public enum HostSelectionChange: Equatable, Sendable {
    /// Our own SetSelection landing: report the owned content upward
    /// (the session's sync book suppresses the echo).
    case reportOwnEcho
    /// A foreign copy during a live session: read this flavor, report it.
    case read(mime: String, image: Bool)
    /// No session is live.
    case ignoreOutsideSession
    /// Nothing the agreed tier carries (rich flavors, a cleared
    /// selection, images off the images tier).
    case ignoreFlavor

    public static func judge(
        sessionLive: Bool,
        sessionIsOwner: Bool,
        offered: [String],
        imagesEnabled: Bool
    ) -> HostSelectionChange {
        guard sessionLive else { return .ignoreOutsideSession }
        if sessionIsOwner { return .reportOwnEcho }
        // Text always wins when an owner offers both; images are the
        // fallback flavor, and only on the images tier.
        if let mime = ClipboardTextMime.pickForRead(fromOffered: offered) {
            return .read(mime: mime, image: false)
        }
        if imagesEnabled,
           let mime = ClipboardImageFlavor.pickForRead(fromOffered: offered) {
            return .read(mime: mime, image: true)
        }
        return .ignoreFlavor
    }
}

/// What a host clipboard leaf owes the shell. The leaf's signals arrive
/// on its own loop; the shell marshals onto the session's. Text is always
/// whole UTF-8 and never carries clearing. A text-only tier never fires
/// the image signal nor receives an image apply.
public protocol HostClipboardLeaf: AnyObject {
    /// Fired for every OS clipboard TEXT change, including the ones
    /// `apply(text:)` causes — the session's sync book suppresses those.
    var onLocalChange: ((String) -> Void)? { get set }

    /// Fired for every OS clipboard IMAGE change (whole PNG bytes),
    /// echoes of `apply(imageData:)` included.
    var onLocalImageChange: (([UInt8]) -> Void)? { get set }

    /// Make `text` the OS clipboard's content (a client 0x1A landing).
    func apply(text: String)

    /// Make the PNG bytes the OS clipboard's content (a sha-verified
    /// client image landing).
    func apply(imageData: [UInt8])

    func start() throws

    /// Stop observing and release the OS resources.
    func stop()
}
