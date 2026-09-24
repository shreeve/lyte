#!/usr/bin/env bash
# setup-host.sh — one-shot, idempotent machine prerequisites for a new
# lyte-host box (GNOME/Mutter Wayland). Run as the seat user; re-run
# any time — it only reports or repairs, never duplicates.
#
# What a fresh machine needs beyond the binary:
#
#  1. CAP_SYS_ADMIN — the direct eye's DRM ticket (GETFB2 + dmabuf
#     export of the scanout). lyte-host.service (install-host.sh) grants
#     it as an AMBIENT capability, so the deployed binary never needs a
#     file capability. Only a hand-run host (a probe, a test port) needs
#     `sudo setcap cap_sys_admin+ep BINARY`, and a rebuild drops it.
#
#  2. /dev/uinput seat access for the CInputUinput input backend —
#     without this rule client input is OFF. Needs root, so this script
#     prints the exact sudo command instead of escalating itself.
#
#  3. An rtprio rlimit lets the latency-owning audio and wire-drain
#     threads obtain SCHED_RR. Optional: the binary degrades safely,
#     and this script only checks/prints the prerequisite.
#
# (The direct eye reads the scanout itself, so Mutter may promote
# fullscreen surfaces freely: a lingering
# ~/.config/environment.d/90-lyte-screencast.conf is obsolete and this
# script offers its removal.)
set -euo pipefail

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
todo() { printf '  \033[33m→\033[0m %s\n' "$1"; }

echo "lyte-host machine setup"

# --- 1. The service and its CAP_SYS_ADMIN (the direct eye's DRM ticket)
UNIT=/etc/systemd/system/lyte-host.service
BIN="$HOME/.local/bin/lyte-host"
if [ -f "$UNIT" ] && grep -q '^AmbientCapabilities=CAP_SYS_ADMIN' "$UNIT"; then
    ok "lyte-host.service grants CAP_SYS_ADMIN (ambient) — no setcap needed"
else
    todo "lyte-host.service not installed — build release, then run:"
    printf '    Host/Scripts/install-host.sh\n'
fi
if [ -L "$BIN" ]; then
    ok "deployed binary: $BIN -> $(readlink "$BIN")"
else
    todo "no deployed binary at $BIN — after a release build run:"
    printf '    Host/Scripts/deploy-host.sh\n'
fi

# --- portal-era leftover: the direct-scanout opt-out is obsolete -----
CONF="$HOME/.config/environment.d/90-lyte-screencast.conf"
if [ -f "$CONF" ]; then
    todo "portal-era leftover $CONF found — the direct eye does not need it; remove with:"
    printf '    rm %s   # then log out and back in\n' "$CONF"
fi

# --- pre-XDG leftovers: the layout before ~/.config/lyte --------------
for OLD in /etc/lyte/lyte-host.conf /usr/local/bin/lyte-host /tmp/lyte-host-session.log; do
    if [ -e "$OLD" ]; then
        todo "pre-XDG leftover $OLD is unused by the current unit; once migrated:"
        printf '    sudo rm %s\n' "$OLD"
    fi
done
if [ -d "$HOME/.config/lyte-host" ]; then
    ok "pre-XDG identity $HOME/.config/lyte-host kept read-only (lyte-host copies from it, never writes it)"
fi

# --- 2. uinput seat access (the input backend) ----------------------
RULE="/etc/udev/rules.d/60-lyte-uinput.rules"
if [ -f "$RULE" ]; then
    ok "udev rule present: $RULE"
else
    todo "udev rule missing — WITHOUT IT CLIENT INPUT IS OFF; run:"
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
