# Changelog

User-visible changes to the Lyte macOS app and the Linux host, newest
first. Each release's section is its GitHub release notes and the notes
Sparkle shows in the update window (`Scripts/release.sh`).

## Unreleased

- **⌘ shortcuts reach Linux as Ctrl (breaking).** In a stream, ⌘ plus a
  letter is sent as Ctrl plus that letter: ⌘S saves, ⌘Z undoes, ⌘⇧Z is
  Ctrl+Shift+Z. The chord follows the letter your layout types (Dvorak or
  AZERTY ⌘S is Ctrl+S; a layout that types no a–z letter sends Super).
  Enabled app shortcuts stay on the Mac: ⌘R Reconnect, ⌘D Disconnect, ⌘N,
  ⌘W, ⌘Q, ⌘H, ⌘M, ⇧⌘M, ⇧⌘H, ⌥⌘I and ⌥⌘C; for Ctrl+R, Ctrl+D or Ctrl+N
  use the physical Ctrl key. Typing on after a ⌘ chord sends no stray
  Ctrl.
- **Terminals (breaking).** ⌘C in a Linux terminal is Ctrl+C, which
  interrupts. Copy and paste there with ⌘⇧C and ⌘⇧V (Ctrl+Shift+C and
  Ctrl+Shift+V); Share Clipboard moved from ⌘⇧C to ⌥⌘C to free them.
- **Secure Keyboard Entry** (Actions menu, off by default) keeps other
  apps from reading your keystrokes while a stream window is key. It also
  blocks password-manager autotype and text expanders while on.
- **Paired hosts off the local network.** A paired host that discovery
  does not see is listed as "last seen at address:port" and dials its
  pinned address.
- **Client fixes.** The host cursor keeps its scale after a window
  resize. Builds signed with the self-signed Lyte Dev identity launch
  again. Development builds report the latest release's version. The
  embedded Sparkle is arm64 only. Audio after an announced quiet no longer
  loses the start of the next sound. Video recovers faster when playback
  flushes: the keyframe that tripped the flush is kept, not dropped and
  asked for again. A frame the Mac cannot decode no longer freezes the
  picture: the client flushes and asks for a fresh keyframe. Pairing
  ends with a goodbye, so a `--pair` host exits at once.
- **Why a keyframe was asked for.** Each keyframe the Mac asks for now
  names its cause in the stats overlay's "idr" row, in `lyte-cli
  wire-view`, and in the app's log ("lyte video: IDR requested after
  frame N — cause").
- **Host.** Input carrying a key or button code the host never declared
  is refused. Dropped file names can no longer become hidden dotfiles, and
  a transfer that fails its final rename leaves no staging file behind.
  The capture card is found automatically (`--drm-device` overrides it).
  Handshake flood protection and retry-cookie state now last for the
  whole host process instead of resetting with each session, and the
  flood statistics are cumulative. `--audio-bitrate-kbps` accepts 1–512.
  Every `host.log` line now starts with its UTC time (ISO 8601,
  milliseconds).
- **Browser.** The proof page no longer forwards volume keys, matching the
  Mac client.

### Migration

- Removed (breaking): `lyte-host --wire-out`, `--no-vbv-reconfigure` and
  `lyte-host advertise`; the `lyte-eye` probe; the host's handshake
  witness (`LYTE_HANDSHAKE_WITNESS_JSONL` on the host); `lyte-cli`
  `wire-discover`, `wire-unpair`, `decode-probe`, `corpus-gen`,
  `corpus-gate`, and `wire-view --input-script` and `--audio-prime`.
- `lyte-host` refuses a session flag given without `--wire-listen`
  (breaking for scripts that passed them in file mode).
- `lyte-cli wire-view` prints its stats as `name=value` fields.

## 0.6.0 — 2026-09-24

The first release installed with Homebrew and updated in place.

- **Install and updates.** `brew install --cask shreeve/tap/lyte`; the app
  then updates itself (Lyte → Check for Updates…). Releases are signed with
  a Developer ID and notarized, so the app's identity, and with it the
  Local Network permission and the helper's approval, carries across
  updates.
- **A new icon** in the Dock and Finder, and a matching menu-bar glyph.
- **Security.** A malformed pointer or scroll event could crash the host,
  and a hostile host could crash the Mac client; both now refuse bad
  values. The root helper is registered only after its signature checks
  out. Copies a password manager marks as concealed stay on the Mac.
  File-drop names can no longer reach a subdirectory. The host's
  handshake throttle now challenges a flood instead of starving real
  clients.
- **Roaming.** The Mac answers the host's path challenge, so moving between
  networks keeps the session instead of redialling, and roaming keeps
  searching for a host that moved.
- **Input.** Caps Lock and the ISO, JIS and context-menu keys reach the
  host. Held keys survive a short network hitch; a key the host would
  repeat is released after two seconds of silence, and modifiers and mouse
  buttons when the session ends.
- **Lower latency.** The host numbers and seals video as the pacer releases
  it, so a frame's first packet leaves in about 10 µs instead of after the
  whole frame is sealed, and stale repairs and phantom loss are gone.
- **Quitting** sends the host a goodbye; a dial in progress is cancelled on
  Disconnect or Quit.

### Migration

- Host flags removed: `--backend`, `--encoder`, `--ratchet` and
  `--require-cookie` (the retry cookie is always armed). New:
  `--drm-device`.
- Host paths follow XDG: `~/.config/lyte/` (identity and `host.conf`),
  versioned binaries behind `~/.local/bin/lyte-host`
  (`Host/Scripts/deploy-host.sh`), the log in `~/.local/state/lyte/`.
  Existing identity files were copied and verified; the old ones are left
  in place.
- A fresh install's `host.conf` no longer turns on clipboard sync.
- A second listener on a port another socket holds now refuses to start.
- `lyte-cli`: `wire-listen`, `--arq-ping` and `--register-helper` are gone.
- Signed builds use the hardened runtime, so a debugger cannot attach to
  them; debug an unsigned build.
- The app honours the benchmark and diagnostic environment only in a bundle
  built with `Scripts/make-app.sh --diagnostics`.
