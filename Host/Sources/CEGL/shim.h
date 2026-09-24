// CEGL: EGL 1.5 + desktop GL for the direct eye — modifier-aware dmabuf
// import (Mesa reads the CCS-compressed scanout) and the RGB→NV12 blit.
// Extension-only functions (glEGLImageTargetTexture2DOES) load via
// eglGetProcAddress at runtime.
#define EGL_EGLEXT_PROTOTYPES 1
#define GL_GLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
