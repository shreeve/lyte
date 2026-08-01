// fbid-poll: the doorbell prototype for Lyte's KMS capture design.
//
// Question under test: can we recover damage detection WITHOUT the
// compositor's cooperation by polling the scanout plane's framebuffer
// ID?  The compositor flips a NEW framebuffer only when it repainted;
// an unchanged ID is proof that not one pixel changed.  If this works,
// idle silence survives the move off Mutter's ScreenCast, and cadence
// (0 fps idle .. 60 fps video) becomes a consequence of content.
//
// Method: enumerate DRM planes on the given device, find the active
// PRIMARY plane (the desktop) and the active CURSOR plane, then poll
// their fb_id at the given interval, recording every change with a
// monotonic timestamp.  Report per-second change counts, inter-change
// gap stats, and the measured cost of one poll.
//
// This is intentionally unprivileged: GETPLANE is a read-only query.
// (Only reading PIXELS — GETFB2 — needs CAP_SYS_ADMIN.)
//
// Build: gcc -O2 -o fbid-poll fbid-poll.c -ldrm -I/usr/include/libdrm
// Usage: ./fbid-poll /dev/dri/card1 <seconds> <poll_interval_us>

#include <fcntl.h>
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

typedef struct {
    uint32_t plane_id;
    uint32_t last_fb;
    long changes;
    double last_change_t;
    double min_gap, max_gap;
} watch_t;

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
    double seconds = argc > 2 ? atof(argv[2]) : 15.0;
    long interval_us = argc > 3 ? atol(argv[3]) : 1000;

    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror(dev); return 1; }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);

    drmModePlaneRes *pr = drmModeGetPlaneResources(fd);
    if (!pr) { fprintf(stderr, "no plane resources\n"); return 1; }

    watch_t primary = {0}, cursor = {0};
    for (uint32_t i = 0; i < pr->count_planes; i++) {
        drmModePlane *pl = drmModeGetPlane(fd, pr->planes[i]);
        if (!pl) continue;
        if (pl->crtc_id && pl->fb_id) {   // active on a live CRTC
            uint64_t t = plane_type(fd, pl->plane_id);
            if (t == DRM_PLANE_TYPE_PRIMARY && !primary.plane_id) {
                primary.plane_id = pl->plane_id;
                primary.last_fb = pl->fb_id;
            } else if (t == DRM_PLANE_TYPE_CURSOR && !cursor.plane_id) {
                cursor.plane_id = pl->plane_id;
                cursor.last_fb = pl->fb_id;
            }
        }
        drmModeFreePlane(pl);
    }
    drmModeFreePlaneResources(pr);

    if (!primary.plane_id) {
        fprintf(stderr, "no active primary plane on %s\n", dev);
        return 1;
    }
    printf("device=%s primary_plane=%u cursor_plane=%u poll=%ldus run=%.0fs\n",
           dev, primary.plane_id, cursor.plane_id, interval_us, seconds);

    primary.min_gap = cursor.min_gap = 1e9;
    long polls = 0;
    double poll_cost_ns = 0;
    double t0 = now_s(), t = t0;
    double next_report = t0 + 1.0;
    long prim_this_sec = 0;

    while ((t = now_s()) - t0 < seconds) {
        double c0 = now_s();
        watch_t *ws[2] = { &primary, cursor.plane_id ? &cursor : NULL };
        for (int w = 0; w < 2; w++) {
            if (!ws[w]) continue;
            drmModePlane *pl = drmModeGetPlane(fd, ws[w]->plane_id);
            if (!pl) continue;
            if (pl->fb_id != ws[w]->last_fb) {
                if (ws[w]->changes > 0 || 1) {
                    double gap = t - ws[w]->last_change_t;
                    if (ws[w]->last_change_t > 0) {
                        if (gap < ws[w]->min_gap) ws[w]->min_gap = gap;
                        if (gap > ws[w]->max_gap) ws[w]->max_gap = gap;
                    }
                }
                ws[w]->last_change_t = t;
                ws[w]->last_fb = pl->fb_id;
                ws[w]->changes++;
                if (w == 0) prim_this_sec++;
            }
            drmModeFreePlane(pl);
        }
        poll_cost_ns += (now_s() - c0) * 1e9;
        polls++;
        if (t >= next_report) {
            printf("  t=%2.0fs primary_flips_this_sec=%ld total=%ld\n",
                   t - t0, prim_this_sec, primary.changes);
            fflush(stdout);
            prim_this_sec = 0;
            next_report += 1.0;
        }
        usleep(interval_us);
    }

    double dur = t - t0;
    printf("RESULT primary: %ld flips in %.1fs = %.2f/s  gap_min=%.1fms gap_max=%.1fms\n",
           primary.changes, dur, primary.changes / dur,
           primary.changes > 1 ? primary.min_gap * 1e3 : 0,
           primary.changes > 1 ? primary.max_gap * 1e3 : 0);
    if (cursor.plane_id)
        printf("RESULT cursor:  %ld flips in %.1fs = %.2f/s\n",
               cursor.changes, dur, cursor.changes / dur);
    printf("RESULT poll cost: %.0f ns/poll (%ld polls)\n",
           poll_cost_ns / polls, polls);
    close(fd);
    return 0;
}
