#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Desktop-audio capture leaf: a PipeWire CAPTURE stream on the default
   sink's monitor (PW_KEY_STREAM_CAPTURE_SINK — the session manager links
   us to whatever the default sink is, and follows default-sink changes).
   Requests F32 interleaved 48 kHz stereo (PipeWire's native graph format,
   so no resample/convert stage runs) with node.latency 240/48000 to ask
   for a 5 ms quantum. The graph may still run a larger quantum; callers
   slice to exact Opus frames themselves. */

/* Called on the capture loop thread for every dequeued buffer.
   `samples` is interleaved F32 at the negotiated `rate`/`channels`
   (48000/2 unless negotiation surprised us), valid only for the duration
   of the call. `graph_us` is the PipeWire graph-clock position of the
   START of this buffer, in microseconds — derived from pw_time.ticks
   (which timestamps the END of the delivered data), never wall clock.
   Monotonic while the graph runs; jumps reveal dropped cycles. */
typedef void (*lyte_pw_audio_cb)(void *user, const float *samples,
                                 uint32_t n_frames, uint32_t channels,
                                 uint32_t rate, uint64_t graph_us);

typedef struct lyte_pw_audio lyte_pw_audio;

/* Connects to the user's default PipeWire remote and prepares the monitor
   capture stream. Returns NULL with `err` filled on failure. */
lyte_pw_audio *lyte_pw_audio_new(lyte_pw_audio_cb cb, void *user,
                                 char *err, size_t errlen);

/* Runs the capture loop on the calling thread.
   Returns 0 when quit via lyte_pw_audio_quit,
           1 when timeout_sec elapsed,
          -1 on stream error (err filled). */
int lyte_pw_audio_run(lyte_pw_audio *a, double timeout_sec,
                      char *err, size_t errlen);

/* Requests loop exit; callable from within the audio callback. */
void lyte_pw_audio_quit(lyte_pw_audio *a);

void lyte_pw_audio_free(lyte_pw_audio *a);

#ifdef __cplusplus
}
#endif
