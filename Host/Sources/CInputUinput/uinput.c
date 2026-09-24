/* uinput injection leaf — see the header for the contract. */

#define _GNU_SOURCE
#include "include/lyte_uinput.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ABS_RANGE 65535

struct lyte_uinput {
    int kbd;
    int mouse;
    int tablet;
    /* Written by set_extent on the capture thread, read by absolute
       moves on the wire-drain thread — atomics, not plain ints. A
       mid-change mismatched pair scales one event against the old
       axis; a mid-session geometry change tears the session down
       anyway (the P-3 law). */
    _Atomic uint32_t width;
    _Atomic uint32_t height;
    /* v120 remainders below one detent, per axis. */
    int32_t wheel_rem_x;
    int32_t wheel_rem_y;
};

static void fill_err(char *err, size_t errlen, const char *what) {
    if (err && errlen) {
        snprintf(err, errlen, "%s: %s", what, strerror(errno));
    }
}

/* One report's events, written to the device in a single write(2):
   uinput accepts an array of input_event per write, so a key, a move
   or a scroll costs one syscall instead of two or three. */
typedef struct {
    struct input_event ev[6];
    size_t count;
} event_batch;

static void batch_add(event_batch *b, uint16_t type, uint16_t code,
                      int32_t value) {
    struct input_event *ev = &b->ev[b->count++];
    memset(ev, 0, sizeof(*ev));
    ev->type = type;
    ev->code = code;
    ev->value = value;
}

/* Appends SYN_REPORT and writes the whole report. */
static int batch_send(int fd, event_batch *b, char *err, size_t errlen) {
    batch_add(b, EV_SYN, SYN_REPORT, 0);
    ssize_t bytes = (ssize_t)(b->count * sizeof(struct input_event));
    if (write(fd, b->ev, (size_t)bytes) != bytes) {
        fill_err(err, errlen, "uinput write");
        return -1;
    }
    return 0;
}

/* Opens /dev/uinput and creates one device; caller sets the evbits via
   the setup callback before UI_DEV_CREATE. */
static int create_device(const char *name, uint16_t product,
                         int (*setup)(int fd, char *err, size_t errlen),
                         char *err, size_t errlen) {
    int fd = open("/dev/uinput", O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        fill_err(err, errlen, "open /dev/uinput");
        return -1;
    }
    if (setup(fd, err, errlen) != 0) {
        close(fd);
        return -1;
    }
    struct uinput_setup us;
    memset(&us, 0, sizeof(us));
    us.id.bustype = BUS_VIRTUAL;
    us.id.vendor = 0x1994;  /* 'lyte'-ish; only uniqueness matters */
    us.id.product = product;
    us.id.version = 1;
    snprintf(us.name, sizeof(us.name), "%s", name);
    if (ioctl(fd, UI_DEV_SETUP, &us) < 0 ||
        ioctl(fd, UI_DEV_CREATE) < 0) {
        fill_err(err, errlen, "UI_DEV_SETUP/CREATE");
        close(fd);
        return -1;
    }
    return fd;
}

static int setup_kbd(int fd, char *err, size_t errlen) {
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0) {
        fill_err(err, errlen, "UI_SET_EVBIT EV_KEY");
        return -1;
    }
    for (int code = 1; code <= 255; code++) {
        if (ioctl(fd, UI_SET_KEYBIT, code) < 0) {
            fill_err(err, errlen, "UI_SET_KEYBIT");
            return -1;
        }
    }
    return 0;
}

static int setup_mouse(int fd, char *err, size_t errlen) {
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_REL) < 0) {
        fill_err(err, errlen, "UI_SET_EVBIT mouse");
        return -1;
    }
    for (int code = BTN_LEFT; code <= BTN_TASK; code++) {
        if (ioctl(fd, UI_SET_KEYBIT, code) < 0) {
            fill_err(err, errlen, "UI_SET_KEYBIT BTN_*");
            return -1;
        }
    }
    int rels[] = {REL_X, REL_Y, REL_WHEEL, REL_HWHEEL,
                  REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES};
    for (size_t i = 0; i < sizeof(rels) / sizeof(rels[0]); i++) {
        if (ioctl(fd, UI_SET_RELBIT, rels[i]) < 0) {
            fill_err(err, errlen, "UI_SET_RELBIT");
            return -1;
        }
    }
    return 0;
}

static int setup_tablet(int fd, char *err, size_t errlen) {
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||
        ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER) < 0) {
        fill_err(err, errlen, "tablet evbits");
        return -1;
    }
    struct uinput_abs_setup abs;
    for (int axis = ABS_X; axis <= ABS_Y; axis++) {
        memset(&abs, 0, sizeof(abs));
        abs.code = (uint16_t)axis;
        abs.absinfo.minimum = 0;
        abs.absinfo.maximum = ABS_RANGE;
        if (ioctl(fd, UI_ABS_SETUP, &abs) < 0) {
            fill_err(err, errlen, "UI_ABS_SETUP");
            return -1;
        }
    }
    return 0;
}

lyte_uinput *lyte_uinput_open(char *err, size_t errlen) {
    lyte_uinput *u = calloc(1, sizeof(*u));
    if (!u) {
        fill_err(err, errlen, "calloc");
        return NULL;
    }
    u->kbd = create_device("Lyte Virtual Keyboard", 0x0001,
                           setup_kbd, err, errlen);
    if (u->kbd < 0) {
        free(u);
        return NULL;
    }
    u->mouse = create_device("Lyte Virtual Mouse", 0x0002,
                             setup_mouse, err, errlen);
    if (u->mouse < 0) {
        ioctl(u->kbd, UI_DEV_DESTROY);
        close(u->kbd);
        free(u);
        return NULL;
    }
    u->tablet = create_device("Lyte Virtual Tablet", 0x0003,
                              setup_tablet, err, errlen);
    if (u->tablet < 0) {
        ioctl(u->kbd, UI_DEV_DESTROY);
        close(u->kbd);
        ioctl(u->mouse, UI_DEV_DESTROY);
        close(u->mouse);
        free(u);
        return NULL;
    }
    return u;
}

void lyte_uinput_free(lyte_uinput *u) {
    if (!u) return;
    int fds[] = {u->kbd, u->mouse, u->tablet};
    for (size_t i = 0; i < 3; i++) {
        if (fds[i] >= 0) {
            ioctl(fds[i], UI_DEV_DESTROY);
            close(fds[i]);
        }
    }
    free(u);
}

int lyte_uinput_set_extent(lyte_uinput *u, uint32_t width, uint32_t height,
                           char *err, size_t errlen) {
    if (!width || !height) {
        if (err && errlen) snprintf(err, errlen, "zero extent");
        return -1;
    }
    u->width = width;
    u->height = height;
    return 0;
}

int lyte_uinput_key(lyte_uinput *u, uint32_t code, int pressed,
                    char *err, size_t errlen) {
    int fd = (code >= BTN_MISC && code < KEY_OK) ? u->mouse : u->kbd;
    event_batch b = {.count = 0};
    batch_add(&b, EV_KEY, (uint16_t)code, pressed ? 1 : 0);
    return batch_send(fd, &b, err, errlen);
}

int lyte_uinput_move_abs(lyte_uinput *u, double x, double y,
                         char *err, size_t errlen) {
    if (!u->width || !u->height) {
        if (err && errlen) {
            snprintf(err, errlen,
                     "absolute move before set_extent (monitor size unknown)");
        }
        return -1;
    }
    double sx = x / (double)u->width * ABS_RANGE;
    double sy = y / (double)u->height * ABS_RANGE;
    if (sx < 0) sx = 0;
    if (sy < 0) sy = 0;
    if (sx > ABS_RANGE) sx = ABS_RANGE;
    if (sy > ABS_RANGE) sy = ABS_RANGE;
    event_batch b = {.count = 0};
    batch_add(&b, EV_ABS, ABS_X, (int32_t)sx);
    batch_add(&b, EV_ABS, ABS_Y, (int32_t)sy);
    return batch_send(u->tablet, &b, err, errlen);
}

int lyte_uinput_move_rel(lyte_uinput *u, int32_t dx, int32_t dy,
                         char *err, size_t errlen) {
    event_batch b = {.count = 0};
    if (dx) batch_add(&b, EV_REL, REL_X, dx);
    if (dy) batch_add(&b, EV_REL, REL_Y, dy);
    return batch_send(u->mouse, &b, err, errlen);
}

static void scroll_axis(event_batch *b, int hires_code, int click_code,
                        int32_t v120, int32_t *rem) {
    if (!v120) return;
    batch_add(b, EV_REL, (uint16_t)hires_code, v120);
    *rem += v120;
    int32_t clicks = *rem / 120;
    if (clicks) {
        *rem -= clicks * 120;
        batch_add(b, EV_REL, (uint16_t)click_code, clicks);
    }
}

int lyte_uinput_scroll(lyte_uinput *u, int32_t v120_x, int32_t v120_y,
                       char *err, size_t errlen) {
    event_batch b = {.count = 0};
    scroll_axis(&b, REL_HWHEEL_HI_RES, REL_HWHEEL, v120_x, &u->wheel_rem_x);
    scroll_axis(&b, REL_WHEEL_HI_RES, REL_WHEEL, v120_y, &u->wheel_rem_y);
    return batch_send(u->mouse, &b, err, errlen);
}
