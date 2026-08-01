// CVA: libva surface export — vaExportSurfaceHandle turns a VAAPI
// surface into per-plane dmabufs (VADRMPRIMESurfaceDescriptor) that
// EGL imports as render targets for the direct eye's NV12 blit.
// DELIBERATELY includes ONLY VA headers: overlapping libavutil types
// here would mint duplicate Swift types against CLibAV's.
#include <va/va.h>
#include <va/va_drmcommon.h>
