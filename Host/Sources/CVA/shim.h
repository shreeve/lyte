// CVA: the libva surface for the direct eye — surface export (the blit's
// dmabuf bridge: vaExportSurfaceHandle → VADRMPRIMESurfaceDescriptor) and
// the native HEVC encode entrypoints. Includes only VA headers: the driver
// boundary and nothing above it.
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_enc_hevc.h>
