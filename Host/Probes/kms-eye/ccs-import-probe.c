// ccs-import-probe: the third link of Lyte's KMS capture prototype.
//
// Established so far on pup (IdeaPad Pro 5 16IMH9, Meteor Lake):
//   1. Doorbell works: primary-plane FB_ID poll = free damage detection
//      (1 flip/s idle, 61/s motion, 4us/poll).
//   2. kmsgrab exports the scanout dmabuf; Arc VAAPI encoders emit real
//      HEVC/AV1 bytes.
//   3. BUT the media engine's VPP (scale_vaapi) cannot digest the
//      scanout buffer directly: XR30 (10-bit RGB) with Intel CCS
//      compression modifier 0x10000000000000f -> "operation failed".
//
// Question under test here: can the 3D engine (EGL/OpenGL via GBM,
// headless) import that exact compressed buffer and hand back real
// pixels?  If yes, the production pipeline is:
//   scanout dmabuf -> EGL import (3D engine reads CCS natively)
//   -> shader blit to plain NV12 -> VAAPI encode.  All GPU-side.
// (The glGetTexImage readback below is PROOF OF PIXEL ACCESS for the
// probe only; the real pipeline never downloads to CPU.)
//
// Build: gcc -O2 -o ccs-import-probe ccs-import-probe.c \
//          -ldrm -lgbm -lEGL -lGL -I/usr/include/libdrm
// Run:   sudo ./ccs-import-probe /dev/dri/card1   (GETFB2 needs privs)

#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <fcntl.h>
#include <gbm.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint64_t plane_type(int fd, uint32_t plane_id) {
    uint64_t type = ~0ULL;
    drmModeObjectProperties *props =
        drmModeObjectGetProperties(fd, plane_id, DRM_MODE_OBJECT_PLANE);
    if (!props) return type;
    for (uint32_t i = 0; i < props->count_props; i++) {
        drmModePropertyRes *p = drmModeGetProperty(fd, props->props[i]);
        if (p) {
            if (!strcmp(p->name, "type")) type = props->prop_values[i];
            drmModeFreeProperty(p);
        }
    }
    drmModeFreeObjectProperties(props);
    return type;
}

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/dri/card1";
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror(dev); return 1; }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);

    // --- find the active primary plane's framebuffer ---
    drmModePlaneRes *pr = drmModeGetPlaneResources(fd);
    uint32_t fb_id = 0;
    for (uint32_t i = 0; pr && i < pr->count_planes; i++) {
        drmModePlane *pl = drmModeGetPlane(fd, pr->planes[i]);
        if (!pl) continue;
        if (pl->crtc_id && pl->fb_id &&
            plane_type(fd, pl->plane_id) == DRM_PLANE_TYPE_PRIMARY)
            fb_id = pl->fb_id;
        drmModeFreePlane(pl);
        if (fb_id) break;
    }
    drmModeFreePlaneResources(pr);
    if (!fb_id) { fprintf(stderr, "no active primary fb\n"); return 1; }

    // --- GETFB2: geometry, format, modifier, per-plane handles ---
    drmModeFB2 *fb = drmModeGetFB2(fd, fb_id);
    if (!fb) { perror("drmModeGetFB2 (need sudo)"); return 1; }
    printf("fb=%u %ux%u fourcc=%.4s modifier=0x%" PRIx64 "\n",
           fb_id, fb->width, fb->height, (char *)&fb->pixel_format,
           fb->modifier);

    int nplanes = 0;
    int dmabuf[4] = {-1, -1, -1, -1};
    for (int i = 0; i < 4; i++) {
        if (!fb->handles[i]) break;
        nplanes++;
        // duplicate handles may repeat; export each occurrence
        if (drmPrimeHandleToFD(fd, fb->handles[i], O_CLOEXEC, &dmabuf[i])) {
            perror("drmPrimeHandleToFD");
            return 1;
        }
        printf("  plane[%d] handle=%u pitch=%u offset=%u fd=%d\n", i,
               fb->handles[i], fb->pitches[i], fb->offsets[i], dmabuf[i]);
    }

    // --- headless EGL on the same GPU via GBM ---
    struct gbm_device *gbm = gbm_create_device(fd);
    if (!gbm) { fprintf(stderr, "gbm_create_device failed\n"); return 1; }
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, NULL, NULL)) {
        fprintf(stderr, "eglInitialize failed\n");
        return 1;
    }
    eglBindAPI(EGL_OPENGL_API);
    static const EGLint ctx_attribs[] = {EGL_NONE};
    EGLContext ctx =
        eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctx_attribs);
    if (ctx == EGL_NO_CONTEXT ||
        !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
        fprintf(stderr, "EGL context failed: 0x%x\n", eglGetError());
        return 1;
    }
    printf("GL: %s / %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

    // --- import the scanout dmabuf WITH its modifier ---
    EGLint attribs[64];
    int a = 0;
    attribs[a++] = EGL_WIDTH;              attribs[a++] = fb->width;
    attribs[a++] = EGL_HEIGHT;             attribs[a++] = fb->height;
    attribs[a++] = EGL_LINUX_DRM_FOURCC_EXT;
    attribs[a++] = fb->pixel_format;
    static const EGLint fd_attr[4] = {
        EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
        EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT};
    static const EGLint off_attr[4] = {
        EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT,
        EGL_DMA_BUF_PLANE2_OFFSET_EXT, EGL_DMA_BUF_PLANE3_OFFSET_EXT};
    static const EGLint pit_attr[4] = {
        EGL_DMA_BUF_PLANE0_PITCH_EXT, EGL_DMA_BUF_PLANE1_PITCH_EXT,
        EGL_DMA_BUF_PLANE2_PITCH_EXT, EGL_DMA_BUF_PLANE3_PITCH_EXT};
    static const EGLint mlo_attr[4] = {
        EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
        EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT};
    static const EGLint mhi_attr[4] = {
        EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
        EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT};
    for (int i = 0; i < nplanes; i++) {
        attribs[a++] = fd_attr[i];  attribs[a++] = dmabuf[i];
        attribs[a++] = off_attr[i]; attribs[a++] = fb->offsets[i];
        attribs[a++] = pit_attr[i]; attribs[a++] = fb->pitches[i];
        attribs[a++] = mlo_attr[i];
        attribs[a++] = (EGLint)(fb->modifier & 0xffffffff);
        attribs[a++] = mhi_attr[i];
        attribs[a++] = (EGLint)(fb->modifier >> 32);
    }
    attribs[a++] = EGL_NONE;

    // The KHR variant takes EGLint attribs — maximum driver compat.
    PFNEGLCREATEIMAGEKHRPROC createImage =
        (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    double t0 = now_s();
    EGLImage img = createImage(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT,
                               NULL, attribs);
    if (img == EGL_NO_IMAGE) {
        fprintf(stderr, "RESULT: EGL IMPORT FAILED 0x%x "
                        "(modifier not importable by 3D engine)\n",
                eglGetError());
        return 2;
    }
    double t_import = now_s() - t0;

    // --- bind as texture and read real pixels back (proof only) ---
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC targetTex =
        (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress(
            "glEGLImageTargetTexture2DOES");
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    targetTex(GL_TEXTURE_2D, (GLeglImageOES)img);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        fprintf(stderr, "RESULT: TEXTURE BIND FAILED 0x%x\n", err);
        return 2;
    }

    size_t bufsz = (size_t)fb->width * fb->height * 4;
    unsigned char *buf = malloc(bufsz);
    memset(buf, 0, bufsz);
    t0 = now_s();
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, buf);
    err = glGetError();
    double t_read = now_s() - t0;
    if (err != GL_NO_ERROR) {
        fprintf(stderr, "RESULT: READBACK FAILED 0x%x\n", err);
        return 2;
    }

    // Non-uniformity check: a real desktop is not a constant color.
    unsigned distinct = 0;
    unsigned seen[8] = {0};
    for (size_t i = 0; i < bufsz; i += 4097 * 4) {
        unsigned px;
        memcpy(&px, buf + (i % (bufsz - 4)), 4);
        int found = 0;
        for (unsigned s = 0; s < distinct && s < 8; s++)
            if (seen[s] == px) found = 1;
        if (!found && distinct < 8) seen[distinct++] = px;
    }
    unsigned long long sum = 0;
    for (size_t i = 0; i < bufsz; i += 997) sum += buf[i];
    printf("RESULT: SUCCESS import=%.2fms decompress+readback=%.1fms "
           "distinct_sampled_pixels=%u checksum=%llu\n",
           t_import * 1e3, t_read * 1e3, distinct, sum);
    printf("center pixel RGBA = %u %u %u %u\n",
           buf[(((size_t)fb->height / 2) * fb->width + fb->width / 2) * 4],
           buf[(((size_t)fb->height / 2) * fb->width + fb->width / 2) * 4 + 1],
           buf[(((size_t)fb->height / 2) * fb->width + fb->width / 2) * 4 + 2],
           buf[(((size_t)fb->height / 2) * fb->width + fb->width / 2) * 4 + 3]);
    return 0;
}
