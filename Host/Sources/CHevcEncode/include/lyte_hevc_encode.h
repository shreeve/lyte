#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Line-buffer stdout so progress prints appear promptly when piped over ssh
   (Swift cannot touch libc's `stdout` global under strict concurrency). */
void lyte_stdout_linebuf(void);
void lyte_stdout_flush(void);

typedef struct lyte_hevc_enc lyte_hevc_enc;

/* Called for every encoded packet. `data` is Annex-B bytes, valid only for
   the duration of the call. `keyframe` is nonzero for IDR packets. `avg_qp`
   is the frame-average QP nvenc reports for the packet (-1 if unknown) —
   the ratchet policy layer reads convergence off it. */
typedef void (*lyte_hevc_packet_cb)(void *user, const uint8_t *data,
                                    size_t size, int keyframe, int avg_qp);

/* Opens hevc_nvenc with the caller's recipe on the fixed low-latency
   frame (GOP INT_MAX, zero B-frames, zero reorder delay, one surface in
   flight — those are latency invariants, not knobs). The recipe knobs
   (HS-24, the encoder A/B ladder) are explicit; the DEFAULT lives in
   Swift (HostCore.EncoderRecipe, test-pinned), not here:
     `preset`     "p1".."p7" (NVENC perf→quality ladder)
     `tune`       "ull" | "ll" (tuning owns the latency shape; both
                  forbid lookahead/B-frames at our delay=0 posture)
     `multipass`  "disabled" | "qres" | "fullres"
     `spatial_aq` / `temporal_aq`  0/1 (temporal AQ needs lookahead on
                  this wrapper — expected to fail to open; the ladder
                  records that as evidence)
     `aq_strength` 1..15, or 0 to leave nvenc's default
   Unknown knob values fail the open with `err` filled — the A/B harness
   depends on a loud reject, not a silent fallback.
   Rate control by `cq`:
     cq == 0: true CBR (max=min=bitrate), single-frame VBV, qmin 23 —
              the committed slice-2 recipe.
     cq  > 0: capped-CQ VBR — rc=vbr with constant-quality target `cq` and
              `bit_rate` as the hard max-rate cap. FFmpeg's nvenc wrapper
              discards avg-bitrate/VBV in CQ mode and honors only the cap.
              Under this mode nvenc itself walks QP down toward `cq` across
              repeated identical frames (the quality-ratchet mechanism);
              note the walk overshoots a few QP below `cq` — `cq` is a soft
              target, not a floor.
   `pix_fmt_name` is an FFmpeg pixel format name; the plumbed set is
   packed RGB ("bgr0", "bgra", "rgb0", "rgba"), "gbrp" (planar RGB —
   the Rext identity-matrix 4:4:4 path; send() still takes packed BGRx
   and the leaf repacks), and "yuv444p" (pre-converted planar input).
   Anything else fails the open loudly.
   H4 probe knobs (V-1): `profile` "main"|"main10"|"rext" and `rgb_mode`
   "yuv420"|"yuv444" (how the wrapper handles packed-RGB input) pass
   through to the wrapper when non-empty; empty leaves the wrapper's
   default. The VUI color signing follows the input path: packed RGB →
   BT.601 limited (the wrapper's forced internal-conversion truth,
   Stage A), gbrp → identity/GBR full-range, yuv444p → BT.709
   full-range (the conversion contract). Transfer is sRGB on every path.
   Returns NULL with `err` filled on failure. */
lyte_hevc_enc *lyte_hevc_enc_new(int width, int height,
                                 const char *pix_fmt_name,
                                 int fps, int64_t bit_rate, int cq,
                                 const char *preset, const char *tune,
                                 const char *multipass,
                                 int spatial_aq, int temporal_aq,
                                 int aq_strength,
                                 const char *profile,
                                 const char *rgb_mode,
                                 char *err, size_t errlen);

/* Encodes one frame. For packed-RGB and gbrp opens, `data` is packed
   BGRx (single plane, `src_stride` bytes per row) — the gbrp path
   repacks to planes inside the leaf. For yuv444p opens, `data` is
   three tightly-packed w×h planes and `src_stride` is ignored.
   `force_idr` nonzero forces an IDR picture. Returns 0 on success, -1 on
   error with `err` filled. */
int lyte_hevc_enc_send(lyte_hevc_enc *e, const uint8_t *data, int src_stride,
                       int64_t pts, int force_idr,
                       lyte_hevc_packet_cb cb, void *user,
                       char *err, size_t errlen);

/* Total wall-clock µs spent in the BGRx→gbrp repack across all send()
   calls (0 unless the encoder was opened with "gbrp") — the V-1 probe's
   repack-cost book. */
uint64_t lyte_hevc_enc_repack_us_total(const lyte_hevc_enc *e);

/* Reconfigures the open encoder's rate control mid-stream (HS-20: the
   congestion controller's frameByteCeiling finally reaches NVENC).
   `avg_bits` <= 0 leaves the average bitrate untouched (capped-CQ mode
   has none and must keep none); `max_bits` and `vbv_bits` set
   rc_max_rate and rc_buffer_size. In CBR mode rc_min_rate follows the
   average (min = avg = max is the CBR contract). FFmpeg's nvenc wrapper
   picks the changed fields up on the next avcodec_send_frame and issues
   one NvEncReconfigureEncoder. WHAT THAT COSTS depends on the linked
   libavcodec (HS-33): upstream/distro sets resetEncoder=1 + forceIDR=1
   for ANY rate delta (the HS-22 correction — every move is a hidden
   full IDR); the vendored no-reset build (Scripts/vendor-ffmpeg.sh)
   reconfigures in place — zero reset, zero IDR — when
   LYTE_NVENC_NO_RESET_RATE=1 (see lyte_hevc_noreset_enable below).
   Returns 0 on success, -1 with `err` filled. */
int lyte_hevc_enc_set_rate(lyte_hevc_enc *e, int64_t avg_bits,
                           int64_t max_bits, int64_t vbv_bits,
                           char *err, size_t errlen);

/* HS-33: detect the vendored no-reset libavcodec and default its env
   gate ON. The vendored build (Scripts/vendor-ffmpeg.sh) is configured
   with --extra-version=lyte-noreset, so `avcodec_configuration()`
   carries the marker — the running process PROVES which libavcodec it
   linked instead of assuming. When the marker is present and
   LYTE_NVENC_NO_RESET_RATE is unset, this sets it to "1" (the patched
   wrapper reads it at reconfigure time); an explicit "0" is respected
   — the A/B control that forces the upstream reset+IDR path through
   the same binary. Returns 1 iff no-reset rate moves are ACTIVE
   (vendored lib AND gate enabled); always 0 under distro libavcodec,
   where the env is inert. Call once at startup, before any encoding. */
int lyte_hevc_noreset_enable(void);

/* Drains the encoder. Returns 0 on success, -1 on error. */
int lyte_hevc_enc_flush(lyte_hevc_enc *e, lyte_hevc_packet_cb cb, void *user,
                        char *err, size_t errlen);

void lyte_hevc_enc_free(lyte_hevc_enc *e);

#ifdef __cplusplus
}
#endif
