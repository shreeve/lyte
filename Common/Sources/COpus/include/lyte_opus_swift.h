#pragma once

#include <opus/opus.h>

/* Swift cannot import C variadic functions. Keep this bridge deliberately
   policy-free: role-layer Swift supplies both the request and value. */
static inline int lyte_opus_encoder_ctl_int(
    OpusEncoder *encoder, int request, int value
) {
    return opus_encoder_ctl(encoder, request, value);
}
