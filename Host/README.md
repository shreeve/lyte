# Lyte Host (Linux)

The Swift Linux host: a full Lyte-UDP session host — the
direct eye's KMS capture → native VAAPI HEVC (our own bitstream pens),
5 ms Opus audio, uinput injection, Noise-sealed datagrams,
congestion control and targeted repair, Avahi discovery. H2 parity
closed 2026-07-22 (gate report in git history); the portal era ended
2026-08-02 at the `self-hosted` tag.

## Layout

- `Sources/HostCore` — pure Swift, no platform deps: Annex-B/HEVC NAL
  helpers, **the HEVC bitstream pens** (parameter sets, slice headers,
  the bit writer — since E5 the host authors its own bitstream), the
  encoder recipe, the quality ratchet, the strict-priority send pacer,
  the kernel-pressure governor, histograms. Builds and tests on macOS
  so the contracts are verifiable off-target.
- `Sources/HostSession` — IO-free responder policy over LyteWire: handshake
  admission and stateless retry cookies, lifecycle projection, and validated
  path migration. Time and randomness are mandatory inputs; decisions are
  values. Builds and tests on macOS and Linux.
- `Sources/HostWire` — the session execution layer on LyteWire (also
  cross-platform): Noise responder orchestration, VideoChannel
  (packetize/FEC/pace/repair store), AudioFramer, RateEstimator, pairing
  responder, and client keystore. It executes `HostSession` decisions but does
  not own their policy.
- `Sources/HostEye` — the direct eye (Linux): KMS doorbell + GETFB2/dmabuf
  export, EGL import + RGB→NV12 blit, the native VAAPI encoder seat fed
  by HostCore's pens, cursor-plane tracking.
- `Sources/CDBus`, `CPipeWire`, `CDRM`, `CGBM`, `CEGL`, `CVA`,
  `CNvEnc`, `CCuda` — pkg-config/systemLibrary module maps (Linux only).
- `Sources/CPipeWireAudio` — C leaf: default-sink monitor audio capture
  at the 5 ms quantum (PipeWire survives E5 for AUDIO only).
- `Sources/HostAudio` — Swift host-side Opus policy: 5 ms hard-CBR encode
  (+ decode for loop verification) over the one pinned static `COpus` source
  leaf in `Common/`.
- `Sources/CNetIO` — C leaf: the UDP socket (sendmmsg/recvmmsg, per-packet
  TOS cmsgs, kernel TX timestamps, line-buffered stdout).
- `Sources/CInputUinput` — C leaf: virtual evdev devices, the sole input
  backend.
- `Sources/lyte-host` — the Linux application composition root:
  `main.swift` only delegates, while `HostApplication` selects direct-eye
  capture, session wiring, Avahi advertisement, pairing (`--pair`), audio,
  clipboard, files, and input backends (`--input auto|uinput|off`).
- `Sources/lyte-eye` / `lyte-nvenc` — the standalone direct-eye probe and
  the banked NVENC-native probe (E6a).
- `Sources/lyte-netio-check`, `lyte-pace-check`, `lyte-audio-check` —
  on-host verification harnesses.

C lives only at the hardware/OS leaves (DRM/EGL/VAAPI module maps,
PipeWire audio, D-Bus, libopus, the socket, uinput), per the repository
architecture doctrine in `AGENTS.md` —
since E5 that includes no media library: the HEVC bitstream itself is
Swift (HostCore's pens).

## Test (macOS or Linux)

```
swift test           # pure cores + HostWire (the executable/C leaves are Linux-only)
```

On macOS use `DEVELOPER_DIR=/Applications/Xcode.app swift test` (CLT lacks XCTest).

## Machine prerequisites (one-time, per host box)

A fresh host needs a few things beyond the binary. All are applied (or
checked, with the exact commands printed) by one idempotent script — run
it as the seat user:

```
Host/Scripts/setup-host.sh
```

1. **CAP_SYS_ADMIN on the binary** — the direct eye reads the KMS
   scanout, which needs the DRM ticket. After EVERY rebuild:
   `sudo -n setcap cap_sys_admin+ep .build/release/lyte-host` (and
   `lyte-eye` when used). A capless binary fails loudly at startup —
   never silently. The script checks with `getcap` and prints the
   exact command. (The portal era's
   `MUTTER_DEBUG_PAINT=disable-direct-scanout` login-env flag is
   OBSOLETE — the direct eye reads the scanout itself, so direct
   scanout is now a feature, not a starvation bug; the script offers
   to remove a leftover `90-lyte-screencast.conf`.)

2. **Seat access to `/dev/uinput`** for the `CInputUinput` fallback
   input backend (HS-13) — the udev rule at
   `/etc/udev/rules.d/60-lyte-uinput.rules`. Needs root; the script
   prints the exact `sudo tee` command rather than escalating itself.

3. **(Optional) realtime scheduling for the latency threads.** The
   pacing drain and the 5 ms audio thread ask for SCHED_RR at startup
   and degrade gracefully without it (`sched:` lines say which rung
   they got). To grant it, add an rtprio rlimit for the seat user and
   re-login:

   ```
   echo "$USER - rtprio 20" | sudo tee /etc/security/limits.d/90-lyte-rtprio.conf
   ```

   Unprivileged runs are fully supported — this only buys scheduling
   tail behavior when the box is loaded (compilers, browsers) while
   hosting.

## Build and run on the Linux host (`pup`)

Source lives in this repo; sync it to the host and build there. This package
depends on the sibling `Wire/` and `Common/` packages, so all three must be
synced as siblings on the host:

```
rsync -a --delete --exclude .build Wire/ pup:src/Wire/
rsync -a --delete --exclude .build Common/ pup:src/Common/
rsync -a --delete --exclude .build Host/ pup:src/lyte-host/
ssh pup 'cd ~/src/lyte-host && \
  LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat swift build -c release'
ssh pup 'cd ~/src/lyte-host && sudo -n setcap cap_sys_admin+ep .build/release/lyte-host'
```

No media-library env exists anymore: E5 demolished the vendored FFmpeg and
Opus is built from Common's pinned source leaf. A release build succeeding
(with `ldd` showing zero libav and zero libopus) is itself a gate. Debug builds
remain for tests and harness development, never for the standing service.
Rate moves apply with zero reset and zero IDR by
construction — our own pens never emit a reset. The setcap line is the
DRM ticket for the direct eye; re-arm it after every rebuild.

The `LD_LIBRARY_PATH` shim points Swift 6.1.2's build tools at the system
`libxml2.so.16` (Ubuntu 26.04 does not ship `libxml2.so.2`):

```
ln -sf /usr/lib/x86_64-linux-gnu/libxml2.so.16 ~/.local/lib/swift-compat/libxml2.so.2
```

Run. Capture needs no graphical session, no consent dialog, and no
unlock — the direct eye reads the scanout with CAP_SYS_ADMIN; **pairing
is the consent model**. (Input and clipboard still prefer the Mutter
RemoteDesktop session bus when a session exists, with uinput as the
fallback.)

```
# File mode — capture the live scanout to an Annex-B file.
./.build/release/lyte-host --out /tmp/lyte-eye.hevc --seconds 5

# The real thing — a Lyte-UDP session host (prints its Noise static pubkey;
# audio + Avahi advertisement default-on; --pair for PIN pairing;
# --require-paired to enforce the keystore). 41000-range ports by
# convention; test hosts take fresh 41xxx ports with --no-advertise.
./.build/release/lyte-host --wire-listen 41000 --seconds 330

# HS-18: mute the host's own speakers for the session — desktop audio is
# routed to a session-owned "Lyte Audio" virtual sink (its monitor feeds
# the wire) and the original default sink is restored at teardown; a
# crashed run is swept on the next start.
./.build/release/lyte-host --wire-listen 41000 --host-audio muted --seconds 330
```

(`--backend direct`, `--encoder native`, and `--ratchet` are accepted
no-ops kept for the owner's standing loop line; the demolished portal/
mutter backends and the libav seat fail loudly by name.)

## Verify the output

```
ffprobe /tmp/lyte-h0a.hevc                     # hevc, correct resolution
ffmpeg -v error -i /tmp/lyte-h0a.hevc -f null - # decodes with no errors
```

The tool also self-checks that the first encoded packet begins with
VPS/SPS/PPS + an IDR.

Capture is change-driven from below: the direct eye polls the scanout
plane's framebuffer ID at display rate — no repaint means no new FB ID
means nothing captured or encoded, so cadence scales 0 fps (blank) →
~1 fps (caret blink) → 60 fps (video) automatically, with no
compositor cooperation to starve. On the wire, a static screen is
served by the repair store's retained IDR rather than re-encodes —
idle silence is the default posture, not a negotiated extra.
