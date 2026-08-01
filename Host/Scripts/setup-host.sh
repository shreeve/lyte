#!/usr/bin/env bash
# setup-host.sh — one-shot, idempotent machine prerequisites for a new
# lyte-host box (GNOME/Mutter Wayland). Run as the seat user; re-run
# any time — it only reports or repairs, never duplicates.
#
# What a fresh machine needs beyond the binary:
#
#  1. Mutter must keep compositing fullscreen video. By default Mutter
#     promotes a fullscreen surface to DIRECT SCANOUT a few seconds in;
#     compositing stops and the ScreenCast delivers nothing — the
#     remote glass freezes (2026-07-30 verdict: three wake IDRs in
#     35 s, 1 s capture gaps, clock-tick frames). There is no runtime
#     toggle on stock Mutter; the paint-debug flag must sit in
#     gnome-shell's login environment, so it goes in environment.d and
#     takes effect at the NEXT login. lyte-host testifies at startup
#     when the running gnome-shell lacks it.
#
#  2. /dev/uinput seat access for the CInputUinput fallback input
#     backend (HS-13). Needs root, so this script prints the exact
#     sudo command instead of escalating itself.
#
#  3. An rtprio rlimit lets the latency-owning audio and wire-drain
#     threads obtain SCHED_RR. Optional: the binary degrades safely,
#     and this script only checks/prints the prerequisite.
set -euo pipefail

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
todo() { printf '  \033[33m→\033[0m %s\n' "$1"; }

echo "lyte-host machine setup"

# --- 1. Mutter direct-scanout opt-out (screencast starvation) --------
ENVD="$HOME/.config/environment.d"
CONF="$ENVD/90-lyte-screencast.conf"
FLAG="disable-direct-scanout"

if [ -f "$CONF" ] && grep -q "$FLAG" "$CONF"; then
    ok "environment.d flag present: $CONF"
else
    mkdir -p "$ENVD"
    cat > "$CONF" <<'EOF'
# Lyte: keep Mutter compositing fullscreen video so the ScreenCast
# never starves (direct scanout bypasses the compositor and freezes
# the remote stream). Read by gnome-shell at login; delete this file
# to restore direct scanout.
MUTTER_DEBUG_PAINT=disable-direct-scanout
EOF
    ok "wrote $CONF"
fi

# Is the RUNNING gnome-shell already carrying it? (environ is NUL-
# separated; grep the raw bytes.)
SHELL_PID="$(pgrep -x -u "$(id -u)" gnome-shell | head -1 || true)"
if [ -z "$SHELL_PID" ]; then
    todo "no gnome-shell session found — flag activates at first login"
elif tr '\0' '\n' < "/proc/$SHELL_PID/environ" 2>/dev/null \
        | grep -q "^MUTTER_DEBUG_PAINT=.*$FLAG"; then
    ok "running gnome-shell (pid $SHELL_PID) already has the flag"
else
    todo "running gnome-shell (pid $SHELL_PID) does NOT have the flag yet — log out and back in"
fi

# --- 2. uinput seat access (input-injection fallback) ----------------
RULE="/etc/udev/rules.d/60-lyte-uinput.rules"
if [ -f "$RULE" ]; then
    ok "udev rule present: $RULE"
else
    todo "udev rule missing — run:"
    cat <<'EOF'
    sudo tee /etc/udev/rules.d/60-lyte-uinput.rules >/dev/null <<'RULE'
# Lyte: seat-user access to /dev/uinput for the CInputUinput fallback
# backend (HS-13). Carried over from Sunshine 60-sunshine.rules at its
# H2-exit uninstall (2026-07-22).
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", GROUP="input", MODE="0660", TAG+="uaccess"
RULE
    sudo udevadm control --reload && sudo udevadm trigger /dev/uinput
EOF
fi

# --- 3. Optional SCHED_RR prerequisite -------------------------------
RTPRIO="$(ulimit -r 2>/dev/null || printf '0')"
if [ "${RTPRIO:-0}" -ge 20 ] 2>/dev/null; then
    ok "realtime scheduling allowance is $RTPRIO (need 20)"
else
    todo "realtime scheduling allowance is ${RTPRIO:-0}; optional loaded-host latency prerequisite:"
    printf '    echo "%s - rtprio 20" | sudo tee /etc/security/limits.d/90-lyte-rtprio.conf\n' "$USER"
    todo "log out and back in after granting it; this script does not mutate limits"
fi

echo "done."
