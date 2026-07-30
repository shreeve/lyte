# Vendored no-reset FFmpeg (HS-33)

A minimal, patched, **static** libavcodec/libavutil the host links in
place of the distro shared FFmpeg, so that rate/VBV reconfigures stop
minting IDRs. Built by `Host/Scripts/vendor-ffmpeg.sh`; the build
products (`build/`, `prefix/`) are gitignored — **the script is the
artifact**, and a fresh checkout reproduces it bit-for-bit from the
pinned inputs below.

## Why this exists — the FFmpeg wall

FFmpeg's nvenc wrapper (`libavcodec/nvenc.c reconfig_encoder`) already
diffs `bit_rate`/`rc_max_rate`/`rc_buffer_size` against the running
NVENC config and folds a change into one `NvEncReconfigureEncoder`
call — but then sets `resetEncoder = 1; forceIDR = 1` UNCONDITIONALLY
for any rate delta. NVENC's own API (the `DYN_BITRATE_CHANGE` cap,
supported on the reference host's RTX 4050) exists precisely to
promise in-place rate moves with `resetEncoder=0/forceIDR=0`; the
wrapper never issues them, no AVOption avoids it, and the session
handle is private wrapper state (HS-27's investigation — option
routes: conclusively dead). Every estimator-driven rate move through
distro libavcodec therefore costs a full forced IDR — the beauty
bar's last red (rung-crossing toll, HS-30 remainder).

## What the patch changes, exactly

`nvenc-no-reset-rate.patch` (the HS-33a spike's GO-verdicted diff,
hunks byte-identical — only the `---`/`+++` headers were normalized to
`a/`//`b/` form so `patch -p1` applies it; sha256 now `16521707ffefc66
3707d2fddf75ffb3fe8bb664ff57de0603456b7cce6576316`; applied to the
n8.0.1 release tarball — the exact upstream tag behind the reference
host's distro `7:8.0.1-3ubuntu2`) touches ONE site: `reconfig_encoder`'s
`if (reconfig_bitrate)` block, plus a `<stdlib.h>` include for
`getenv`. The unconditional

```c
params.resetEncoder = 1;
params.forceIDR = 1;
```

becomes: **if env `LYTE_NVENC_NO_RESET_RATE` is set to `1` AND the
reconfigure carries no DAR change, both are set to `0`** (logged loud
at AV_LOG_INFO); otherwise the upstream behavior rides byte-for-byte.
One binary A/Bs both behaviors; any resolution/aspect move keeps
today's reset path by construction (the DAR guard).

Validated on real hardware by the HS-33a spike (HANDOFF.md wave
entry; evidence pup `~/hs33a/`): rate-only, VBV-only, and rate+VBV
ladder shapes all applied under `resetEncoder=0` — segment rates
track the ladder within ~1% of the reset path, max frame sizes clamp
to vbv/8 exactly, `nvEncReconfigureEncoder` accepted every move, the
no-reset streams are 1 I + 719 consecutive P decoding 720/720 under
ffmpeg strict `-err_detect …+explode -xerror` AND VideoToolbox
hardware (`lyte-cli decode-probe --require-hardware`), with per-frame
PSNR floors ≥ the control legs in every shape.

## The build — pinned inputs

| input | pin |
| --- | --- |
| ffmpeg-8.0.1.tar.xz | sha256 `05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41` |
| nv-codec-headers | tag `n13.0.19.1` = commit `88fee5c37318c991a8762d423530f91681e32e3a` (SDK 13.0, min driver 570 — the reference host runs 595.84; n13.1.x wants 610+) |

Configure: `--disable-everything --disable-autodetect` + explicit
ffnvcodec/cuda/nvenc + `--enable-encoder=hevc_nvenc`, static only,
PIC, no x86asm (hevc_nvenc has no SIMD) — `config_components.h`
proves exactly one encoder and zero decoders, and no ambient external
lib leaks into the archive's link-time needs. The build also carries
`--extra-version=lyte-noreset`: the marker `lyte-noreset` in
`avcodec_configuration()` is how a running binary PROVES it linked
this build (CHevcEncode's `lyte_hevc_noreset_enable()`), so no-reset
behavior is detected, never assumed.

## How a fresh checkout builds

```
Host/Scripts/vendor-ffmpeg.sh          # fetch (pinned), patch, build
                                       #  → Host/Vendor/ffmpeg/prefix
VP=$PWD/Host/Vendor/ffmpeg/prefix      # then, from Host/:
LYTE_FFMPEG_PREFIX=$VP PKG_CONFIG_PATH=$VP/lib/pkgconfig swift build
```

Two halves of one gate, both env (nothing changes on disk or in git):

- `PKG_CONFIG_PATH` swings the `CLibAV` system-library target
  (`pkgConfig: "libavcodec"`) to the vendored HEADERS, so CHevcEncode
  compiles against exactly what it links. The vendored `.pc` files
  carry NO `-lavcodec`/`-lavutil` (the script strips them at install):
  under search order those flags resolve the distro SHARED lib for
  lyte-host, because the other leaves' distro `.pc` files (pipewire,
  dbus, opus) inject `-L/usr/lib/<triple>` earlier in the link line
  (measured — lyte-encode-check went static, lyte-host didn't).
- `LYTE_FFMPEG_PREFIX` makes `Package.swift` link the static archives
  BY PATH into `lyte-host` and `lyte-encode-check` — a direct archive
  path has no search order to lose. Set-but-missing fails the
  manifest loudly — never a silent distro fallback. (Setting only
  `PKG_CONFIG_PATH` without this fails the link loudly on undefined
  avcodec symbols — also never silent.)

Verify after any build: `ldd .build/debug/lyte-host` must show no
libavcodec/libavutil, and the running host prints
`encoder: vendored no-reset libavcodec …` (the configuration marker —
proof, not assumption). Without the envs, `swift build` resolves the
distro FFmpeg exactly as before — macOS and CI never run the vendor
step (the C leaves are `#if os(Linux)`), and a Linux build without
the prefix stays green against distro.

When rsyncing a working tree to the reference host, exclude the build
products or every sync deletes the remote prefix:

```
rsync -a --delete --exclude .build \
  --exclude Vendor/ffmpeg/build --exclude Vendor/ffmpeg/prefix \
  Host/ pup:src/lyte-host/
```

## Carry-costs (named, accepted — squeeze review §3 + addendum)

- **Security tracking**: the pinned tarball no longer receives distro
  security updates; libavcodec here is ENCODE-ONLY (one encoder, zero
  decoders, no demuxers/parsers/network), which removes nearly all of
  the historical attack surface, but the pin must be bumped
  deliberately when upstream ships nvenc fixes.
- **Dual-libav symbol risk**: lyte-host links the static avcodec
  beside distro shared libs pulled by other leaves. Audited at HS-33:
  no other leaf (PipeWire, D-Bus, opus) pulls a shared libavcodec —
  `ldd` on the linked executables shows exactly one libav, ours.
- **Rebase cost**: the patch is ~6 lines against one function; a
  future FFmpeg bump re-applies it or re-derives it in minutes (the
  README you are reading is the spec).
