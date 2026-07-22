/* uinput injection leaf — see the header for the contract. */

#define _GNU_SOURCE
#include "include/lyte_uinput.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ABS_RANGE 65535

struct lyte_uinput {
    int kbd;
    int mouse;
    int tablet;
    uint32_t width;
    uint32_t height;
    /* v120 remainders below one detent, per axis. */
    int32_t wheel_rem_x;
    int32_t wheel_rem_y;
};

static void fill_err(char *err, size_t errlen, const char *what) {
    if (err && errlen) {
        snprintf(err, errlen, "%s: %s", what, strerror(errno));
    }
}

static int emit(int fd, uint16_t type, uint16_t code, int32_t value,
                char *err, size_t errlen) {
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    if (write(fd, &ev, sizeof(ev)) != sizeof(ev)) {
        fill_err(err, errlen, "uinput write");
        return -1;
    }
    return 0;
}

static int emit_syn(int fd, char *err, size_t errlen) {
    return emit(fd, EV_SYN, SYN_REPORT, 0, err, errlen);
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
    if (emit(fd, EV_KEY, (uint16_t)code, pressed ? 1 : 0, err, errlen) != 0) {
        return -1;
    }
    return emit_syn(fd, err, errlen);
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
    if (emit(u->tablet, EV_ABS, ABS_X, (int32_t)sx, err, errlen) != 0 ||
        emit(u->tablet, EV_ABS, ABS_Y, (int32_t)sy, err, errlen) != 0) {
        return -1;
    }
    return emit_syn(u->tablet, err, errlen);
}

int lyte_uinput_move_rel(lyte_uinput *u, int32_t dx, int32_t dy,
                         char *err, size_t errlen) {
    if (dx && emit(u->mouse, EV_REL, REL_X, dx, err, errlen) != 0) return -1;
    if (dy && emit(u->mouse, EV_REL, REL_Y, dy, err, errlen) != 0) return -1;
    return emit_syn(u->mouse, err, errlen);
}

static int scroll_axis(lyte_uinput *u, int hires_code, int click_code,
                       int32_t v120, int32_t *rem, char *err, size_t errlen) {
    if (!v120) return 0;
    if (emit(u->mouse, EV_REL, (uint16_t)hires_code, v120, err, errlen) != 0) {
        return -1;
    }
    *rem += v120;
    int32_t clicks = *rem / 120;
    if (clicks) {
        *rem -= clicks * 120;
        if (emit(u->mouse, EV_REL, (uint16_t)click_code, clicks,
                 err, errlen) != 0) {
            return -1;
        }
    }
    return 0;
}

int lyte_uinput_scroll(lyte_uinput *u, int32_t v120_x, int32_t v120_y,
                       char *err, size_t errlen) {
    if (scroll_axis(u, REL_HWHEEL_HI_RES, REL_HWHEEL, v120_x,
                    &u->wheel_rem_x, err, errlen) != 0 ||
        scroll_axis(u, REL_WHEEL_HI_RES, REL_WHEEL, v120_y,
                    &u->wheel_rem_y, err, errlen) != 0) {
        return -1;
    }
    return emit_syn(u->mouse, err, errlen);
}
