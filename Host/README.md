# Lyte Host (Linux)

The Swift Linux host (LYTE-PLAN §6, `docs/HOST-PLAN.md`): a full Lyte-UDP
session host — portal desktop capture → NVENC HEVC video, 5 ms Opus audio,
Mutter/uinput input injection, Noise-sealed datagrams, congestion control
and targeted repair, Avahi discovery. H2 parity closed 2026-07-22
(`docs/20260722-h2-joint-gate.md`).

## Layout

- `Sources/HostCore` — pure Swift, no platform deps: Annex-B/HEVC NAL
  helpers, the strict-priority send pacer, histograms. Builds and tests on
  macOS so the contracts are verifiable off-target.
- `Sources/HostWire` — the session layer on LyteWire (also cross-platform):
  Session (Noise responder), VideoChannel (packetize/FEC/pace/repair
  store), AudioFramer, RateEstimator, SessionStateMachine wiring,
  PathValidator migration, pairing responder, client keystore.
- `Sources/CDBus`, `Sources/CPipeWire`, `Sources/CLibAV`, `Sources/COpus` —
  pkg-config systemLibrary modules (Linux only).
- `Sources/CPipeWireCapture` / `Sources/CPipeWireAudio` — C leaves: portal
  video stream (mapped RGB frames + damage-driven callback + tick) and
  default-sink monitor audio capture at the 5 ms quantum.
- `Sources/CHevcEncode` — C leaf: libavcodec `hevc_nvenc` with the
  low-latency recipe (true CBR, single-frame VBV, GOP INT_MAX, zero
  B-frames, preset p1 + ull, zero reorder, one surface; capped-CQ VBR for
  `--ratchet`). Annex-B packets out.
- `Sources/COpusEncode` — C leaf: libopus 5 ms hard-CBR encode (+ decode
  for loop verification).
- `Sources/CNetIO` — C leaf: the UDP socket (sendmmsg/recvmmsg, per-packet
  TOS cmsgs, kernel TX timestamps).
- `Sources/CInputUinput` — C leaf: virtual evdev devices, the input
  fallback behind Mutter RemoteDesktop.
- `Sources/lyte-host` — the executable: portal/Mutter capture session,
  session wiring, Avahi advertisement, pairing (`--pair`), input backends
  (`--input auto|mutter|uinput|off`).
- `Sources/lyte-netio-check`, `lyte-pace-check`, `lyte-audio-check` —
  on-host verification harnesses.

C lives only at the hardware/OS leaves (PipeWire, D-Bus, libavcodec,
libopus, the socket, uinput), per LYTE-PLAN §4.

## Test (macOS or Linux)

```
swift test           # HostCore + HostWire (the executable + C leaves are Linux-only)
```

On macOS use `DEVELOPER_DIR=/Applications/Xcode.app swift test` (CLT lacks XCTest).

## Machine prerequisites (one-time, per host box)

A fresh GNOME/Wayland host needs two things beyond the binary. Both are
applied (or checked, with the exact commands printed) by one idempotent
script — run it as the seat user, then log out and back in:

```
Host/Scripts/setup-host.sh
```

1. **Mutter must keep compositing fullscreen video** —
   `MUTTER_DEBUG_PAINT=disable-direct-scanout` in
   `~/.config/environment.d/90-lyte-screencast.conf`. By default Mutter
   promotes a fullscreen surface (video players, games) to *direct
   scanout* a few seconds in: the surface bypasses the compositor and
   goes straight to the display hardware, compositing stops, and the
   ScreenCast — which watches the compositor's output — delivers
   nothing. The remote glass freezes while the host idles; every mouse
   move wakes one frame, then it starves again. (Diagnosed live
   2026-07-30: wake IDRs + 1 s capture gaps during YouTube playback;
   see HANDOFF.) There is **no runtime toggle** on stock Mutter — no
   D-Bus control, no gsettings experimental feature; gnome-shell reads
   the flag once at login, which is why this is per-machine session
   config and not something lyte-host can set for itself. The host
   *does* verify it at every startup: if the running gnome-shell lacks
   the flag it prints `capture: WARNING — … fullscreen video will
   freeze the stream` in its opening lines. A silent startup means the
   box is provisioned. Local cost: fullscreen content composites
   instead of scanning out — a few % GPU, irrelevant for a host box.

2. **Seat access to `/dev/uinput`** for the `CInputUinput` fallback
   input backend (HS-13) — the udev rule at
   `/etc/udev/rules.d/60-lyte-uinput.rules`. Needs root; the script
   prints the exact `sudo tee` command rather than escalating itself.

## Build and run on the Linux host (`pup`)

Source lives in this repo; sync it to the host and build there. This package
depends on the sibling `Wire/` package (`.package(path: "../Wire")`), so both
must be synced as siblings on the host:

```
rsync -a --delete --exclude .build Wire/ pup:src/Wire/
rsync -a --delete --exclude .build --exclude Vendor/ffmpeg/build \
  --exclude Vendor/ffmpeg/prefix Host/ pup:src/lyte-host/
ssh pup 'cd ~/src/lyte-host && \
  VP=$PWD/Vendor/ffmpeg/prefix && \
  LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat \
  LYTE_FFMPEG_PREFIX=$VP PKG_CONFIG_PATH=$VP/lib/pkgconfig \
  swift build'
```

⚠️ `LYTE_FFMPEG_PREFIX`/`PKG_CONFIG_PATH` link the vendored no-reset
FFmpeg (HS-33 — rate reconfigures without an encoder reset or forced
IDR; `Vendor/ffmpeg/README.md` is the full account, including the
first-time `Scripts/vendor-ffmpeg.sh` bootstrap). A bare `swift build`
still succeeds but silently relinks the **distro** libavcodec and every
rate move goes back to minting IDRs. The running binary proves which
one it got in its second log line: `encoder: vendored no-reset
libavcodec …` is the good one; `encoder: no-reset rate moves INACTIVE`
means rebuild with the envs.

The `LD_LIBRARY_PATH` shim points Swift 6.1.2's build tools at the system
`libxml2.so.16` (Ubuntu 26.04 does not ship `libxml2.so.2`):

```
ln -sf /usr/lib/x86_64-linux-gnu/libxml2.so.16 ~/.local/lib/swift-compat/libxml2.so.2
```

Run (must be inside the logged-in graphical session; the session must be
unlocked or capture is inhibited):

```
# Primary path — xdg-desktop-portal ScreenCast. First run shows a one-time
# consent dialog on the host's physical screen; approving it persists a
# restore token so later runs are non-interactive.
./.build/debug/lyte-host --out /tmp/lyte-h0a.hevc --seconds 5

# Spike fallback — Mutter's internal ScreenCast, no consent dialog.
./.build/debug/lyte-host --backend mutter --connector eDP-1 --out /tmp/lyte-h0a.hevc --seconds 5

# The real thing — a Lyte-UDP session host (prints its Noise static pubkey;
# audio + Avahi advertisement default-on; --pair for PIN pairing;
# --require-paired to enforce the keystore). 41000-range ports by convention.
./.build/debug/lyte-host --backend portal --wire-listen 41000 --ratchet --seconds 330

# HS-18: mute the host's own speakers for the session — desktop audio is
# routed to a session-owned "Lyte Audio" virtual sink (its monitor feeds
# the wire) and the original default sink is restored at teardown; a
# crashed run is swept on the next start.
./.build/debug/lyte-host --backend portal --wire-listen 41000 --host-audio muted --seconds 330
```

## Verify the output

```
ffprobe /tmp/lyte-h0a.hevc                     # hevc, correct resolution
ffmpeg -v error -i /tmp/lyte-h0a.hevc -f null - # decodes with no errors
```

The tool also self-checks that the first encoded packet begins with
VPS/SPS/PPS + an IDR, and rejects loudly (naming a locked session) if the
portal inhibits capture.

PipeWire delivery is damage-driven (a static desktop yields ~1–2 fps), so the
host applies Sunshine's idle floor by default: when no fresh frame arrives
within a frame interval it re-encodes the last captured frame, giving a
steady ~fps supply. A 5-second run therefore reports ~300 frames encoded —
e.g. `301 frames encoded (7 damage, 294 repeated), 301 packets out (1 IDR)` —
instead of a handful. Repeats are ordinary P-frames; note that CBR rate
control keeps spending budget refining the static scene (Sunshine's
documented "idle ≠ quiet" behavior), so bytes track the bitrate rather than
the damage rate. `--no-idle-floor` restores pure damage-driven output for
debugging.
