// CNvEnc: the NVENC SDK surface for the E6a native encoder
// (direct-eye plan E6a — the SDK writes its own headers and
// NvEncReconfigureEncoder kills the no-reset patch at the root).
//
// nvEncodeAPI.h is VENDORED next to this shim (FFmpeg's
// nv-codec-headers n12.2.72.0, MIT-licensed by NVIDIA for exactly
// this use; driver 595.84 on pup speaks API ≥ 12.2). The runtime
// library is the driver's own libnvidia-encode.so.1 — linked, not
// dlopen'd: a missing driver fails loudly at spawn, never silently
// mid-session.
//
// The *_VER macros compose NVENCAPI_STRUCT_VERSION() expressions the
// Swift importer cannot see — re-exported here as plain constants
// (only the ones the E6a code touches; extend as the wrapper grows).

#ifndef LYTE_CNVENC_SHIM_H
#define LYTE_CNVENC_SHIM_H

#include "nvEncodeAPI.h"

static const uint32_t LYTE_NVENCAPI_VERSION = NVENCAPI_VERSION;
static const uint32_t LYTE_NV_ENCODE_API_FUNCTION_LIST_VER =
    NV_ENCODE_API_FUNCTION_LIST_VER;
static const uint32_t LYTE_NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER =
    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
static const uint32_t LYTE_NV_ENC_INITIALIZE_PARAMS_VER =
    NV_ENC_INITIALIZE_PARAMS_VER;
static const uint32_t LYTE_NV_ENC_PRESET_CONFIG_VER =
    NV_ENC_PRESET_CONFIG_VER;
static const uint32_t LYTE_NV_ENC_CONFIG_VER = NV_ENC_CONFIG_VER;
static const uint32_t LYTE_NV_ENC_CREATE_INPUT_BUFFER_VER =
    NV_ENC_CREATE_INPUT_BUFFER_VER;
static const uint32_t LYTE_NV_ENC_CREATE_BITSTREAM_BUFFER_VER =
    NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
static const uint32_t LYTE_NV_ENC_LOCK_INPUT_BUFFER_VER =
    NV_ENC_LOCK_INPUT_BUFFER_VER;
static const uint32_t LYTE_NV_ENC_LOCK_BITSTREAM_VER =
    NV_ENC_LOCK_BITSTREAM_VER;
static const uint32_t LYTE_NV_ENC_PIC_PARAMS_VER = NV_ENC_PIC_PARAMS_VER;
static const uint32_t LYTE_NV_ENC_RECONFIGURE_PARAMS_VER =
    NV_ENC_RECONFIGURE_PARAMS_VER;

#endif
