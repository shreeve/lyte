# Changelog

User-visible changes to the Lyte macOS app and the Linux host, newest
first. Each release's section is its GitHub release notes and the notes
Sparkle shows in the update window (`Scripts/release.sh`).

## 0.6.0 — unreleased

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
