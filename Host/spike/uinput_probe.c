// CP-5 spike (throwaway): uinput fallback feasibility probe.
//
// Answers HS-13 fallback question 5: can an unprivileged process on the host
// create a virtual keyboard via /dev/uinput and have the kernel actually
// emit the injected key? We create a device, then read the events back
// from the kernel-assigned /dev/input/eventN node (evtest-style readback)
// to prove the full input path works end to end. No sudo, no portal.
//
//   cc -O2 -o /tmp/uinput_probe uinput_probe.c && /tmp/uinput_probe
//
// Exit 0 = created + read back the injected KEY_A down/up. Nonzero = the
// failure mode (printed to stderr), which is itself the deliverable.

#include <errno.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static void emit(int fd, int type, int code, int val) {
    struct input_event ev = {0};
    ev.type = type;
    ev.code = code;
    ev.value = val;
    if (write(fd, &ev, sizeof ev) != (ssize_t)sizeof ev)
        fprintf(stderr, "warn: write ev(%d,%d,%d) failed: %s\n",
                type, code, val, strerror(errno));
}

int main(void) {
    int fd = open("/dev/uinput", O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "FAIL open /dev/uinput: %s\n", strerror(errno));
        return 2;
    }
    printf("ok: opened /dev/uinput rw (no sudo)\n");

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, KEY_A);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);

    struct uinput_setup us = {0};
    us.id.bustype = BUS_USB;
    us.id.vendor = 0x1d1d;   // "lyte"
    us.id.product = 0x5000;
    strncpy(us.name, "lyte-spike-kbd", sizeof us.name - 1);
    if (ioctl(fd, UI_DEV_SETUP, &us) < 0) {
        fprintf(stderr, "FAIL UI_DEV_SETUP: %s\n", strerror(errno));
        return 3;
    }
    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        fprintf(stderr, "FAIL UI_DEV_CREATE: %s\n", strerror(errno));
        return 4;
    }

    char sysname[64] = {0};
    if (ioctl(fd, UI_GET_SYSNAME(sizeof sysname), sysname) < 0) {
        fprintf(stderr, "FAIL UI_GET_SYSNAME: %s\n", strerror(errno));
        return 5;
    }
    printf("ok: device created, kernel sysname=%s\n", sysname);

    // Resolve the eventN node the kernel bound to this uinput device.
    char evpath[128] = {0};
    char globdir[128];
    snprintf(globdir, sizeof globdir, "/sys/devices/virtual/input/%s", sysname);
    // The eventN dir lives under the input's sysfs; scan for "event*".
    char cmd[256];
    snprintf(cmd, sizeof cmd,
             "ls -d /sys/devices/virtual/input/%s/event* 2>/dev/null "
             "| head -1 | xargs -r basename",
             sysname);
    FILE *p = popen(cmd, "r");
    char evname[64] = {0};
    if (p && fgets(evname, sizeof evname, p)) {
        evname[strcspn(evname, "\n")] = 0;
        snprintf(evpath, sizeof evpath, "/dev/input/%s", evname);
    }
    if (p) pclose(p);
    if (!evpath[0]) {
        fprintf(stderr, "FAIL: could not resolve /dev/input/eventN for %s\n", sysname);
        ioctl(fd, UI_DEV_DESTROY);
        return 6;
    }
    printf("ok: event node = %s\n", evpath);

    int rfd = open(evpath, O_RDONLY | O_NONBLOCK);
    if (rfd < 0) {
        fprintf(stderr, "NOTE: cannot open %s for readback: %s "
                "(device created OK; readback is the only blocked step)\n",
                evpath, strerror(errno));
        // Still emit so a listener/desktop would receive it.
        emit(fd, EV_KEY, KEY_A, 1);
        emit(fd, EV_SYN, SYN_REPORT, 0);
        emit(fd, EV_KEY, KEY_A, 0);
        emit(fd, EV_SYN, SYN_REPORT, 0);
        ioctl(fd, UI_DEV_DESTROY);
        return 7;
    }

    usleep(50 * 1000); // let udev settle

    emit(fd, EV_KEY, KEY_A, 1);
    emit(fd, EV_SYN, SYN_REPORT, 0);
    emit(fd, EV_KEY, KEY_A, 0);
    emit(fd, EV_SYN, SYN_REPORT, 0);

    // Read back, with a short poll budget.
    int got_down = 0, got_up = 0;
    for (int i = 0; i < 200 && !(got_down && got_up); i++) {
        struct input_event ev;
        ssize_t n = read(rfd, &ev, sizeof ev);
        if (n == (ssize_t)sizeof ev) {
            if (ev.type == EV_KEY && ev.code == KEY_A) {
                if (ev.value == 1) got_down = 1;
                if (ev.value == 0) got_up = 1;
                printf("readback: EV_KEY KEY_A value=%d\n", ev.value);
            }
        } else {
            usleep(5 * 1000);
        }
    }

    close(rfd);
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);

    if (got_down && got_up) {
        printf("PASS: injected KEY_A down+up read back from kernel event node\n");
        return 0;
    }
    fprintf(stderr, "FAIL: did not read injected key back (down=%d up=%d)\n",
            got_down, got_up);
    return 8;
}
