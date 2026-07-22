#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Desktop-audio capture leaf, two routing modes (HS-18):
 *
 *   hostAudible (mode 0, HS-14's original): a PipeWire CAPTURE stream
 *   on the default sink's monitor (PW_KEY_STREAM_CAPTURE_SINK — the
 *   session manager links us to whatever the default sink is, and
 *   follows default-sink changes). The host's speakers keep playing.
 *
 *   hostMuted (mode 1): create a virtual "Lyte Audio" null sink
 *   (support.null-audio-sink via the adapter factory — a server-side
 *   object OWNED BY THIS CONNECTION, so a killed process can never
 *   leak the sink: the server destroys it when the socket closes),
 *   save the current default.configured.audio.sink metadata value,
 *   switch the default to the Lyte sink, and capture ITS monitor.
 *   Sound flows only to the wire; the physical output goes silent.
 *   lyte_pw_audio_restore / _free put the saved default back exactly.
 *   The metadata value is the one thing a SIGKILL can strand — the
 *   caller persists it (lyte_pw_audio_saved_default) and sweeps a
 *   dirty previous run with lyte_pw_audio_restore_default on the next
 *   start.
 *
 * Both modes request F32 interleaved 48 kHz stereo (PipeWire's native
 * graph format, so no resample/convert stage runs) with node.latency
 * 240/48000 and node.force-quantum 240 — the HS-15 lesson: the 5 ms
 * pipeline must be IDENTICAL in both modes, quantum forcing included.
 * The graph may still deliver larger buffers; callers slice to exact
 * Opus frames themselves. */

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

/* Connects to the user's default PipeWire remote and prepares the
   capture stream. `mute_host` nonzero selects the virtual-sink
   hostMuted mode described above (sink created + default switched
   before this returns); zero is the classic default-sink-monitor
   capture. Returns NULL with `err` filled on failure — a hostMuted
   setup failure restores anything it had already changed. */
lyte_pw_audio *lyte_pw_audio_new(lyte_pw_audio_cb cb, void *user,
                                 int mute_host, char *err, size_t errlen);

/* Runs the capture loop on the calling thread.
   Returns 0 when quit via lyte_pw_audio_quit,
           1 when timeout_sec elapsed,
          -1 on stream error (err filled). */
int lyte_pw_audio_run(lyte_pw_audio *a, double timeout_sec,
                      char *err, size_t errlen);

/* Requests loop exit; callable from within the audio callback. */
void lyte_pw_audio_quit(lyte_pw_audio *a);

/* hostMuted only: the default.configured.audio.sink metadata VALUE
   (a JSON string like {"name":"alsa_output..."}) that was in force
   before the switch. Returns 1 and copies it into buf when one
   existed, 0 when the property was unset (restore = clear), -1 when
   not in hostMuted mode. Callers persist this for the crash sweep. */
int lyte_pw_audio_saved_default(lyte_pw_audio *a, char *buf, size_t buflen);

/* hostMuted only: put the saved default back (or clear the property
   if none was set) and flush the change to the server. Idempotent;
   also runs inside lyte_pw_audio_free. Safe to call after run()
   returned. Returns 0 on success, -1 with err filled. */
int lyte_pw_audio_restore(lyte_pw_audio *a, char *err, size_t errlen);

void lyte_pw_audio_free(lyte_pw_audio *a);

/* Standalone sweep helper for a previous run that died without
   restoring (SIGKILL): one-shot connection that sets
   default.configured.audio.sink to `saved_json` — or clears the
   property when `saved_json` is NULL — and disconnects. The dead
   run's sink itself never survives (connection-owned); only the
   metadata can be stranded. Returns 0 on success, -1 with err. */
int lyte_pw_audio_restore_default(const char *saved_json,
                                  char *err, size_t errlen);

#ifdef __cplusplus
}
#endif
