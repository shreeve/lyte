#!/usr/bin/env bash
# vendor-ffmpeg.sh (HS-33) — build the vendored no-reset FFmpeg.
#
# Produces Host/Vendor/ffmpeg/prefix/lib/{libavcodec.a,libavutil.a}
# (+ headers + pkgconfig): a minimal static libavcodec with ONLY the
# hevc_nvenc encoder, patched so a rate/VBV reconfigure no longer
# resets the encoder or mints an IDR (gated on env
# LYTE_NVENC_NO_RESET_RATE=1 — one binary A/Bs both behaviors; a DAR
# change always keeps the upstream reset path). Full rationale,
# evidence, and link mechanics: Host/Vendor/ffmpeg/README.md; the
# hardware validation is the HS-33a wave entry in HANDOFF.md.
#
# Re-runnable: inputs are fetched only if absent and verified against
# the pins below on EVERY run; a prior build is reused unless the
# source tree is gone. `rm -rf Host/Vendor/ffmpeg/{build,prefix}` for
# a from-scratch rebuild. Nothing here is committed — the script is
# the artifact.
#
# Then link it (from Host/):
#   PKG_CONFIG_PATH=$PWD/Vendor/ffmpeg/prefix/lib/pkgconfig swift build
# and verify: ldd .build/debug/lyte-host shows no shared libavcodec.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$(cd "$SCRIPT_DIR/../Vendor/ffmpeg" && pwd)"
BUILD="$VENDOR/build"
PREFIX="$VENDOR/prefix"
PATCH="$VENDOR/nvenc-no-reset-rate.patch"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"

# The pins (Host/Vendor/ffmpeg/README.md documents each):
FFMPEG_VER="8.0.1"           # the exact upstream tag behind the
                             # reference host's distro 7:8.0.1-3ubuntu2
FFMPEG_SHA256="05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41"
NVH_TAG="n13.0.19.1"         # SDK 13.0: min driver 570 (pup: 595.84);
                             # n13.1.x wants 610+ — too new
NVH_COMMIT="88fee5c37318c991a8762d423530f91681e32e3a"

case "$(uname -s)" in
  Linux) ;;
  *) echo "vendor-ffmpeg: Linux only (the CHevcEncode leaf is" \
         "#if os(Linux); macOS never links libav)" >&2; exit 1;;
esac

mkdir -p "$BUILD"
cd "$BUILD"

# --- nv-codec-headers, pinned by tag AND commit ------------------------------
if [ ! -d nv-codec-headers ]; then
    git clone -q https://github.com/FFmpeg/nv-codec-headers.git
fi
git -C nv-codec-headers checkout -q "$NVH_TAG"
ACTUAL_NVH="$(git -C nv-codec-headers rev-parse HEAD)"
if [ "$ACTUAL_NVH" != "$NVH_COMMIT" ]; then
    echo "vendor-ffmpeg: nv-codec-headers $NVH_TAG resolves to" \
         "$ACTUAL_NVH, expected $NVH_COMMIT — refusing" >&2
    exit 1
fi
make -C nv-codec-headers install PREFIX="$PREFIX" >/dev/null

# --- ffmpeg source, pinned by sha256 -----------------------------------------
TARBALL="ffmpeg-$FFMPEG_VER.tar.xz"
if [ ! -f "$TARBALL" ]; then
    curl -sfLO "https://ffmpeg.org/releases/$TARBALL"
fi
echo "$FFMPEG_SHA256  $TARBALL" | sha256sum -c - >/dev/null || {
    echo "vendor-ffmpeg: $TARBALL sha256 mismatch — refusing" >&2
    exit 1
}
if [ ! -d "ffmpeg-$FFMPEG_VER" ]; then
    tar xf "$TARBALL"
fi
cd "ffmpeg-$FFMPEG_VER"

# --- the no-reset patch (idempotent) -----------------------------------------
if ! grep -q LYTE_NVENC_NO_RESET_RATE libavcodec/nvenc.c; then
    patch -p1 < "$PATCH"
fi

# --- configure ----------------------------------------------------------------
# Rationale per flag:
#   --disable-everything        no components except what we re-enable
#   --disable-autodetect        no ambient external libs (zlib, vaapi, …)
#                               leak into the archive's link-time needs
#   --enable-ffnvcodec/cuda/nvenc  autodetect-listed, so with autodetect
#                               off all three must be explicit
#   --enable-encoder=hevc_nvenc the component the CHevcEncode leaf uses
#   --enable-vaapi/hevc_vaapi   the direct eye's Arc/iGPU encode leaf
#                               (docs/20260801-direct-eye-plan.md §3:
#                               panel-owning-die encode; pup has no MUX).
#                               vaapi is autodetect-listed, so explicit;
#                               pulls libva/libva-drm into the link tail
#                               (Package.swift adds -lva -lva-drm)
#   --disable-avformat/avfilter/avdevice/swscale/swresample  CLibAV
#                               consumers touch only avcodec+avutil
#   --disable-x86asm            hevc_nvenc has no SIMD; no yasm needed
#   --enable-pic                the .a links into PIE Swift executables
#   --disable-shared/--enable-static  the distro shared libavcodec62
#                               stays untouched; static is the point
#   --extra-version=lyte-noreset  the marker lyte_hevc_noreset_enable()
#                               reads from avcodec_configuration() to
#                               PROVE the vendored lib is the one linked
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure \
    --prefix="$PREFIX" \
    --extra-version=lyte-noreset \
    --disable-everything \
    --disable-autodetect \
    --disable-programs \
    --disable-doc \
    --disable-avdevice \
    --disable-avformat \
    --disable-avfilter \
    --disable-swscale \
    --disable-swresample \
    --disable-network \
    --disable-x86asm \
    --disable-shared \
    --enable-static \
    --enable-pic \
    --enable-ffnvcodec \
    --enable-cuda \
    --enable-nvenc \
    --enable-encoder=hevc_nvenc \
    --enable-vaapi \
    --enable-encoder=hevc_vaapi \
    > "$BUILD/configure.log" 2>&1 || {
        tail -30 "$BUILD/configure.log" >&2; exit 1; }

make -j"$JOBS" > "$BUILD/make.log" 2>&1 || {
    tail -30 "$BUILD/make.log" >&2; exit 1; }
make install >/dev/null

# Neutralize the installed .pc link flags (headers/Cflags stay). The
# archives are linked BY PATH via Package.swift's LYTE_FFMPEG_PREFIX
# gate; leaving `-L${libdir} -lavcodec` here loses to link-line search
# order — the distro .pc files of the other leaves (pipewire, dbus,
# opus) inject -L/usr/lib/<triple> EARLIER, so `-lavcodec` resolves
# the distro SHARED lib for lyte-host (measured at HS-33). The system
# tail (-pthread -lm -latomic) stays: the .a carries no DT_NEEDED.
sed -i -E 's/^Libs: .*/Libs: -pthread -lm -latomic/' \
    "$PREFIX/lib/pkgconfig/libavcodec.pc" \
    "$PREFIX/lib/pkgconfig/libavutil.pc"

# --- prove the build is what we think it is ----------------------------------
# Exactly two encoders (nvenc + the eye's vaapi), zero decoders/
# parsers/demuxers; the patch and the marker both present.
ENCODERS="$(grep -c '^#define CONFIG_.*_ENCODER 1$' config_components.h)"
DECODERS="$(grep -c '^#define CONFIG_.*_DECODER 1$' config_components.h || true)"
grep -q '^#define CONFIG_HEVC_NVENC_ENCODER 1$' config_components.h
grep -q '^#define CONFIG_HEVC_VAAPI_ENCODER 1$' config_components.h
[ "$ENCODERS" = 2 ] || { echo "expected 2 encoders, got $ENCODERS" >&2; exit 1; }
[ "$DECODERS" = 0 ] || { echo "expected 0 decoders, got $DECODERS" >&2; exit 1; }
grep -q LYTE_NVENC_NO_RESET_RATE libavcodec/nvenc.c
grep -q 'lyte-noreset' config.h

echo "== vendored ffmpeg installed =="
ls -la "$PREFIX/lib/"*.a
echo "encoders=2 (hevc_nvenc hevc_vaapi) decoders=0; marker lyte-noreset present"
echo "link with: PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig swift build"
