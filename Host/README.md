# Lyte Host (Linux)

The Swift Linux host: a Lyte-UDP session host that captures the KMS
scanout with its own Direct Eye, encodes HEVC through native VAAPI with
Lyte's own bitstream writers, sends 5 ms Opus audio, injects input through
uinput, and advertises itself over Avahi. No portal, ffmpeg or libav.

This page is the package developer's view. Installing a host:
[INSTALL.md](INSTALL.md). Operating an installed host and the reference
rig: [docs/OPERATIONS.md](../docs/OPERATIONS.md). How the host fits the whole
system: [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## Targets and tests

Pure targets (`HostCore`, `HostSession`, `HostWire`, `HostIO`,
`HostAudio`) build and test on macOS as well as Linux; everything that
touches hardware or the OS is Linux-only (`#if os(Linux)` in
`Package.swift`). What each target owns:
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md#targets). C lives only at
hardware and OS leaves, per the doctrine in [AGENTS.md](../AGENTS.md); the
HEVC bitstream itself is Swift.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Host --scratch-path Host/.build -Xswiftc -warnings-as-errors
```

Which suites run where, and the gates: [docs/TESTING.md](../docs/TESTING.md).
Building on pup, including the `LD_LIBRARY_PATH` shim:
[docs/OPERATIONS.md](../docs/OPERATIONS.md#build-on-pup).

## Run by hand

Hand-run binaries need the DRM capability (`sudo setcap cap_sys_admin+ep
BINARY`, re-applied after every rebuild) and must live off `/tmp`. Never
run one on the standing port 41151 (a listener on a port another socket
holds refuses to start) or beside the standing service's Direct Eye; see
the safety rules in [docs/OPERATIONS.md](../docs/OPERATIONS.md#safety).

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
(admit only paired clients), `--input auto|uinput|off`, `--clipboard` or
`--clipboard=images`, `--accept-files[=DIR]`, `--advertise-interface
IFACE`, `--drm-device PATH` (the card to capture, default
`/dev/dri/card1`; the render node is that GPU's own), and
`--cookie-enter N` / `--cookie-exit N` (the message-1 rates that turn the
handshake's retry-cookie demand on and off, default 20 and 5).
`lyte-host --help` lists the rest. The host self-checks that its first
encoded packet starts with VPS/SPS/PPS and an IDR.

How capture, encode and the service loop behave:
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md#host-linux). Machine
prerequisites (`CAP_SYS_ADMIN`, uinput access, realtime scheduling) and
`Host/Scripts/setup-host.sh`: [INSTALL.md](INSTALL.md#1-machine-prerequisites).
