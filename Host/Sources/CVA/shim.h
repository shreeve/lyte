// CVA: the libva surface for the direct eye — surface export (the
// E1 blit's dmabuf bridge: vaExportSurfaceHandle →
// VADRMPRIMESurfaceDescriptor) and, since E6b, the NATIVE encode
// entrypoints: DRM display open (va_drm.h), config/context/buffer
// calls, and the HEVC encode parameter structs (va_enc_hevc.h).
// DELIBERATELY includes ONLY VA headers — the driver boundary and
// nothing above it.
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_enc_hevc.h>
