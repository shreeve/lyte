#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pixel layouts the capture negotiates. All are 32bpp packed RGB variants
   that hevc_nvenc consumes directly (no swscale stage). */
typedef enum {
    LYTE_PIXFMT_UNKNOWN = 0,
    LYTE_PIXFMT_BGRX = 1, /* AV: bgr0 */
    LYTE_PIXFMT_BGRA = 2, /* AV: bgra */
    LYTE_PIXFMT_RGBX = 3, /* AV: rgb0 */
    LYTE_PIXFMT_RGBA = 4, /* AV: rgba */
} lyte_pixfmt;

/* Called on the capture loop thread for every dequeued video frame.
   `data` points at the mapped buffer; valid only for the duration of the
   call. `graph_us` is the frame's capture timestamp in graph-clock
   microseconds (CLOCK_MONOTONIC domain): the buffer's spa_meta_header
   pts when the compositor stamps it, the stream's pw_time position
   otherwise, monotonic-now as the last resort — never wall clock. */
typedef void (*lyte_pw_frame_cb)(void *user, const uint8_t *data, uint32_t size,
                                 int32_t stride, uint32_t width, uint32_t height,
                                 lyte_pixfmt fmt, uint64_t graph_us);

/* Called on the capture loop thread at the interval given to
   lyte_pw_capture_set_tick. Serialized with frame callbacks (same thread,
   same loop), so callers need no locking between the two. */
typedef void (*lyte_pw_tick_cb)(void *user);

typedef struct lyte_pw_capture lyte_pw_capture;

/* Bounded liveness evidence for the policy layer's starvation diagnostic.
   Counters are monotonic for one capture object and read on the same
   PipeWire loop thread as callbacks. `stream_state` is pw_stream_state's
   integer value; keeping the C ABI free of PipeWire headers is deliberate. */
typedef struct {
    uint64_t process_callbacks;
    uint64_t dequeue_empty;
    uint64_t buffer_empty;
    uint64_t frames_delivered;
    uint64_t last_process_monotonic_ns;
    int32_t stream_state;
} lyte_pw_capture_stats;

/* Connects to the PipeWire remote on `pipewire_fd` (from the portal's
   OpenPipeWireRemote) and prepares an input stream targeting `node_id`.
   Returns NULL with `err` filled on failure. */
lyte_pw_capture *lyte_pw_capture_new(int pipewire_fd, uint32_t node_id,
                                     lyte_pw_frame_cb frame_cb, void *user,
                                     char *err, size_t errlen);

/* Optional repeating tick, armed when lyte_pw_capture_run starts. Call
   before lyte_pw_capture_run. The policy (what a tick means) is the
   caller's; this leaf only guarantees delivery on the loop thread.
   Returns 0 on success, -1 on bad arguments. */
int lyte_pw_capture_set_tick(lyte_pw_capture *c, uint64_t interval_ns,
                             lyte_pw_tick_cb tick_cb, void *user);

/* Runs the capture loop on the calling thread.
   Returns 0 when quit via lyte_pw_capture_quit,
           1 when timeout_sec elapsed,
          -1 on stream error (err filled). */
int lyte_pw_capture_run(lyte_pw_capture *c, double timeout_sec,
                        char *err, size_t errlen);

/* Takes a non-mutating snapshot for bounded diagnostics. */
void lyte_pw_capture_get_stats(const lyte_pw_capture *c,
                               lyte_pw_capture_stats *out);

/* Requests loop exit; callable from within the frame callback. */
void lyte_pw_capture_quit(lyte_pw_capture *c);

void lyte_pw_capture_free(lyte_pw_capture *c);

#ifdef __cplusplus
}
#endif
