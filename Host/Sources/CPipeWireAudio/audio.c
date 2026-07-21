#include "lyte_pw_audio.h"

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The dialect's audio ground truth: Opus 48 kHz stereo in 5 ms frames.
   240/48000 as node.latency asks the graph for a 5 ms quantum; if the graph
   runs larger, callers slice — the leaf never buffers. */
#define LYTE_AUDIO_RATE     48000
#define LYTE_AUDIO_CHANNELS 2
#define LYTE_AUDIO_QUANTUM  240

struct lyte_pw_audio {
    struct pw_main_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_source *timer;

    lyte_pw_audio_cb cb;
    void *user;

    struct spa_audio_info_raw format;
    int have_format;
    uint64_t total_frames; /* fallback clock if pw_time is not ready yet */

    /* 0 = quit requested, 1 = timeout, -1 = error */
    int exit_reason;
    char error[256];
};

static void set_err(char *err, size_t errlen, const char *fmt, ...)
{
    if (!err || errlen == 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

static void on_stream_state_changed(void *data, enum pw_stream_state old,
                                    enum pw_stream_state state, const char *error)
{
    struct lyte_pw_audio *a = data;
    (void)old;
    if (state == PW_STREAM_STATE_ERROR) {
        snprintf(a->error, sizeof(a->error), "pipewire audio stream error: %s",
                 error ? error : "(unspecified)");
        a->exit_reason = -1;
        pw_main_loop_quit(a->loop);
    }
}

static void on_stream_param_changed(void *data, uint32_t id,
                                    const struct spa_pod *param)
{
    struct lyte_pw_audio *a = data;

    if (param == NULL || id != SPA_PARAM_Format)
        return;

    uint32_t media_type, media_subtype;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0)
        return;
    if (media_type != SPA_MEDIA_TYPE_audio ||
        media_subtype != SPA_MEDIA_SUBTYPE_raw)
        return;

    if (spa_format_audio_raw_parse(param, &a->format) < 0) {
        snprintf(a->error, sizeof(a->error),
                 "cannot parse negotiated audio format");
        a->exit_reason = -1;
        pw_main_loop_quit(a->loop);
        return;
    }
    if (a->format.format != SPA_AUDIO_FORMAT_F32) {
        snprintf(a->error, sizeof(a->error),
                 "negotiated audio format %u is not F32 interleaved",
                 a->format.format);
        a->exit_reason = -1;
        pw_main_loop_quit(a->loop);
        return;
    }
    a->have_format = 1;
}

static void on_stream_process(void *data)
{
    struct lyte_pw_audio *a = data;

    struct pw_buffer *b = pw_stream_dequeue_buffer(a->stream);
    if (b == NULL)
        return;

    struct spa_buffer *buf = b->buffer;
    struct spa_data *d = &buf->datas[0];

    if (a->have_format && d->data != NULL && d->chunk != NULL &&
        d->chunk->size > 0) {
        uint32_t channels = a->format.channels;
        uint32_t rate = a->format.rate;
        uint32_t n_frames = d->chunk->size / (sizeof(float) * channels);

        /* Graph-clock stamp. pw_time.ticks is the graph position after the
           delivered data (units of pw_time.rate, i.e. samples for audio);
           the buffer START is ticks - n_frames. Never wall clock. */
        struct pw_time t;
        uint64_t graph_us;
        if (pw_stream_get_time_n(a->stream, &t, sizeof(t)) == 0 &&
            t.rate.denom != 0) {
            uint64_t start_ticks =
                t.ticks >= n_frames ? t.ticks - n_frames : 0;
            graph_us = start_ticks * (uint64_t)SPA_USEC_PER_SEC *
                       t.rate.num / t.rate.denom;
        } else {
            graph_us = a->total_frames * (uint64_t)SPA_USEC_PER_SEC / rate;
        }
        a->total_frames += n_frames;

        a->cb(a->user,
              (const float *)((const uint8_t *)d->data + d->chunk->offset),
              n_frames, channels, rate, graph_us);
    }

    pw_stream_queue_buffer(a->stream, b);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_stream_state_changed,
    .param_changed = on_stream_param_changed,
    .process = on_stream_process,
};

static void on_timeout(void *data, uint64_t expirations)
{
    struct lyte_pw_audio *a = data;
    (void)expirations;
    a->exit_reason = 1;
    pw_main_loop_quit(a->loop);
}

lyte_pw_audio *lyte_pw_audio_new(lyte_pw_audio_cb cb, void *user,
                                 char *err, size_t errlen)
{
    pw_init(NULL, NULL);

    struct lyte_pw_audio *a = calloc(1, sizeof(*a));
    if (!a) {
        set_err(err, errlen, "out of memory");
        return NULL;
    }
    a->cb = cb;
    a->user = user;
    a->exit_reason = 1;

    a->loop = pw_main_loop_new(NULL);
    if (!a->loop) {
        set_err(err, errlen, "pw_main_loop_new failed");
        goto fail;
    }

    a->context = pw_context_new(pw_main_loop_get_loop(a->loop), NULL, 0);
    if (!a->context) {
        set_err(err, errlen, "pw_context_new failed");
        goto fail;
    }

    a->core = pw_context_connect(a->context, NULL, 0);
    if (!a->core) {
        set_err(err, errlen, "pw_context_connect failed");
        goto fail;
    }

    /* stream.capture.sink is the canonical monitor trick: a capture stream
       carrying it links to the DEFAULT SINK's monitor ports (and follows
       default-sink switches) — no registry scan, no node-name matching.
       Unlike the video leaf there is no portal node id to pin by serial. */
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Music",
        PW_KEY_STREAM_CAPTURE_SINK, "true",
        PW_KEY_NODE_LATENCY, "240/48000",
        NULL);
    if (!props) {
        set_err(err, errlen, "pw_properties_new failed");
        goto fail;
    }

    a->stream = pw_stream_new(a->core, "lyte-host-audio", props);
    if (!a->stream) {
        set_err(err, errlen, "pw_stream_new failed");
        goto fail;
    }
    pw_stream_add_listener(a->stream, &a->stream_listener, &stream_events, a);

    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    struct spa_audio_info_raw info = {
        .format = SPA_AUDIO_FORMAT_F32,
        .rate = LYTE_AUDIO_RATE,
        .channels = LYTE_AUDIO_CHANNELS,
    };
    params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);

    if (pw_stream_connect(a->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                          PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
                          params, 1) < 0) {
        set_err(err, errlen, "pw_stream_connect failed for sink monitor");
        goto fail;
    }

    return a;

fail:
    lyte_pw_audio_free(a);
    return NULL;
}

int lyte_pw_audio_run(lyte_pw_audio *a, double timeout_sec,
                      char *err, size_t errlen)
{
    a->timer = pw_loop_add_timer(pw_main_loop_get_loop(a->loop), on_timeout, a);
    if (a->timer) {
        struct timespec value = {
            .tv_sec = (time_t)timeout_sec,
            .tv_nsec = (long)((timeout_sec - (time_t)timeout_sec) * 1e9),
        };
        pw_loop_update_timer(pw_main_loop_get_loop(a->loop), a->timer,
                             &value, NULL, false);
    }

    pw_main_loop_run(a->loop);

    if (a->exit_reason == -1)
        set_err(err, errlen, "%s", a->error);
    return a->exit_reason;
}

void lyte_pw_audio_quit(lyte_pw_audio *a)
{
    a->exit_reason = 0;
    pw_main_loop_quit(a->loop);
}

void lyte_pw_audio_free(lyte_pw_audio *a)
{
    if (!a)
        return;
    if (a->stream)
        pw_stream_destroy(a->stream);
    if (a->core)
        pw_core_disconnect(a->core);
    if (a->context)
        pw_context_destroy(a->context);
    if (a->loop)
        pw_main_loop_destroy(a->loop);
    free(a);
}
