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
   the duration of the call. `keyframe` is nonzero for IDR packets. */
typedef void (*lyte_hevc_packet_cb)(void *user, const uint8_t *data,
                                    size_t size, int keyframe);

/* Opens hevc_nvenc with the Sunshine low-latency recipe: true CBR
   (max=min=bitrate), single-frame VBV, GOP INT_MAX, zero B-frames, preset
   p1 + ull tuning, zero reorder delay, one surface in flight.
   `pix_fmt_name` is an FFmpeg pixel format name ("bgr0", "bgra", "rgb0",
   "rgba"). Returns NULL with `err` filled on failure. */
lyte_hevc_enc *lyte_hevc_enc_new(int width, int height,
                                 const char *pix_fmt_name,
                                 int fps, int64_t bit_rate,
                                 char *err, size_t errlen);

/* Encodes one packed-RGB frame (single plane, `src_stride` bytes per row).
   `force_idr` nonzero forces an IDR picture. Returns 0 on success, -1 on
   error with `err` filled. */
int lyte_hevc_enc_send(lyte_hevc_enc *e, const uint8_t *data, int src_stride,
                       int64_t pts, int force_idr,
                       lyte_hevc_packet_cb cb, void *user,
                       char *err, size_t errlen);

/* Drains the encoder. Returns 0 on success, -1 on error. */
int lyte_hevc_enc_flush(lyte_hevc_enc *e, lyte_hevc_packet_cb cb, void *user,
                        char *err, size_t errlen);

void lyte_hevc_enc_free(lyte_hevc_enc *e);

#ifdef __cplusplus
}
#endif
