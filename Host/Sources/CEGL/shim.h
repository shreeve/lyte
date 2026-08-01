// CEGL: EGL 1.5 + desktop GL for the direct eye's 3D-engine leg — the
// modifier-aware dmabuf import (ccs-import-probe proved Mesa reads the
// CCS-compressed scanout here) and the RGB→NV12 blit. PROTOTYPES
// macros expose core entry points; the few extension-only functions
// (glEGLImageTargetTexture2DOES) load via eglGetProcAddress at runtime.
#define EGL_EGLEXT_PROTOTYPES 1
#define GL_GLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
