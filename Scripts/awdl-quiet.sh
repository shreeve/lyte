#!/bin/sh
# Hold AWDL down while streaming — the MANUAL FALLBACK. The shipped path
# is lyte-helperd (SMAppService privileged daemon) + the app's radio
# watchdog, which hold awdl0 down per-stream automatically; use this only
# on a build without the helper, or when its approval is pending.
#
# AWDL (Apple Wireless Direct Link, interface awdl0) time-slices the Wi-Fi
# radio for AirDrop/Handoff/Sidecar/Continuity scanning. Each scan hop takes
# the radio off-channel for tens of milliseconds — no packet loss, just
# bursts of delay, which drain the audio buffer and chop playback (the
# signature is underruns with near-zero packet loss). macOS re-raises the
# interface on its own whenever those services stir, so a one-shot
# `ifconfig awdl0 down` doesn't stick; this loop re-downs it every second
# until you Ctrl-C, then restores it.
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
trap 'ifconfig awdl0 up 2>/dev/null; echo; echo "awdl0 restored"; exit 0' INT TERM
echo "holding awdl0 down (AirDrop/Handoff paused) — Ctrl-C to restore"
while :; do
    ifconfig awdl0 down 2>/dev/null
    sleep 1
done
