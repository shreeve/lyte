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
#include <time.h>

struct lyte_hevc_enc {
    AVCodecContext *ctx;
    AVFrame *frame;
    AVPacket *pkt;
    int width;
    int height;
    int cbr; /* opened in CBR mode (cq == 0): min-rate tracks the avg */
    uint64_t repack_us_total; /* BGRx→planar repack wall time (gbrp path) */
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

/* av_opt_set that fails the open loudly: the HS-24 A/B harness needs a
   bad knob value to reject the run, never to ride a silent default. */
static int set_opt(AVCodecContext *ctx, const char *name, const char *val,
                   char *err, size_t errlen)
{
    int rc = av_opt_set(ctx->priv_data, name, val, 0);
    if (rc < 0) {
        char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(rc, buf, sizeof(buf));
        set_err(err, errlen, "encoder option %s=%s rejected: %s",
                name, val, buf);
        return -1;
    }
    return 0;
}

static int set_opt_int(AVCodecContext *ctx, const char *name, int64_t val,
                       char *err, size_t errlen)
{
    int rc = av_opt_set_int(ctx->priv_data, name, val, 0);
    if (rc < 0) {
        char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(rc, buf, sizeof(buf));
        set_err(err, errlen, "encoder option %s=%lld rejected: %s",
                name, (long long)val, buf);
        return -1;
    }
    return 0;
}

lyte_hevc_enc *lyte_hevc_enc_new(int width, int height,
                                 const char *pix_fmt_name,
                                 int fps, int64_t bit_rate, int cq,
                                 const char *preset, const char *tune,
                                 const char *multipass,
                                 int spatial_aq, int temporal_aq,
                                 int aq_strength,
                                 const char *profile,
                                 const char *rgb_mode,
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
    /* The input formats this leaf actually plumbs (send() owns a copy
       path per family). Anything else is a loud reject, not a maybe. */
    if (pix_fmt != AV_PIX_FMT_BGR0 && pix_fmt != AV_PIX_FMT_BGRA &&
        pix_fmt != AV_PIX_FMT_RGB0 && pix_fmt != AV_PIX_FMT_RGBA &&
        pix_fmt != AV_PIX_FMT_GBRP && pix_fmt != AV_PIX_FMT_YUV444P) {
        set_err(err, errlen,
                "pixel format \"%s\" has no input plumbing in this leaf "
                "(packed RGB, gbrp, yuv444p only)", pix_fmt_name);
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

    /* The latency invariants (Sunshine's low-latency frame,
       docs/sunshine-v2026.715.205118.md §7): infinite GOP, no B-frames,
       no reorder delay. These are NOT recipe knobs — a B-frame or a
       lookahead frame is buffered latency by definition, and the
       packetizer's PTS invariant assumes display order. */
    ctx->gop_size = INT_MAX;
    ctx->keyint_min = INT_MAX;
    ctx->max_b_frames = 0;
    ctx->flags |= AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY;

    /* Sign the colors per input path — the VUI must carry the MEASURED
       truth of what actually happens to the pixels, never a hope.
       Transfer is signed sRGB (IEC 61966-2-1) on every path: the
       desktop framebuffer IS sRGB-encoded and neither NVENC nor a
       repack touches the transfer — a bt709 tag would buy the classic
       gamma shift on any color-managed decoder (the Mac client's exact
       pipeline). Primaries: sRGB and BT.709 share them. */
    ctx->color_primaries = AVCOL_PRI_BT709;
    ctx->color_trc = AVCOL_TRC_IEC61966_2_1;
    if (pix_fmt == AV_PIX_FMT_GBRP) {
        /* Planar RGB rides Rext as raw GBR planes: identity matrix,
           full range, zero matrix conversion anywhere (V-1; nvenc.c
           forces colourMatrix=RGB for gbrp and honors color_range). */
        ctx->colorspace = AVCOL_SPC_RGB;
        ctx->color_range = AVCOL_RANGE_JPEG;
    } else if (pix_fmt == AV_PIX_FMT_YUV444P) {
        /* The host-side conversion path: the caller hands YUV444 it
           converted itself, BT.709 full-range by contract (the V-1
           probe's third candidate; a real conversion leaf would sign
           the matrix it applies here). */
        ctx->colorspace = AVCOL_SPC_BT709;
        ctx->color_range = AVCOL_RANGE_JPEG;
    } else {
        /* R3 Stage A (HS-22c): packed RGB in, NVENC converts
           internally; the wrapper forces colourMatrix to bt470bg
           limited for packed-RGB input no matter what colorspace says
           (measured on the reference host: BT.601 limited wins, 41.7 dB
           RGB vs 40.0 for 709-limited; full-range collapses to ~26 dB)
           — so we set the field to match reality rather than fight it.
           Holds for the rgb_mode=yuv444 4:4:4 path too: the internal
           conversion stays 601-limited (V-1 re-measured). */
        ctx->colorspace = AVCOL_SPC_BT470BG;
        ctx->color_range = AVCOL_RANGE_MPEG;
    }

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

    /* The recipe knobs (HS-24): preset/tune/multipass/AQ come from the
       caller — HostCore.EncoderRecipe owns the product default. Every
       set is checked: a knob this libavcodec build doesn't know fails
       the open (the harness's reject evidence). */
    if (set_opt(ctx, "preset", preset, err, errlen) < 0 ||
        set_opt(ctx, "tune", tune, err, errlen) < 0 ||
        set_opt(ctx, "multipass", multipass, err, errlen) < 0 ||
        set_opt_int(ctx, "spatial-aq", spatial_aq ? 1 : 0, err, errlen) < 0 ||
        set_opt_int(ctx, "temporal-aq", temporal_aq ? 1 : 0, err, errlen) < 0)
        goto fail;
    if (aq_strength > 0 &&
        set_opt_int(ctx, "aq-strength", aq_strength, err, errlen) < 0)
        goto fail;
    /* H4 probe knobs (V-1): profile ("main"/"main10"/"rext") and
       rgb_mode ("yuv420"/"yuv444", the wrapper's packed-RGB handling).
       Empty means "leave the wrapper's default"; a value this build
       doesn't know fails the open loudly like every other knob. */
    if (profile && profile[0] &&
        set_opt(ctx, "profile", profile, err, errlen) < 0)
        goto fail;
    if (rgb_mode && rgb_mode[0] &&
        set_opt(ctx, "rgb_mode", rgb_mode, err, errlen) < 0)
        goto fail;
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

static uint64_t now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000;
}

/* BGRx → gbrp: split the packed capture buffer into the G/B/R planes
   nvenc's identity-matrix Rext path encodes verbatim. This is the
   production-shaped repack the gbrp path costs (V-1 measures it via
   lyte_hevc_enc_repack_us_total). */
static void repack_bgrx_gbrp(const uint8_t *src, int src_stride,
                             AVFrame *f, int width, int height)
{
    for (int y = 0; y < height; y++) {
        const uint8_t *row = src + (ptrdiff_t)y * src_stride;
        uint8_t *g = f->data[0] + (ptrdiff_t)y * f->linesize[0];
        uint8_t *b = f->data[1] + (ptrdiff_t)y * f->linesize[1];
        uint8_t *r = f->data[2] + (ptrdiff_t)y * f->linesize[2];
        for (int x = 0; x < width; x++) {
            b[x] = row[4 * x + 0];
            g[x] = row[4 * x + 1];
            r[x] = row[4 * x + 2];
        }
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

    if (e->frame->format == AV_PIX_FMT_GBRP) {
        /* Input stays packed BGRx (the capture contract); the leaf owns
           the planar split. */
        uint64_t t0 = now_us();
        repack_bgrx_gbrp(data, src_stride, e->frame, e->width, e->height);
        e->repack_us_total += now_us() - t0;
    } else if (e->frame->format == AV_PIX_FMT_YUV444P) {
        /* Pre-converted planar input: three tightly-packed w×h planes
           (Y, Cb, Cr); src_stride is ignored. */
        for (int p = 0; p < 3; p++) {
            const uint8_t *src = data + (ptrdiff_t)p * e->width * e->height;
            for (int y = 0; y < e->height; y++)
                memcpy(e->frame->data[p] + (ptrdiff_t)y * e->frame->linesize[p],
                       src + (ptrdiff_t)y * e->width, e->width);
        }
    } else {
        const int row_bytes = e->width * 4;
        uint8_t *dst = e->frame->data[0];
        const int dst_stride = e->frame->linesize[0];
        for (int y = 0; y < e->height; y++)
            memcpy(dst + (ptrdiff_t)y * dst_stride,
                   data + (ptrdiff_t)y * src_stride, row_bytes);
    }

    e->frame->pts = pts;
    e->frame->pict_type = force_idr ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;

    rc = avcodec_send_frame(e->ctx, e->frame);
    if (rc < 0) {
        averr(err, errlen, "avcodec_send_frame failed", rc);
        return -1;
    }
    return drain(e, cb, user, err, errlen);
}

uint64_t lyte_hevc_enc_repack_us_total(const lyte_hevc_enc *e)
{
    return e->repack_us_total;
}

int lyte_hevc_noreset_enable(void)
{
    /* The vendored build signs itself: --extra-version=lyte-noreset
       lands in the configuration string. Distro libavcodec never
       carries it, so the whole feature is provably inert there. */
    if (!strstr(avcodec_configuration(), "lyte-noreset"))
        return 0;
    const char *env = getenv("LYTE_NVENC_NO_RESET_RATE");
    if (!env) {
        /* Default ON under the vendored lib; never overwrite an
           explicit choice (the "0" control leg of every A/B). */
        setenv("LYTE_NVENC_NO_RESET_RATE", "1", 0);
        env = getenv("LYTE_NVENC_NO_RESET_RATE");
    }
    return env && env[0] == '1';
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
