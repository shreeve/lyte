# Wayland clipboard leaf — GNOME blocker (2026-08-07)

> **Verdict: blocked on the reference host.** Capture and input are
> compositor-independent; host clipboard is not. Shipping Lyte on Ubuntu
> GNOME still requires the Mutter RemoteDesktop session-bus clipboard API
> (`MutterClipboardLeaf`). Do not fake a Wayland-helper carriage until an
> unlock below lands. Wire protocol and `HostClipboardLeaf` seam stay
> unchanged.

## 1. What was asked

After Direct Eye, the last Mutter-coupled organ is clipboard
(`TODO.md`; plan note in `docs/20260801-105800-direct-eye-plan.md` §5).
The filed replacement was an unprivileged user-session Wayland helper
(`wlr-data-control` or equivalent) speaking to `lyte-host` over a local
socket — or, failing that, portal Clipboard without a Mutter RD session.

## 2. What works today (keep shipping)

`MutterClipboardLeaf` drives `org.gnome.Mutter.RemoteDesktop` on its own
session-bus connection: `CreateSession` → `Start` → `EnableClipboard`,
then `SelectionOwnerChanged` / `SelectionRead` / `SetSelection` /
`SelectionTransfer` / `SelectionWrite`. Probed live on pup again for
this record: Start + EnableClipboard succeed immediately. Capability
key 10 (and images key 12) still declare only when the leaf comes up.

This is GNOME-specific by construction. It is also the only bidirectional
background clipboard path that works on the reference rig.

## 3. Pup probes (Ubuntu 26.04, GNOME Shell 50.1, Mutter 50.1)

Environment: user session `WAYLAND_DISPLAY=wayland-0`, portal stack
`xdg-desktop-portal` 1.21.1 + `xdg-desktop-portal-gnome` 50.0,
`wl-clipboard` 2.2.1. `lyte-host.service` already inherits the session
bus and Wayland display.

| Path | Result |
|---|---|
| Mutter RD clipboard (`EnableClipboard`) | **Works** — CreateSession/Start/EnableClipboard/Stop |
| `wlr-data-control` / `ext-data-control` | **Absent** — not in compositor globals; `org.gnome.mutter experimental-features` is empty |
| `wl-copy` / `wl-paste` | **Hang** (5 s / 3 s timeouts) — no focus-steal carriage from the session helper context |
| GDK/GTK4 clipboard read + `set_content` | **Fail** — empty / no compatible transfer format from a headless display connection |
| Portal `org.freedesktop.portal.Clipboard` | **Interface present** (v1) — `RequestClipboard` / selection signals exist |
| Portal RemoteDesktop `Start` after SelectDevices + RequestClipboard | **No Response** within 8 s — CP-5 Q1 headless auto-deny / consent hang reconfirmed |
| Standalone `org.gnome.Mutter.Clipboard` | **Absent** — clipboard remains on the RD session object only (`EnableClipboard` in libmutter) |
| Mutter `InputCapture` bus | **No clipboard methods** — CreateSession only |

GNOME's stated posture (upstream tracker / community writeups): 
`wlr-data-control` / `ext-data-control` are treated as a sandbox hole for
background clipboard scraping and are not a shipping Mutter feature.
Upstream portal work to hang Clipboard off Input Capture (deskflow-era
MRs) is not a Lyte unlock on this host: Input Capture is barrier/EIS
shaped, and portal RD Start still does not complete headlessly here.

## 4. Ranked options (honest)

1. **Real Wayland clipboard leaf on pup's GNOME without Mutter RD** —
   **unavailable.** No data-control protocol; wl-clipboard and GDK do not
   provide watch+serve without compositor privilege APIs.
2. **Best compositor-independent stopgap (portal Clipboard, no Mutter
   RD name)** — **unavailable for headless host duty.** Portal Clipboard
   does not create its own session; it attaches to RemoteDesktop or
   Input Capture. Portal RD Start does not complete without interactive
   consent on this GNOME. Restoring a prior portal RD token would still
   be a portal RemoteDesktop session (and a consent-once product story
   Lyte deliberately left with Direct Eye), not the Wayland-helper plan.
3. **Remain on Mutter RD; sharpen the deferral** — **chosen.** Keep
   `MutterClipboardLeaf` as the shipping GNOME leaf. Do not ship a
   pretend helper, a `wl-clipboard` subprocess carriage, or a portal
   wrapper that cannot Start.

A `wlr-data-control` leaf for wlroots compositors remains a valid future
optional path, but it does not retire the Mutter dependency on the
reference host and is not this slice.

## 5. Unlock conditions (any one)

- Mutter/GNOME ships a **documented, non-RD** background clipboard API
  that an unsandboxed user-session helper can watch and serve (selection
  change + fd transfer both ways), **or**
- Portal Clipboard becomes usable for Lyte's host without an interactive
  RemoteDesktop/InputCapture Start on the reference GNOME (restore-token
  or policy change proven live on pup), **or**
- The reference host moves to a compositor that exposes
  `ext-data-control` / `wlr-data-control` and a Wayland helper is
  implemented against that contract.

Until then the TODO bullet stays, with this record as the pin.

## 6. What must not change while blocked

- Wire types 0x1A / 0x1B, image bulk dialect, keys 10/12, and
  `ClipboardSyncBook` loop law.
- `HostClipboardLeaf` seam in HostWire (scripted gates remain the
  cross-platform proof).
- Identity files and the standing UDP 41151 service discipline.
