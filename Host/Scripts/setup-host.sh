#!/usr/bin/env bash
# setup-host.sh — one-shot, idempotent machine prerequisites for a new
# lyte-host box (GNOME/Mutter Wayland). Run as the seat user; re-run
# any time — it only reports or repairs, never duplicates.
#
# What a fresh machine needs beyond the binary:
#
#  1. CAP_SYS_ADMIN on the lyte-host binary — the direct eye's DRM
#     ticket (GETFB2 + dmabuf export of the scanout). File capabilities
#     don't survive a rebuild, so this must be re-armed after EVERY
#     `swift build`. Needs root; this script prints the exact command
#     and reports current state.
#
#  2. /dev/uinput seat access for the CInputUinput input backend —
#     E2 made it PRIMARY (the Mutter RemoteDesktop injector is
#     retired), so without this rule client input is OFF. Needs root,
#     so this script prints the exact sudo command instead of
#     escalating itself.
#
#  3. An rtprio rlimit lets the latency-owning audio and wire-drain
#     threads obtain SCHED_RR. Optional: the binary degrades safely,
#     and this script only checks/prints the prerequisite.
#
# (The portal era's MUTTER_DEBUG_PAINT=disable-direct-scanout flag is
# GONE with E5: the direct eye reads the scanout itself, so Mutter may
# promote fullscreen surfaces freely. If an old
# ~/.config/environment.d/90-lyte-screencast.conf lingers, this script
# offers its removal.)
set -euo pipefail

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
todo() { printf '  \033[33m→\033[0m %s\n' "$1"; }

echo "lyte-host machine setup"

# --- 1. CAP_SYS_ADMIN on the binary (the direct eye's DRM ticket) ----
BIN="${LYTE_HOST_BIN:-$HOME/src/lyte-host/.build/debug/lyte-host}"
if [ ! -x "$BIN" ]; then
    todo "no binary at $BIN (set LYTE_HOST_BIN or build first) — after building:"
    printf '    sudo setcap cap_sys_admin+ep %s\n' "$BIN"
elif command -v getcap >/dev/null && getcap "$BIN" | grep -q cap_sys_admin; then
    ok "cap_sys_admin present on $BIN"
    todo "remember: re-arm after EVERY rebuild (caps do not survive swift build)"
else
    todo "cap_sys_admin missing — run:"
    printf '    sudo setcap cap_sys_admin+ep %s\n' "$BIN"
fi

# --- portal-era leftover: the direct-scanout opt-out is obsolete -----
CONF="$HOME/.config/environment.d/90-lyte-screencast.conf"
if [ -f "$CONF" ]; then
    todo "portal-era leftover $CONF found — the direct eye does not need it; remove with:"
    printf '    rm %s   # then log out and back in\n' "$CONF"
fi

# --- 2. uinput seat access (E2: the PRIMARY input backend) -----------
RULE="/etc/udev/rules.d/60-lyte-uinput.rules"
if [ -f "$RULE" ]; then
    ok "udev rule present: $RULE"
else
    todo "udev rule missing — WITHOUT IT CLIENT INPUT IS OFF (E2); run:"
    cat <<'EOF'
    sudo tee /etc/udev/rules.d/60-lyte-uinput.rules >/dev/null <<'RULE'
# Lyte: seat-user access to /dev/uinput for the CInputUinput input
# backend — E2 primary (the Mutter RemoteDesktop injector is retired).
# Shape carried over from Sunshine 60-sunshine.rules at its H2-exit
# uninstall (2026-07-22).
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
