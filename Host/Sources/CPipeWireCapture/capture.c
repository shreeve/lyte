#include "lyte_pw_capture.h"

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h>
#include <spa/debug/types.h>

#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct lyte_pw_capture {
    struct pw_main_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_source *timer;
    struct spa_source *tick_timer;

    lyte_pw_tick_cb tick_cb;
    void *tick_user;
    uint64_t tick_interval_ns;

    /* Registry scan state used to resolve the target node's object.serial. */
    uint32_t target_node_id;
    uint64_t target_serial;
    int target_serial_found;
    int registry_sync_done;
    int registry_sync_seq;

    lyte_pw_frame_cb frame_cb;
    void *user;

    struct spa_video_info_raw format;
    int have_format;

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

static lyte_pixfmt map_spa_format(enum spa_video_format f)
{
    switch (f) {
    case SPA_VIDEO_FORMAT_BGRx: return LYTE_PIXFMT_BGRX;
    case SPA_VIDEO_FORMAT_BGRA: return LYTE_PIXFMT_BGRA;
    case SPA_VIDEO_FORMAT_RGBx: return LYTE_PIXFMT_RGBX;
    case SPA_VIDEO_FORMAT_RGBA: return LYTE_PIXFMT_RGBA;
    default: return LYTE_PIXFMT_UNKNOWN;
    }
}

static void on_stream_state_changed(void *data, enum pw_stream_state old,
                                    enum pw_stream_state state, const char *error)
{
    struct lyte_pw_capture *c = data;
    (void)old;
    if (state == PW_STREAM_STATE_ERROR) {
        snprintf(c->error, sizeof(c->error), "pipewire stream error: %s",
                 error ? error : "(unspecified)");
        c->exit_reason = -1;
        pw_main_loop_quit(c->loop);
    }
}

static void on_stream_param_changed(void *data, uint32_t id, const struct spa_pod *param)
{
    struct lyte_pw_capture *c = data;

    if (param == NULL || id != SPA_PARAM_Format)
        return;

    uint32_t media_type, media_subtype;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0)
        return;
    if (media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw)
        return;

    if (spa_format_video_raw_parse(param, &c->format) < 0) {
        snprintf(c->error, sizeof(c->error), "cannot parse negotiated video format");
        c->exit_reason = -1;
        pw_main_loop_quit(c->loop);
        return;
    }
    c->have_format = 1;

    /* Restrict buffers to memory the client can mmap: no DMA-BUF in this
       slice. MAP_BUFFERS makes MemFd arrive pre-mapped. */
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&b,
        SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 8),
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int(
            (1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
    pw_stream_update_params(c->stream, params, 1);
}

static void on_stream_process(void *data)
{
    struct lyte_pw_capture *c = data;

    struct pw_buffer *b = pw_stream_dequeue_buffer(c->stream);
    if (b == NULL)
        return;

    struct spa_buffer *buf = b->buffer;
    struct spa_data *d = &buf->datas[0];

    if (c->have_format && d->data != NULL && d->chunk != NULL && d->chunk->size > 0) {
        lyte_pixfmt fmt = map_spa_format(c->format.format);
        c->frame_cb(c->user,
                    (const uint8_t *)d->data + d->chunk->offset,
                    d->chunk->size,
                    d->chunk->stride,
                    c->format.size.width,
                    c->format.size.height,
                    fmt);
    }

    pw_stream_queue_buffer(c->stream, b);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_stream_state_changed,
    .param_changed = on_stream_param_changed,
    .process = on_stream_process,
};

static void on_timeout(void *data, uint64_t expirations)
{
    struct lyte_pw_capture *c = data;
    (void)expirations;
    c->exit_reason = 1;
    pw_main_loop_quit(c->loop);
}

static void on_tick(void *data, uint64_t expirations)
{
    struct lyte_pw_capture *c = data;
    (void)expirations;
    if (c->tick_cb)
        c->tick_cb(c->tick_user);
}

/* Registry scan: find the target node's object.serial. pw_stream_connect's
   target_id parameter is resolved by the session manager against
   object.serial (ids and serials differ), so passing the portal's node id
   there can miss — WirePlumber then falls back to the *default* video
   source (e.g. a webcam), whose YUV formats fail negotiation with
   "no more input formats". Targeting by serial is exact. */

static void on_registry_global(void *data, uint32_t id, uint32_t permissions,
                               const char *type, uint32_t version,
                               const struct spa_dict *props)
{
    struct lyte_pw_capture *c = data;
    (void)permissions;
    (void)version;
    if (getenv("LYTE_PW_DEBUG") != NULL) {
        fprintf(stderr, "pw-registry: global id=%u type=%s name=%s serial=%s class=%s\n",
                id, type ? type : "?",
                props ? spa_dict_lookup(props, PW_KEY_NODE_NAME) : NULL,
                props ? spa_dict_lookup(props, PW_KEY_OBJECT_SERIAL) : NULL,
                props ? spa_dict_lookup(props, PW_KEY_MEDIA_CLASS) : NULL);
    }
    if (id != c->target_node_id || props == NULL)
        return;
    const char *serial = spa_dict_lookup(props, PW_KEY_OBJECT_SERIAL);
    if (serial != NULL) {
        c->target_serial = strtoull(serial, NULL, 10);
        c->target_serial_found = 1;
    }
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = on_registry_global,
};

static void on_core_done(void *data, uint32_t id, int seq)
{
    struct lyte_pw_capture *c = data;
    if (id == PW_ID_CORE && seq == c->registry_sync_seq) {
        c->registry_sync_done = 1;
        pw_main_loop_quit(c->loop);
    }
}

static void on_core_error(void *data, uint32_t id, int seq, int res,
                          const char *message)
{
    struct lyte_pw_capture *c = data;
    (void)id;
    (void)seq;
    (void)res;
    (void)message;
    /* Stop the sync wait; the stream connect below will report the error. */
    c->registry_sync_done = 1;
    pw_main_loop_quit(c->loop);
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = on_core_done,
    .error = on_core_error,
};

static int resolve_target_serial(struct lyte_pw_capture *c, uint32_t node_id)
{
    struct pw_registry *registry =
        pw_core_get_registry(c->core, PW_VERSION_REGISTRY, 0);
    if (registry == NULL)
        return -1;

    struct spa_hook registry_listener;
    struct spa_hook core_listener;
    spa_zero(registry_listener);
    spa_zero(core_listener);

    c->target_node_id = node_id;
    c->target_serial_found = 0;
    c->registry_sync_done = 0;

    pw_registry_add_listener(registry, &registry_listener, &registry_events, c);
    pw_core_add_listener(c->core, &core_listener, &core_events, c);
    c->registry_sync_seq = pw_core_sync(c->core, PW_ID_CORE, 0);

    /* Run the loop until the core round-trip completes; done/error quit it. */
    pw_main_loop_run(c->loop);

    spa_hook_remove(&registry_listener);
    spa_hook_remove(&core_listener);
    pw_proxy_destroy((struct pw_proxy *)registry);

    return c->target_serial_found ? 0 : -1;
}

lyte_pw_capture *lyte_pw_capture_new(int pipewire_fd, uint32_t node_id,
                                     lyte_pw_frame_cb frame_cb, void *user,
                                     char *err, size_t errlen)
{
    pw_init(NULL, NULL);

    struct lyte_pw_capture *c = calloc(1, sizeof(*c));
    if (!c) {
        set_err(err, errlen, "out of memory");
        return NULL;
    }
    c->frame_cb = frame_cb;
    c->user = user;
    c->exit_reason = 1;

    c->loop = pw_main_loop_new(NULL);
    if (!c->loop) {
        set_err(err, errlen, "pw_main_loop_new failed");
        goto fail;
    }

    c->context = pw_context_new(pw_main_loop_get_loop(c->loop), NULL, 0);
    if (!c->context) {
        set_err(err, errlen, "pw_context_new failed");
        goto fail;
    }

    /* fd < 0 means connect to the user's default PipeWire remote (the
       Mutter internal ScreenCast backend publishes nodes there); otherwise
       adopt the portal-provided remote fd. */
    if (pipewire_fd < 0)
        c->core = pw_context_connect(c->context, NULL, 0);
    else
        c->core = pw_context_connect_fd(c->context, pipewire_fd, NULL, 0);
    if (!c->core) {
        set_err(err, errlen, "pw_context_connect%s failed",
                pipewire_fd < 0 ? "" : "_fd (portal fd invalid?)");
        goto fail;
    }

    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Video",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Screen",
        NULL);
    if (!props) {
        set_err(err, errlen, "pw_properties_new failed");
        goto fail;
    }

    /* Pin the stream to the intended node by object.serial. Without this,
       the session manager resolves the connect target loosely and can link
       the default video source (e.g. a webcam) instead of the portal's
       screencast node, which fails negotiation ("no more input formats").
       node.dont-fallback makes a missing target an error instead of a
       silent fallback to the default source. */
    if (resolve_target_serial(c, node_id) == 0) {
        pw_properties_setf(props, PW_KEY_TARGET_OBJECT,
                           "%" PRIu64, c->target_serial);
        pw_properties_set(props, "node.dont-fallback", "true");
    } else {
        pw_properties_free(props);
        set_err(err, errlen,
                "PipeWire node %u not found on this remote (registry scan); "
                "the portal stream may have closed", node_id);
        goto fail;
    }

    c->stream = pw_stream_new(c->core, "lyte-host-capture", props);
    if (!c->stream) {
        set_err(err, errlen, "pw_stream_new failed");
        goto fail;
    }
    pw_stream_add_listener(c->stream, &c->stream_listener, &stream_events, c);

    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&b,
        SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(5,
            SPA_VIDEO_FORMAT_BGRx,
            SPA_VIDEO_FORMAT_BGRx,
            SPA_VIDEO_FORMAT_BGRA,
            SPA_VIDEO_FORMAT_RGBx,
            SPA_VIDEO_FORMAT_RGBA),
        SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(
            &SPA_RECTANGLE(1920, 1080),
            &SPA_RECTANGLE(1, 1),
            &SPA_RECTANGLE(8192, 8192)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(
            &SPA_FRACTION(60, 1),
            &SPA_FRACTION(0, 1),
            &SPA_FRACTION(1000, 1)));

    /* target.object above carries the real target; PW_ID_ANY avoids the
       legacy id-based path whose resolution against serials is unreliable. */
    if (pw_stream_connect(c->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                          PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
                          params, 1) < 0) {
        set_err(err, errlen, "pw_stream_connect failed for node %u", node_id);
        goto fail;
    }

    return c;

fail:
    lyte_pw_capture_free(c);
    return NULL;
}

int lyte_pw_capture_set_tick(lyte_pw_capture *c, uint64_t interval_ns,
                             lyte_pw_tick_cb tick_cb, void *user)
{
    if (!c || !tick_cb || interval_ns == 0)
        return -1;
    c->tick_cb = tick_cb;
    c->tick_user = user;
    c->tick_interval_ns = interval_ns;
    return 0;
}

int lyte_pw_capture_run(lyte_pw_capture *c, double timeout_sec,
                        char *err, size_t errlen)
{
    c->timer = pw_loop_add_timer(pw_main_loop_get_loop(c->loop), on_timeout, c);
    if (c->timer) {
        struct timespec value = {
            .tv_sec = (time_t)timeout_sec,
            .tv_nsec = (long)((timeout_sec - (time_t)timeout_sec) * 1e9),
        };
        pw_loop_update_timer(pw_main_loop_get_loop(c->loop), c->timer,
                             &value, NULL, false);
    }

    if (c->tick_cb) {
        c->tick_timer = pw_loop_add_timer(pw_main_loop_get_loop(c->loop),
                                          on_tick, c);
        if (c->tick_timer) {
            struct timespec interval = {
                .tv_sec = (time_t)(c->tick_interval_ns / 1000000000ull),
                .tv_nsec = (long)(c->tick_interval_ns % 1000000000ull),
            };
            pw_loop_update_timer(pw_main_loop_get_loop(c->loop), c->tick_timer,
                                 &interval, &interval, false);
        }
    }

    pw_main_loop_run(c->loop);

    if (c->exit_reason == -1)
        set_err(err, errlen, "%s", c->error);
    return c->exit_reason;
}

void lyte_pw_capture_quit(lyte_pw_capture *c)
{
    c->exit_reason = 0;
    pw_main_loop_quit(c->loop);
}

void lyte_pw_capture_free(lyte_pw_capture *c)
{
    if (!c)
        return;
    if (c->stream)
        pw_stream_destroy(c->stream);
    if (c->core)
        pw_core_disconnect(c->core);
    if (c->context)
        pw_context_destroy(c->context);
    if (c->loop)
        pw_main_loop_destroy(c->loop);
    free(c);
}
