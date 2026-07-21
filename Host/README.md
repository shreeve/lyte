# Lyte Host (Linux)

The Swift Linux host (LYTE-PLAN §6, `docs/HOST-PLAN.md`). This is the H0a
"first pixels" work: desktop capture → NVENC HEVC, ahead of any RTP/protocol.

## Layout

- `Sources/HostCore` — pure Swift, no platform deps. Annex-B/HEVC NAL helpers.
  Builds and tests on macOS so the bitstream contract is verifiable off-target.
- `Sources/CDBus`, `Sources/CPipeWire`, `Sources/CLibAV` — pkg-config
  systemLibrary modules (Linux only).
- `Sources/CPipeWireCapture` — C leaf: a PipeWire input stream that hands mapped
  RGB frames to a callback (SPA pod building is macro-only, hence C), plus an
  optional repeating tick on the same loop thread for the steady-rate supply.
- `Sources/CHevcEncode` — C leaf: libavcodec `hevc_nvenc` with Sunshine's
  low-latency recipe (true CBR, single-frame VBV, GOP INT_MAX, zero B-frames,
  preset p1 + ull, zero reorder, one surface). Annex-B packets out.
- `Sources/lyte-host` — the executable: D-Bus portal ScreenCast session (or the
  Mutter fallback), the capture→encode wiring, and the file writer.

C lives only at the hardware/OS leaves (PipeWire, D-Bus, libavcodec), per
LYTE-PLAN §4.

## Test (macOS or Linux)

```
swift test           # HostCore Annex-B helpers
```

On macOS use `DEVELOPER_DIR=/Applications/Xcode.app swift test` (CLT lacks XCTest).

## Build and run on the Linux host (`pop`)

Source lives in this repo; sync it to the host and build there:

```
rsync -a --delete --exclude .build Host/ pop:src/lyte-host/
ssh pop 'cd ~/src/lyte-host && \
  LD_LIBRARY_PATH=$HOME/.local/lib/swift-compat /usr/local/bin/swift build'
```

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
