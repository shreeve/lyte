#include "lyte_opus.h"

#include <opus/opus.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

struct lyte_opus_enc {
    OpusEncoder *enc;
};

struct lyte_opus_dec {
    OpusDecoder *dec;
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

lyte_opus_enc *lyte_opus_enc_new(int32_t bitrate, int use_vbr,
                                 char *err, size_t errlen)
{
    struct lyte_opus_enc *e = calloc(1, sizeof(*e));
    if (!e) {
        set_err(err, errlen, "out of memory");
        return NULL;
    }

    int rc = OPUS_OK;
    e->enc = opus_encoder_create(LYTE_OPUS_RATE, LYTE_OPUS_CHANNELS,
                                 OPUS_APPLICATION_RESTRICTED_LOWDELAY, &rc);
    if (rc != OPUS_OK || !e->enc) {
        set_err(err, errlen, "opus_encoder_create: %s", opus_strerror(rc));
        free(e);
        return NULL;
    }

    opus_encoder_ctl(e->enc, OPUS_SET_BITRATE(bitrate));
    opus_encoder_ctl(e->enc, OPUS_SET_VBR(use_vbr ? 1 : 0));
    /* DTX off is load-bearing: silence must still emit 200 pkt/s — the
       receiver's continuity engine reads cadence as a clock. */
    opus_encoder_ctl(e->enc, OPUS_SET_DTX(0));
    opus_encoder_ctl(e->enc, OPUS_SET_PACKET_LOSS_PERC(0));
    opus_encoder_ctl(e->enc, OPUS_SET_INBAND_FEC(0));

    return e;
}

int32_t lyte_opus_enc_encode(lyte_opus_enc *e, const float *pcm,
                             uint8_t *out, int32_t out_cap,
                             char *err, size_t errlen)
{
    opus_int32 n = opus_encode_float(e->enc, pcm, LYTE_OPUS_FRAME,
                                     out, out_cap);
    if (n <= 0) {
        set_err(err, errlen, "opus_encode_float: %s",
                opus_strerror(n < 0 ? n : OPUS_INTERNAL_ERROR));
        return -1;
    }
    return n;
}

void lyte_opus_enc_free(lyte_opus_enc *e)
{
    if (!e)
        return;
    if (e->enc)
        opus_encoder_destroy(e->enc);
    free(e);
}

lyte_opus_dec *lyte_opus_dec_new(char *err, size_t errlen)
{
    struct lyte_opus_dec *d = calloc(1, sizeof(*d));
    if (!d) {
        set_err(err, errlen, "out of memory");
        return NULL;
    }

    int rc = OPUS_OK;
    d->dec = opus_decoder_create(LYTE_OPUS_RATE, LYTE_OPUS_CHANNELS, &rc);
    if (rc != OPUS_OK || !d->dec) {
        set_err(err, errlen, "opus_decoder_create: %s", opus_strerror(rc));
        free(d);
        return NULL;
    }
    return d;
}

int32_t lyte_opus_dec_decode(lyte_opus_dec *d, const uint8_t *pkt,
                             int32_t len, float *pcm, int32_t pcm_cap_frames,
                             char *err, size_t errlen)
{
    int n = opus_decode_float(d->dec, pkt, len, pcm, pcm_cap_frames, 0);
    if (n <= 0) {
        set_err(err, errlen, "opus_decode_float: %s",
                opus_strerror(n < 0 ? n : OPUS_INTERNAL_ERROR));
        return -1;
    }
    return n;
}

void lyte_opus_dec_free(lyte_opus_dec *d)
{
    if (!d)
        return;
    if (d->dec)
        opus_decoder_destroy(d->dec);
    free(d);
}
