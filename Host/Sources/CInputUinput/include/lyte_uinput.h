#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* uinput injection leaf (HS-13's documented SECONDARY fallback; the
   primary is Mutter's internal RemoteDesktop D-Bus API). Mechanism only:
   three virtual evdev devices shaped like hardware libinput already
   understands, fed by ioctl/write — no protocol knowledge, no threads.

   CP-5 proved the unprivileged path: Sunshine's udev rule
   (60-sunshine.rules, KERNEL=="uinput" ... TAG+="uaccess") grants the
   seat user an ACL on /dev/uinput, so open(O_RDWR) needs no sudo on the
   reference host.

   Device shapes (each mirrors a proven real-world profile):
     keyboard  EV_KEY codes 1..255 (evdev keycodes; the host session's
               XKB map owns layout)
     mouse     EV_KEY BTN_LEFT..BTN_TASK, EV_REL X/Y + wheels incl.
               hi-res (the ordinary relative mouse profile)
     tablet    EV_ABS X/Y in 0..65535 + BTN_LEFT + INPUT_PROP_POINTER
               (the QEMU/VMware absolute-pointer profile — classified as
               a pointer, not a touchscreen)

   Absolute coordinates arrive in pixels; set_extent supplies the monitor
   size the leaf scales against (until then, absolute moves fail loudly).
   Scroll uses v120 units (one wheel detent = 120, the kernel's hi-res
   convention); the caller owns pixel→v120 policy. */

typedef struct lyte_uinput lyte_uinput;

/* Creates the three devices. Returns NULL with `err` filled on failure
   (no uinput access, ioctl refusal). */
lyte_uinput *lyte_uinput_open(char *err, size_t errlen);

void lyte_uinput_free(lyte_uinput *u);

/* Monitor size in pixels for absolute scaling. Nonzero required. */
int lyte_uinput_set_extent(lyte_uinput *u, uint32_t width, uint32_t height,
                           char *err, size_t errlen);

/* One key or button transition. `code` is the evdev code — keyboard
   codes route to the keyboard device, BTN_* to the mouse. */
int lyte_uinput_key(lyte_uinput *u, uint32_t code, int pressed,
                    char *err, size_t errlen);

/* Absolute pointer motion, pixels (scaled against the extent). */
int lyte_uinput_move_abs(lyte_uinput *u, double x, double y,
                         char *err, size_t errlen);

/* Relative pointer motion, whole pixels. */
int lyte_uinput_move_rel(lyte_uinput *u, int32_t dx, int32_t dy,
                         char *err, size_t errlen);

/* Scroll in v120 units (120 = one detent). Emits hi-res events plus
   accumulated whole-detent REL_WHEEL/REL_HWHEEL clicks. */
int lyte_uinput_scroll(lyte_uinput *u, int32_t v120_x, int32_t v120_y,
                       char *err, size_t errlen);

#ifdef __cplusplus
}
#endif
