// CCuda: the CUDA *driver* API sliver NVENC needs — a context for
// nvEncOpenEncodeSessionEx (frames go through NVENC's own system-memory
// input buffers, so no device allocations). Declared by hand against the
// stable driver ABI (libcuda.so.1 ships with the display driver); the
// CUDA toolkit and its cuda.h are deliberately not a dependency. The _v2
// names are the real exported symbols.

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
