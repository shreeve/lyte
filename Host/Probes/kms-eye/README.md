# kms-eye probes — the night the direct eye was proven (2026-08-01)

Two standalone C probes that established, on the reference laptop host
("pup", IdeaPad Pro 5 16IMH9, Meteor Lake Arc iGPU + RTX 4050, GNOME
Wayland live session), that Lyte can capture the screen WITHOUT the
compositor's cooperation — the feasibility basis for the direct-eye
rearchitecture (see docs/20260801-direct-eye-plan.md).

These are proof artifacts, kept verbatim. The production organ is
Swift (module-map C interop, no .c files); these compile standalone:

    gcc -O2 -o fbid-poll fbid-poll.c -ldrm -I/usr/include/libdrm
    gcc -O2 -o ccs-import-probe ccs-import-probe.c \
        -ldrm -lgbm -lEGL -lGL -I/usr/include/libdrm

## fbid-poll — the doorbell

Polls the active primary plane's FB_ID (and the cursor plane's) via
drmModeGetPlane. UNPRIVILEGED — only pixel access needs privileges.
The compositor flips a new framebuffer iff it repainted, so an
unchanged ID proves zero pixels changed: damage detection recovered
from below, wedge-proof (a register read cannot be withheld).

Measured (1 ms poll cadence, 15 s legs):

| leg                        | primary flips/s | cursor flips/s | poll cost |
|----------------------------|-----------------|----------------|-----------|
| idle desktop               | 1.00 (gap 998–1002 ms) | 0       | 4.3 µs    |
| 60 fps ffplay window       | 61.00 sustained | 0              | 32 µs     |

Cadence 0→60 fps is a consequence of content. Idle silence survives
the loss of Mutter's damage events. Hardware cursor is confirmed to
live on its own plane (cursor motion ≠ repaints → cursor is metadata).

## ccs-import-probe — the format bridge

The one real finding: Meteor Lake scans out XR30 (10-bit RGB) with CCS
compression (modifier 0x10000000000000f, 3-plane fb: main + aux +
clear-color). The MEDIA engine's VPP cannot ingest it (scale_vaapi
"Failed to start picture processing"; p010 output fails identically ⇒
it's the modifier, not the bit depth ⇒ no stock-ffmpeg one-liner).
The 3D engine CAN: headless EGL (GBM, surfaceless desktop-GL context),
eglCreateImageKHR with per-plane fd/offset/pitch + modifier lo/hi.

Measured: import 0.04 ms; glGetTexImage readback of genuine desktop
pixels in 6.8 ms (readback is probe-proof only — the production chain
blits GPU-side to an uncompressed NV12 surface shared with VAAPI and
never downloads).

Run with sudo (drmModeGetFB2 + drmPrimeHandleToFD need privileges):

    sudo ./ccs-import-probe /dev/dri/card1

## Encoder leg (no probe file — stock ffmpeg sufficed)

pup's system ffmpeg has hevc_vaapi AND av1_vaapi; iHD 26.1.2 drives
the Arc media engine; both emitted real bytes from kmsgrab input.
Two hardware AV1 encoders exist on this machine (Arc + Ada NVENC);
the client Mac (M5) hardware-decodes AV1 — recorded in TODO.md for
the post-rearchitecture codec milestone.
