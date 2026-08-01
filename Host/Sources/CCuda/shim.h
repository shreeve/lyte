// CCuda: the sliver of the CUDA *driver* API that NVENC needs — a
// CUDA context to hand nvEncOpenEncodeSessionEx (E6a feeds frames
// through NVENC's own system-memory input buffers, so no device
// allocations live here). Declared by hand against the stable,
// documented driver ABI (libcuda.so.1 ships with the display driver;
// the CUDA *toolkit* — and its cuda.h — is deliberately NOT a
// dependency). The _v2 names are the real exported symbols for the
// post-3.2 ABI.

#ifndef LYTE_CCUDA_SHIM_H
#define LYTE_CCUDA_SHIM_H

typedef int CUresult;   /* 0 == CUDA_SUCCESS */
typedef int CUdevice;
typedef struct CUctx_st *CUcontext;

CUresult cuInit(unsigned int flags);
CUresult cuDriverGetVersion(int *version);
CUresult cuDeviceGetCount(int *count);
CUresult cuDeviceGet(CUdevice *device, int ordinal);
CUresult cuDeviceGetName(char *name, int length, CUdevice device);
CUresult cuCtxCreate_v2(CUcontext *context, unsigned int flags,
                        CUdevice device);
CUresult cuCtxDestroy_v2(CUcontext context);

#endif
