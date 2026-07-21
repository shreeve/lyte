#include "lyte_hevc_encode.h"

#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>

#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct lyte_hevc_enc {
    AVCodecContext *ctx;
    AVFrame *frame;
    AVPacket *pkt;
    int width;
    int height;
};

void lyte_stdout_linebuf(void) { setvbuf(stdout, NULL, _IOLBF, 0); }
void lyte_stdout_flush(void) { fflush(stdout); }

static void set_err(char *err, size_t errlen, const char *fmt, ...)
{
    if (!err || errlen == 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

static void averr(char *err, size_t errlen, const char *what, int rc)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(rc, buf, sizeof(buf));
    set_err(err, errlen, "%s: %s", what, buf);
}

lyte_hevc_enc *lyte_hevc_enc_new(int width, int height,
                                 const char *pix_fmt_name,
                                 int fps, int64_t bit_rate,
                                 char *err, size_t errlen)
{
    const AVCodec *codec = avcodec_find_encoder_by_name("hevc_nvenc");
    if (!codec) {
        set_err(err, errlen,
                "hevc_nvenc is not available in this libavcodec build");
        return NULL;
    }

    enum AVPixelFormat pix_fmt = av_get_pix_fmt(pix_fmt_name);
    if (pix_fmt == AV_PIX_FMT_NONE) {
        set_err(err, errlen, "unknown pixel format \"%s\"", pix_fmt_name);
        return NULL;
    }

    struct lyte_hevc_enc *e = calloc(1, sizeof(*e));
    if (!e) {
        set_err(err, errlen, "out of memory");
        return NULL;
    }
    e->width = width;
    e->height = height;

    e->ctx = avcodec_alloc_context3(codec);
    e->frame = av_frame_alloc();
    e->pkt = av_packet_alloc();
    if (!e->ctx || !e->frame || !e->pkt) {
        set_err(err, errlen, "out of memory allocating codec state");
        goto fail;
    }

    AVCodecContext *ctx = e->ctx;
    ctx->width = width;
    ctx->height = height;
    ctx->pix_fmt = pix_fmt;
    ctx->time_base = (AVRational){1, fps};
    ctx->framerate = (AVRational){fps, 1};

    /* Sunshine's low-latency recipe (docs/sunshine-v2026.715.205118.md §7). */
    ctx->bit_rate = bit_rate;
    ctx->rc_max_rate = bit_rate;
    ctx->rc_min_rate = bit_rate;
    ctx->rc_buffer_size = (int)(bit_rate / fps); /* single-frame VBV */
    ctx->gop_size = INT_MAX;
    ctx->keyint_min = INT_MAX;
    ctx->max_b_frames = 0;
    ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY;
    /* Sunshine's HEVC min-QP floor (nvenc 19/23/23 per codec) — bounds how
       far CBR may refine quality per block. */
    ctx->qmin = 23;

    av_opt_set(ctx->priv_data, "preset", "p1", 0);
    av_opt_set(ctx->priv_data, "tune", "ull", 0);
    av_opt_set(ctx->priv_data, "rc", "cbr", 0);
    /* Sunshine's two-pass quarter-res rate control. Besides better bit
       placement, it lets CBR go quiet on static content (~4.5x fewer bytes
       measured on a repeated still) instead of burning budget re-refining. */
    av_opt_set(ctx->priv_data, "multipass", "qres", 0);
    av_opt_set_int(ctx->priv_data, "zerolatency", 1, 0);
    av_opt_set_int(ctx->priv_data, "delay", 0, 0);
    av_opt_set_int(ctx->priv_data, "forced-idr", 1, 0);
    av_opt_set_int(ctx->priv_data, "surfaces", 1, 0);

    int rc = avcodec_open2(ctx, codec, NULL);
    if (rc < 0) {
        averr(err, errlen, "avcodec_open2(hevc_nvenc) failed", rc);
        goto fail;
    }

    e->frame->format = pix_fmt;
    e->frame->width = width;
    e->frame->height = height;
    rc = av_frame_get_buffer(e->frame, 0);
    if (rc < 0) {
        averr(err, errlen, "av_frame_get_buffer failed", rc);
        goto fail;
    }

    return e;

fail:
    lyte_hevc_enc_free(e);
    return NULL;
}

static int drain(lyte_hevc_enc *e, lyte_hevc_packet_cb cb, void *user,
                 char *err, size_t errlen)
{
    for (;;) {
        int rc = avcodec_receive_packet(e->ctx, e->pkt);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF)
            return 0;
        if (rc < 0) {
            averr(err, errlen, "avcodec_receive_packet failed", rc);
            return -1;
        }
        cb(user, e->pkt->data, (size_t)e->pkt->size,
           (e->pkt->flags & AV_PKT_FLAG_KEY) != 0);
        av_packet_unref(e->pkt);
    }
}

int lyte_hevc_enc_send(lyte_hevc_enc *e, const uint8_t *data, int src_stride,
                       int64_t pts, int force_idr,
                       lyte_hevc_packet_cb cb, void *user,
                       char *err, size_t errlen)
{
    int rc = av_frame_make_writable(e->frame);
    if (rc < 0) {
        averr(err, errlen, "av_frame_make_writable failed", rc);
        return -1;
    }

    const int row_bytes = e->width * 4;
    uint8_t *dst = e->frame->data[0];
    const int dst_stride = e->frame->linesize[0];
    for (int y = 0; y < e->height; y++)
        memcpy(dst + (ptrdiff_t)y * dst_stride,
               data + (ptrdiff_t)y * src_stride, row_bytes);

    e->frame->pts = pts;
    e->frame->pict_type = force_idr ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;

    rc = avcodec_send_frame(e->ctx, e->frame);
    if (rc < 0) {
        averr(err, errlen, "avcodec_send_frame failed", rc);
        return -1;
    }
    return drain(e, cb, user, err, errlen);
}

int lyte_hevc_enc_flush(lyte_hevc_enc *e, lyte_hevc_packet_cb cb, void *user,
                        char *err, size_t errlen)
{
    int rc = avcodec_send_frame(e->ctx, NULL);
    if (rc < 0 && rc != AVERROR_EOF) {
        averr(err, errlen, "avcodec_send_frame(flush) failed", rc);
        return -1;
    }
    return drain(e, cb, user, err, errlen);
}

void lyte_hevc_enc_free(lyte_hevc_enc *e)
{
    if (!e)
        return;
    av_packet_free(&e->pkt);
    av_frame_free(&e->frame);
    avcodec_free_context(&e->ctx);
    free(e);
}
