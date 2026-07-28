#include "lyte_hevc_encode.h"

#include <libavcodec/avcodec.h>
#include <libavutil/intreadwrite.h>
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
    int cbr; /* opened in CBR mode (cq == 0): min-rate tracks the avg */
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
                                 int fps, int64_t bit_rate, int cq,
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
    ctx->gop_size = INT_MAX;
    ctx->keyint_min = INT_MAX;
    ctx->max_b_frames = 0;
    ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY;

    /* R3 Stage A (HS-22c): sign the colors. We feed packed RGB and NVENC
       converts to 4:2:0 internally; before this, no colorspace/range was
       set anywhere, the VUI carried "unspecified", and every decoder
       GUESSED the matrix and range — the classic smeared/washed-desktop
       bug class (image-quality pillar §2). These fields flow into the
       SPS VUI via the nvenc wrapper. The values are the MEASURED truth
       of what the hardware conversion actually does with RGB input,
       decided on the reference host by decoding a captured SMPTE-bars
       stream under every candidate interpretation against the raw BGRx
       dump: BT.601 limited wins (41.7 dB RGB vs 40.0 for 709-limited;
       full-range collapses to ~26 dB) — and the wrapper agrees, forcing
       colourMatrix to bt470bg for RGB input no matter what colorspace
       says, so we set the field to match reality rather than fight it.
       Transfer is signed sRGB (IEC 61966-2-1): the desktop framebuffer
       IS sRGB-encoded and NVENC never touches the transfer — a bt709
       tag would buy the classic gamma shift on any color-managed
       decoder (the Mac client's exact pipeline). Primaries: sRGB and
       BT.709 share them. */
    ctx->color_primaries = AVCOL_PRI_BT709;
    ctx->color_trc = AVCOL_TRC_IEC61966_2_1;
    ctx->colorspace = AVCOL_SPC_BT470BG;
    ctx->color_range = AVCOL_RANGE_MPEG;

    if (cq > 0) {
        /* Capped-CQ VBR (the quality-ratchet mode): a constant-quality
           target with `bit_rate` as the hard cap. FFmpeg's nvenc wrapper
           zeroes avg-bitrate/VBV in CQ mode and keeps only max-rate.
           qmin pins nvenc's downward QP walk at `cq` — without it the walk
           overshoots ~3 QP below the target (measured on real hardware). */
        ctx->rc_max_rate = bit_rate;
        av_opt_set_int(ctx->priv_data, "qmin", cq, 0);
        av_opt_set(ctx->priv_data, "rc", "vbr", 0);
        av_opt_set_int(ctx->priv_data, "cq", cq, 0);
    } else {
        /* True CBR (the committed slice-2 recipe). */
        e->cbr = 1;
        ctx->bit_rate = bit_rate;
        ctx->rc_max_rate = bit_rate;
        ctx->rc_min_rate = bit_rate;
        ctx->rc_buffer_size = (int)(bit_rate / fps); /* single-frame VBV */
        /* Sunshine's HEVC min-QP floor (nvenc 19/23/23 per codec) — bounds
           how far CBR may refine quality per block. */
        ctx->qmin = 23;
        av_opt_set(ctx->priv_data, "rc", "cbr", 0);
    }

    av_opt_set(ctx->priv_data, "preset", "p1", 0);
    av_opt_set(ctx->priv_data, "tune", "ull", 0);
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

/* Frame-average QP from the packet's quality-stats side data (nvenc reports
   frameAvgQP there, stored as (qp-1)*FF_QP2LAMBDA). -1 if absent. */
static int packet_avg_qp(const AVPacket *pkt)
{
    size_t size = 0;
    const uint8_t *sd =
        av_packet_get_side_data(pkt, AV_PKT_DATA_QUALITY_STATS, &size);
    if (!sd || size < 4)
        return -1;
    return (int)(AV_RL32(sd) / FF_QP2LAMBDA) + 1;
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
           (e->pkt->flags & AV_PKT_FLAG_KEY) != 0, packet_avg_qp(e->pkt));
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

int lyte_hevc_enc_set_rate(lyte_hevc_enc *e, int64_t avg_bits,
                           int64_t max_bits, int64_t vbv_bits,
                           char *err, size_t errlen)
{
    if (max_bits <= 0 || vbv_bits <= 0 || vbv_bits > INT_MAX) {
        set_err(err, errlen,
                "set_rate: max %lld / vbv %lld out of range",
                (long long)max_bits, (long long)vbv_bits);
        return -1;
    }
    /* The nvenc wrapper (nvenc_reconfig_encoder) reads these fields at
       the next send_frame, diffs them against the running NVENC config,
       and reconfigures in place when something moved. Nothing to call
       here — assignment IS the API. */
    AVCodecContext *ctx = e->ctx;
    if (avg_bits > 0) {
        ctx->bit_rate = avg_bits;
        if (e->cbr)
            ctx->rc_min_rate = avg_bits; /* min = avg = max: still CBR */
    }
    ctx->rc_max_rate = max_bits;
    ctx->rc_buffer_size = (int)vbv_bits;
    return 0;
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
