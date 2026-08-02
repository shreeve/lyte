#include "lyte_pw_audio.h"

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/dict.h>

#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The dialect's audio ground truth: Opus 48 kHz stereo in 5 ms frames.
   240/48000 as node.latency asks the graph for a 5 ms quantum; if the graph
   runs larger, callers slice — the leaf never buffers. */
#define LYTE_AUDIO_RATE     48000
#define LYTE_AUDIO_CHANNELS 2
#define LYTE_AUDIO_QUANTUM  240

/* The virtual sink's identity (HS-18 hostMuted). node.name is the
   metadata handle ({"name":...}) and the capture target; the
   description is what mixers display. */
#define LYTE_SINK_NAME "lyte-audio-sink"
#define LYTE_SINK_DESC "Lyte Audio"

/* WirePlumber's user-preference key: what wpctl set-default writes.
   default.audio.sink is the COMPUTED current default (wireplumber's
   output) — a client expresses preference through the configured key
   and never writes the computed one. */
#define DEFAULT_SINK_KEY "default.configured.audio.sink"

struct lyte_pw_audio {
    struct pw_main_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct spa_hook core_listener;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_source *timer;

    lyte_pw_audio_cb cb;
    void *user;

    struct spa_audio_info_raw format;
    int have_format;
    uint64_t total_frames; /* fallback clock if pw_time is not ready yet */

    /* 0 = quit requested, 1 = timeout, -1 = error. Atomic: quit()
       stores from the session thread while the loop thread writes
       error/timeout verdicts (A-24). */
    _Atomic int exit_reason;
    char error[256];

    /* --- hostMuted (virtual sink) state --- */
    int mute_host;
    struct pw_registry *registry;
    struct spa_hook registry_listener;
    struct pw_metadata *metadata;      /* the "default" metadata object */
    struct spa_hook metadata_listener;
    struct pw_proxy *sink_proxy;       /* our connection-owned null sink */
    int sink_seen;                     /* the sink's global appeared */
    int capture_defaults;              /* record DEFAULT_SINK_KEY replays */
    int have_saved_default;            /* 1 = saved_default holds a value */
    char saved_default[512];           /* original DEFAULT_SINK_KEY value */
    int default_switched;              /* we own the key until restored */
    int restored;

    /* roundtrip plumbing (the pw_core_sync/done pattern) */
    int sync_seq;
    int sync_pending;
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

/* --- core events: the roundtrip's done edge + loud protocol errors --- */

static void on_core_done(void *data, uint32_t id, int seq)
{
    struct lyte_pw_audio *a = data;
    if (id == PW_ID_CORE && a->sync_pending && seq == a->sync_seq) {
        a->sync_pending = 0;
        pw_main_loop_quit(a->loop);
    }
}

static void on_core_error(void *data, uint32_t id, int seq, int res,
                          const char *message)
{
    struct lyte_pw_audio *a = data;
    (void)seq;
    /* Setup-time protocol errors must not hang a roundtrip. Errors on
       other objects during streaming surface via the stream state. */
    if (id == PW_ID_CORE) {
        snprintf(a->error, sizeof(a->error),
                 "pipewire core error %d: %s", res,
                 message ? message : "(unspecified)");
        a->exit_reason = -1;
        pw_main_loop_quit(a->loop);
    }
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = on_core_done,
    .error = on_core_error,
};

/* A wedged server must not hang setup or restore (A-19: exit used to
   block forever with the desktop's default sink still pointed at
   "Lyte Audio"). Generous for a local-socket sync; the next-start
   sweep backstops an abandoned restore. */
#define ROUNDTRIP_TIMEOUT_SEC 2

static void on_roundtrip_timeout(void *data, uint64_t expirations)
{
    struct lyte_pw_audio *a = data;
    (void)expirations;
    if (!a->sync_pending)
        return;
    a->sync_pending = 0;
    snprintf(a->error, sizeof(a->error),
             "pipewire roundtrip timed out (%ds)", ROUNDTRIP_TIMEOUT_SEC);
    a->exit_reason = -1;
    pw_main_loop_quit(a->loop);
}

/* One server roundtrip: everything we asked for before the sync is
   processed (and its events delivered) before this returns. Returns
   0, or -1 when the core reported an error mid-trip or the guard
   timer expired. */
static int roundtrip(struct lyte_pw_audio *a)
{
    struct pw_loop *loop = pw_main_loop_get_loop(a->loop);
    struct spa_source *guard =
        pw_loop_add_timer(loop, on_roundtrip_timeout, a);
    if (guard) {
        struct timespec value = { .tv_sec = ROUNDTRIP_TIMEOUT_SEC };
        pw_loop_update_timer(loop, guard, &value, NULL, false);
    }
    a->sync_pending = 1;
    a->sync_seq = pw_core_sync(a->core, PW_ID_CORE, 0);
    pw_main_loop_run(a->loop);
    if (guard)
        pw_loop_destroy_source(loop, guard);
    return a->exit_reason == -1 ? -1 : 0;
}

/* --- registry + metadata (hostMuted only) --- */

static int on_metadata_property(void *data, uint32_t subject,
                                const char *key, const char *type,
                                const char *value)
{
    struct lyte_pw_audio *a = data;
    (void)type;
    /* Existing properties replay when the listener attaches; the
       original default is whatever the replay window shows. Later
       events (our own set included) must not clobber the saved
       value, hence the capture flag. */
    if (a->capture_defaults && subject == PW_ID_CORE && key &&
        strcmp(key, DEFAULT_SINK_KEY) == 0 && value) {
        snprintf(a->saved_default, sizeof(a->saved_default), "%s", value);
        a->have_saved_default = 1;
    }
    return 0;
}

static const struct pw_metadata_events metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = on_metadata_property,
};

static void on_registry_global(void *data, uint32_t id, uint32_t permissions,
                               const char *type, uint32_t version,
                               const struct spa_dict *props)
{
    struct lyte_pw_audio *a = data;
    (void)permissions;
    (void)version;

    if (!a->metadata && props &&
        strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0) {
        const char *name = spa_dict_lookup(props, PW_KEY_METADATA_NAME);
        if (name && strcmp(name, "default") == 0) {
            a->metadata = pw_registry_bind(a->registry, id, type,
                                           PW_VERSION_METADATA, 0);
            if (a->metadata)
                pw_metadata_add_listener(a->metadata, &a->metadata_listener,
                                         &metadata_events, a);
        }
        return;
    }
    if (props && strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
        const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
        if (name && strcmp(name, LYTE_SINK_NAME) == 0)
            a->sink_seen = 1;
    }
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = on_registry_global,
};

/* Create the null sink, save the original default, switch the default
   to us. Called from _new before the capture stream exists, so the
   only loop-quitting handlers live on the core. */
static int setup_virtual_sink(struct lyte_pw_audio *a,
                              char *err, size_t errlen)
{
    a->registry = pw_core_get_registry(a->core, PW_VERSION_REGISTRY, 0);
    if (!a->registry) {
        set_err(err, errlen, "pw_core_get_registry failed");
        return -1;
    }
    pw_registry_add_listener(a->registry, &a->registry_listener,
                             &registry_events, a);

    /* Trip 1: registry globals arrive; the handler binds the "default"
       metadata. Trip 2: the freshly bound metadata replays its
       properties — the original default is captured there. */
    a->capture_defaults = 1;
    if (roundtrip(a) < 0)
        goto core_error;
    if (!a->metadata) {
        set_err(err, errlen, "no \"default\" metadata object — is "
                "wireplumber running? hostMuted needs the session "
                "manager's default-sink switch");
        return -1;
    }
    if (roundtrip(a) < 0)
        goto core_error;
    a->capture_defaults = 0;

    /* The sink: support.null-audio-sink through the adapter factory —
       the same object pactl's module-null-sink makes, but owned by
       THIS connection: the server destroys it when our socket closes,
       so a SIGKILLed host can never leak a sink. */
    struct pw_properties *props = pw_properties_new(
        PW_KEY_FACTORY_NAME, "support.null-audio-sink",
        PW_KEY_NODE_NAME, LYTE_SINK_NAME,
        PW_KEY_NODE_DESCRIPTION, LYTE_SINK_DESC,
        PW_KEY_MEDIA_CLASS, "Audio/Sink",
        PW_KEY_NODE_VIRTUAL, "true",
        "audio.channels", "2",
        "audio.position", "[ FL FR ]",
        "audio.rate", "48000",
        "monitor.channel-volumes", "true",
        NULL);
    if (!props) {
        set_err(err, errlen, "pw_properties_new failed for the sink");
        return -1;
    }
    a->sink_proxy = pw_core_create_object(a->core, "adapter",
                                          PW_TYPE_INTERFACE_Node,
                                          PW_VERSION_NODE,
                                          &props->dict, 0);
    pw_properties_free(props);
    if (!a->sink_proxy) {
        set_err(err, errlen, "cannot create the Lyte Audio sink "
                "(adapter/support.null-audio-sink)");
        return -1;
    }

    /* The node's global must exist before we point the default (and
       the capture target) at its name. One trip usually suffices;
       adapters occasionally announce a trip late. */
    for (int i = 0; i < 3 && !a->sink_seen; i++) {
        if (roundtrip(a) < 0)
            goto core_error;
    }
    if (!a->sink_seen) {
        set_err(err, errlen, "the Lyte Audio sink never appeared in the "
                "registry");
        return -1;
    }

    /* The default switch: the configured key is wireplumber's user
       preference — exactly what wpctl set-default writes. */
    pw_metadata_set_property(a->metadata, PW_ID_CORE, DEFAULT_SINK_KEY,
                             "Spa:String:JSON",
                             "{\"name\":\"" LYTE_SINK_NAME "\"}");
    a->default_switched = 1;
    if (roundtrip(a) < 0)
        goto core_error;
    return 0;

core_error:
    set_err(err, errlen, "%s", a->error);
    return -1;
}

/* --- the capture stream (both modes) --- */

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
                                 int mute_host, char *err, size_t errlen)
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
    a->mute_host = mute_host ? 1 : 0;

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
    pw_core_add_listener(a->core, &a->core_listener, &core_events, a);

    /* hostMuted: the sink comes up and takes the default BEFORE the
       capture stream exists, so the stream's target is already real
       and the roundtrips below can't be quit by stream events. A
       failure inside restores whatever was already changed (free()'s
       restore path). */
    if (a->mute_host && setup_virtual_sink(a, err, errlen) < 0)
        goto fail;

    /* stream.capture.sink is the canonical monitor trick: a capture
       stream carrying it links to a sink's monitor ports. hostAudible
       leaves the target to the session manager = the DEFAULT sink
       (following default-sink switches — HS-14); hostMuted pins
       target.object to OUR sink so the capture ignores any default
       churn (the default IS our sink, but the pin makes the routing
       explicit rather than emergent).

       node.force-quantum (HS-15): node.latency is a REQUEST the graph may
       round up when other streams drive it (measured live: with video
       capture sharing the graph, buffers arrived at ~256 samples/5.33 ms,
       beating against the 240-sample slicer into a 5.3/2.7 ms wall-clock
       emission pattern that violates the 5 ms ± 2 ms inter-send bound at
       the NIC before the pacer ever sees a packet). Forcing the quantum
       to 240 makes the graph actually run 5 ms cycles while this stream
       lives — reverting when it closes — so packets become AVAILABLE at
       the cadence the wire must carry them. Identical in BOTH routing
       modes: the 5 ms pipeline is one pipeline (HS-18's cadence rule). */
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Music",
        PW_KEY_STREAM_CAPTURE_SINK, "true",
        PW_KEY_NODE_LATENCY, "240/48000",
        PW_KEY_NODE_FORCE_QUANTUM, "240",
        NULL);
    if (!props) {
        set_err(err, errlen, "pw_properties_new failed");
        goto fail;
    }
    if (a->mute_host)
        pw_properties_set(props, PW_KEY_TARGET_OBJECT, LYTE_SINK_NAME);

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
    /* Cross-thread stop request. An error verdict already recorded by
       the loop thread must survive the quit — the run-error line is
       the operator's only witness (A-24). */
    int cur = atomic_load(&a->exit_reason);
    while (cur != -1 &&
           !atomic_compare_exchange_weak(&a->exit_reason, &cur, 0)) {
    }
    pw_main_loop_quit(a->loop);
}

int lyte_pw_audio_saved_default(lyte_pw_audio *a, char *buf, size_t buflen)
{
    if (!a || !a->mute_host)
        return -1;
    if (!a->have_saved_default)
        return 0;
    if (buf && buflen > 0)
        snprintf(buf, buflen, "%s", a->saved_default);
    return 1;
}

int lyte_pw_audio_restore(lyte_pw_audio *a, char *err, size_t errlen)
{
    if (!a || !a->mute_host || a->restored || !a->default_switched)
        return 0;
    if (!a->metadata) {
        set_err(err, errlen, "no metadata handle to restore through");
        return -1;
    }
    /* Put the original preference back — or clear the key when none
       existed (wireplumber then recomputes from priorities, which is
       the pre-Lyte state by definition). The roundtrip flushes the
       change before anything is torn down. */
    if (a->have_saved_default)
        pw_metadata_set_property(a->metadata, PW_ID_CORE, DEFAULT_SINK_KEY,
                                 "Spa:String:JSON", a->saved_default);
    else
        pw_metadata_set_property(a->metadata, PW_ID_CORE, DEFAULT_SINK_KEY,
                                 NULL, NULL);
    a->restored = 1;
    /* A core error mid-flush leaves the metadata as the server saw it
       last; the next-start sweep is the backstop. */
    if (roundtrip(a) < 0) {
        set_err(err, errlen, "%s", a->error);
        return -1;
    }
    return 0;
}

void lyte_pw_audio_free(lyte_pw_audio *a)
{
    if (!a)
        return;
    /* Restore while the connection is still whole: default back first
       (wireplumber re-routes to the real sink while ours still
       exists — no fallback churn), then the sink dies with its
       proxy/connection. */
    if (a->mute_host && a->default_switched && !a->restored)
        (void)lyte_pw_audio_restore(a, NULL, 0);
    if (a->stream)
        pw_stream_destroy(a->stream);
    if (a->sink_proxy)
        pw_proxy_destroy(a->sink_proxy);
    if (a->metadata) {
        spa_hook_remove(&a->metadata_listener);
        pw_proxy_destroy((struct pw_proxy *)a->metadata);
    }
    if (a->registry) {
        spa_hook_remove(&a->registry_listener);
        pw_proxy_destroy((struct pw_proxy *)a->registry);
    }
    if (a->core) {
        spa_hook_remove(&a->core_listener);
        pw_core_disconnect(a->core);
    }
    if (a->context)
        pw_context_destroy(a->context);
    if (a->loop)
        pw_main_loop_destroy(a->loop);
    free(a);
}

/* --- the next-start sweep (a SIGKILLed previous run) --- */

struct lyte_sweep {
    struct pw_main_loop *loop;
    struct pw_core *core;
    struct spa_hook core_listener;
    struct pw_registry *registry;
    struct spa_hook registry_listener;
    struct pw_metadata *metadata;
    struct spa_hook metadata_listener;
    int sync_seq;
    int sync_pending;
    int failed;
    char error[256];
};

static void sweep_core_done(void *data, uint32_t id, int seq)
{
    struct lyte_sweep *s = data;
    if (id == PW_ID_CORE && s->sync_pending && seq == s->sync_seq) {
        s->sync_pending = 0;
        pw_main_loop_quit(s->loop);
    }
}

static void sweep_core_error(void *data, uint32_t id, int seq, int res,
                             const char *message)
{
    struct lyte_sweep *s = data;
    (void)seq;
    if (id == PW_ID_CORE) {
        snprintf(s->error, sizeof(s->error), "pipewire core error %d: %s",
                 res, message ? message : "(unspecified)");
        s->failed = 1;
        pw_main_loop_quit(s->loop);
    }
}

static const struct pw_core_events sweep_core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = sweep_core_done,
    .error = sweep_core_error,
};

static int sweep_roundtrip(struct lyte_sweep *s)
{
    s->sync_pending = 1;
    s->sync_seq = pw_core_sync(s->core, PW_ID_CORE, 0);
    pw_main_loop_run(s->loop);
    return s->failed ? -1 : 0;
}

/* The sweep needs no property events — it only writes. */
static const struct pw_metadata_events sweep_metadata_events = {
    PW_VERSION_METADATA_EVENTS,
};

static void sweep_registry_global(void *data, uint32_t id,
                                  uint32_t permissions, const char *type,
                                  uint32_t version,
                                  const struct spa_dict *props)
{
    struct lyte_sweep *s = data;
    (void)permissions;
    (void)version;
    if (s->metadata || !props ||
        strcmp(type, PW_TYPE_INTERFACE_Metadata) != 0)
        return;
    const char *name = spa_dict_lookup(props, PW_KEY_METADATA_NAME);
    if (name && strcmp(name, "default") == 0) {
        s->metadata = pw_registry_bind(s->registry, id, type,
                                       PW_VERSION_METADATA, 0);
        if (s->metadata)
            pw_metadata_add_listener(s->metadata, &s->metadata_listener,
                                     &sweep_metadata_events, s);
    }
}

static const struct pw_registry_events sweep_registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = sweep_registry_global,
};

int lyte_pw_audio_restore_default(const char *saved_json,
                                  char *err, size_t errlen)
{
    pw_init(NULL, NULL);

    struct lyte_sweep s;
    memset(&s, 0, sizeof(s));
    struct pw_context *context = NULL;
    int rc = -1;

    s.loop = pw_main_loop_new(NULL);
    if (!s.loop) {
        set_err(err, errlen, "pw_main_loop_new failed");
        goto out;
    }
    context = pw_context_new(pw_main_loop_get_loop(s.loop), NULL, 0);
    if (!context) {
        set_err(err, errlen, "pw_context_new failed");
        goto out;
    }
    s.core = pw_context_connect(context, NULL, 0);
    if (!s.core) {
        set_err(err, errlen, "pw_context_connect failed");
        goto out;
    }
    pw_core_add_listener(s.core, &s.core_listener, &sweep_core_events, &s);
    s.registry = pw_core_get_registry(s.core, PW_VERSION_REGISTRY, 0);
    if (!s.registry) {
        set_err(err, errlen, "pw_core_get_registry failed");
        goto out;
    }
    pw_registry_add_listener(s.registry, &s.registry_listener,
                             &sweep_registry_events, &s);

    if (sweep_roundtrip(&s) < 0) {
        set_err(err, errlen, "%s", s.error);
        goto out;
    }
    if (!s.metadata) {
        set_err(err, errlen, "no \"default\" metadata object — is "
                "wireplumber running?");
        goto out;
    }

    if (saved_json)
        pw_metadata_set_property(s.metadata, PW_ID_CORE, DEFAULT_SINK_KEY,
                                 "Spa:String:JSON", saved_json);
    else
        pw_metadata_set_property(s.metadata, PW_ID_CORE, DEFAULT_SINK_KEY,
                                 NULL, NULL);
    if (sweep_roundtrip(&s) < 0) {
        set_err(err, errlen, "%s", s.error);
        goto out;
    }
    rc = 0;

out:
    if (s.metadata) {
        spa_hook_remove(&s.metadata_listener);
        pw_proxy_destroy((struct pw_proxy *)s.metadata);
    }
    if (s.registry) {
        spa_hook_remove(&s.registry_listener);
        pw_proxy_destroy((struct pw_proxy *)s.registry);
    }
    if (s.core) {
        spa_hook_remove(&s.core_listener);
        pw_core_disconnect(s.core);
    }
    if (context)
        pw_context_destroy(context);
    if (s.loop)
        pw_main_loop_destroy(s.loop);
    return rc;
}
