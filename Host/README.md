# Lyte Host (Linux)

The Swift Linux host: a Lyte-UDP session host that captures the KMS
scanout with its own Direct Eye, encodes HEVC through native VAAPI with
Lyte's own bitstream writers, sends 5 ms Opus audio, injects input through
uinput, and advertises itself over Avahi. No portal, ffmpeg or libav.

This page is the package developer's view. Installing a host:
[INSTALL.md](INSTALL.md). Deploying to and operating the reference host:
[docs/OPERATIONS.md](../docs/OPERATIONS.md). How the host fits the whole
system: [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## Targets

Pure targets build and test on macOS as well as Linux. Everything that
touches hardware or the OS is Linux-only (`#if os(Linux)` in
`Package.swift`).

| Target | Platforms | Owns |
|---|---|---|
| `HostCore` | all | HEVC parameter-set and slice-header writers (the pens), `Pacer`, kernel-pressure governor, `HostServiceLoop`, audio tripwire, quiet-video pacer, screen sampling cadence |
| `HostSession` | all | Sans-IO responder policy: handshake admission and retry cookies, lifecycle lane, path validation. Time and randomness are inputs |
| `HostWire` | all | Sans-IO session execution: Noise responder, sealing, ARQ lanes, `VideoChannel` (packetize, FEC, repair store), `RateEstimator`, `SocketOutbox`, pre-encode admission, encoder VBV/HRD policy, pairing responder, client keystore |
| `HostIO` | all | OS adapters over HostWire's seams: `HostPaths` (XDG layout, pre-XDG identity adoption), `SecretFile` (0600 atomic writes), `BulkFileStore` (file drops) |
| `HostAudio` | all | 5 ms hard-CBR Opus over Common's pinned `COpus` |
| `HostWireTestKit` | all | Test-only: `HostSessionHarness`, a shipping `Session` in virtual time |
| `HostEye` | Linux | Direct Eye: GETFB2 scanout ticket, dmabuf import, 16×16-tile GPU pixel fingerprint, NV12/AYUV EGL blit (BT.709 limited range), VAAPI encoder seat, cursor plane |
| `CDRM` `CGBM` `CEGL` `CVA` `CPipeWire` `CDBus` `CNvEnc` `CCuda` | Linux | System-library module maps |
| `CPipeWireAudio` | Linux | Default-sink monitor capture at the 5 ms quantum |
| `CNetIO` | Linux | UDP sockets: `sendmmsg`/`recvmmsg`, per-packet TOS, kernel timestamps |
| `CInputUinput` | Linux | Virtual evdev devices, the only input backend |
| `lyte-host` | Linux | The composition root (`HostApplication`): Direct Eye leg, session wiring, service loop, Avahi, pairing, audio, clipboard (Mutter RemoteDesktop session), files, input |
| `lyte-control-peer` | all | DRM-free `HostWire.Session` over UDP for the browser proof |
| `lyte-eye` | Linux | Standalone Direct Eye probe |
| `lyte-nvenc` | Linux | Banked NVENC probe |
| `lyte-netio-check`, `lyte-pace-check`, `lyte-audio-check`, `lyte-uinput-check` | Linux | On-host verification harnesses |

C lives only at hardware and OS leaves, per the doctrine in
[AGENTS.md](../AGENTS.md). The HEVC bitstream itself is Swift.

## Test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Host --scratch-path Host/.build -Xswiftc -warnings-as-errors
```

On macOS this runs `HostCoreTests`, `HostSessionTests`, `HostWireTests`,
`HostAudioTests` and `HostLayoutTests`. On Linux it adds `HostEyeTests`,
`CNetIOTests` and `LyteHostIntegrationTests` (loopback sockets, the
service loop, identity files). Building on pup, including the
`LD_LIBRARY_PATH` shim: [docs/OPERATIONS.md](../docs/OPERATIONS.md#build-on-pup).
All gates: [docs/TESTING.md](../docs/TESTING.md).

## Run by hand

Hand-run binaries need the DRM capability (`sudo setcap cap_sys_admin+ep
BINARY`, re-applied after every rebuild) and must live off `/tmp`. Never
run one on the standing port 41151 or beside the standing service's
Direct Eye; see the safety rules in
[docs/OPERATIONS.md](../docs/OPERATIONS.md#safety).

```sh
# File mode: capture the scanout to an Annex-B file.
./.build/release/lyte-host --out /tmp/lyte-eye.hevc --seconds 5
ffprobe /tmp/lyte-eye.hevc                        # hevc, the panel's resolution
ffmpeg -v error -i /tmp/lyte-eye.hevc -f null -   # decodes without errors

# A session host on a fresh test port. Without --seconds or --pair a
# listening host is the service: it serves sessions in turn in one process.
./.build/release/lyte-host --wire-listen 41000 --no-advertise
./.build/release/lyte-host --wire-listen 41000 --no-advertise --seconds 330

# Mute the host's speakers for the session: desktop audio goes to a
# session-owned "Lyte Audio" sink whose monitor feeds the wire; the
# original default sink is restored at teardown (or on the next start
# after a crash).
./.build/release/lyte-host --wire-listen 41000 --no-advertise --host-audio muted --seconds 330
```

Other flags: `--pair` (PIN pairing, one session), `--require-paired`
(admit only paired clients), `--input auto|uinput|off`,
`--clipboard=images`, `--advertise-interface IFACE`. `lyte-host --help`
lists them all. The host self-checks that its first encoded packet starts
with VPS/SPS/PPS and an IDR.

## Capture

Capture is change-driven by pixels. On a 60 Hz beat the Direct Eye
fingerprints the current scanout on the GPU; framebuffer identity only
decides when to re-import, because a compositor may redraw one buffer for
minutes. Unchanged pixels encode nothing, so the frame rate runs from 0 fps
(blank) through about 1 fps (a blinking caret) to 60 fps (video). A still
screen is kept warm by re-encoding the retained frame once a second, less
often under an announced quiet video posture, and a demanded IDR on a still
screen re-encodes that frame. A changed frame is skipped before encode
while queued video already holds its latency budget, and the encoder's HRD
buffer is bounded so a frame at the rate ceiling fits one FEC group. Rate
changes apply on the next frame with no encoder reset and no IDR.

## Machine prerequisites

`Host/Scripts/setup-host.sh` checks each of these and prints the exact
repair command; it never escalates itself. Run it as the seat user.

1. **`CAP_SYS_ADMIN`** for the Direct Eye's DRM ticket. The installed
   service grants it ambiently; only hand-run binaries need `setcap`. A
   binary without it fails loudly at startup.
2. **`/dev/uinput` access** through `/etc/udev/rules.d/60-lyte-uinput.rules`.
   Without it client input is off.
3. **Optional realtime scheduling.** The pacing and audio threads ask for
   `SCHED_RR` and degrade gracefully (`sched:` log lines say which rung
   they got). To grant it:

   ```sh
   echo "$USER - rtprio 20" | sudo tee /etc/security/limits.d/90-lyte-rtprio.conf
   ```

The script also reports portal-era and pre-XDG leftovers.
