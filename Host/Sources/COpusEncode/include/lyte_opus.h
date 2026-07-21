#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* libopus leaf, pinned to the dialect's audio ground truth: 48 kHz stereo,
   OPUS_APPLICATION_RESTRICTED_LOWDELAY (CELT-only — 5 ms frames are
   CELT-only regardless), DTX forced OFF so every 5 ms tick emits a packet
   (silence included; cadence is load-bearing for the receiver's clock).
   The decoder half exists for loop-decode verification harnesses and the
   client's eventual libopus PLC path. */

#define LYTE_OPUS_RATE       48000
#define LYTE_OPUS_CHANNELS   2
#define LYTE_OPUS_FRAME      240 /* samples per channel = 5 ms at 48 kHz */
#define LYTE_OPUS_MAX_PACKET 1500

typedef struct lyte_opus_enc lyte_opus_enc;
typedef struct lyte_opus_dec lyte_opus_dec;

/* Creates the encoder. `bitrate` in bits/s (Lyte default 128000).
   `use_vbr` zero (the dialect: hard CBR, constant packet bytes) or nonzero
   (unconstrained VBR — harness/evidence use only, where silence-vs-signal
   packet sizes prove the pipeline carries real audio).
   Returns NULL with `err` filled on failure. */
lyte_opus_enc *lyte_opus_enc_new(int32_t bitrate, int use_vbr,
                                 char *err, size_t errlen);

/* Encodes exactly LYTE_OPUS_FRAME interleaved F32 stereo samples per call
   (`pcm` holds LYTE_OPUS_FRAME * LYTE_OPUS_CHANNELS floats). Returns the
   packet byte count written to `out` (>0), or -1 with `err` filled. */
int32_t lyte_opus_enc_encode(lyte_opus_enc *e, const float *pcm,
                             uint8_t *out, int32_t out_cap,
                             char *err, size_t errlen);

void lyte_opus_enc_free(lyte_opus_enc *e);

/* Creates the matching 48 kHz stereo decoder. */
lyte_opus_dec *lyte_opus_dec_new(char *err, size_t errlen);

/* Decodes one packet into interleaved F32 stereo. `pcm_cap_frames` is the
   capacity of `pcm` in samples-per-channel (>= LYTE_OPUS_FRAME). Returns
   frames decoded (>0), or -1 with `err` filled. */
int32_t lyte_opus_dec_decode(lyte_opus_dec *d, const uint8_t *pkt,
                             int32_t len, float *pcm, int32_t pcm_cap_frames,
                             char *err, size_t errlen);

void lyte_opus_dec_free(lyte_opus_dec *d);

#ifdef __cplusplus
}
#endif
