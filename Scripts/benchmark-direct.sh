#!/usr/bin/env bash
# The direct-eye live leg (direct-eye plan E1, the owner-sanctioned
# half): borrow port 41151 from the standing pup host — exactly the
# synthetic rig's takeover choreography, identity-checksum guard
# included — but stand a DIRECT-backend host there (real KMS capture,
# hevc_vaapi, setcap privileges, full user-session environment for
# audio/input/clipboard), then run the REAL-capture motion benchmark
# against it and restore the owner's loop no matter what.
#
# Usage: Scripts/benchmark-direct.sh [seconds]   (default 30; the
#        30-minute soak is `Scripts/benchmark-direct.sh 1800`)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUP="${PUP:-pup}"
SECONDS_ARG="${1:-30}"
[[ "$SECONDS_ARG" =~ ^[0-9]+$ ]] && (( SECONDS_ARG >= 5 && SECONDS_ARG <= 3600 )) \
  || { echo "seconds must be 5..3600" >&2; exit 2; }
HOST_LOG_REMOTE="/tmp/lyte-direct-leg-$$.log"

standing="$(ssh -o ConnectTimeout=10 "$PUP" \
  "pgrep -o -f 'lyte-host.*--wire-listen 41151' || true")"
[[ "$standing" =~ ^[0-9]+$ ]] || {
  echo "refusing: no standing pup host on 41151" >&2; exit 1; }
SUPERVISOR="$(ssh -o ConnectTimeout=10 "$PUP" \
  "pgrep -o -f '[b]ash /home/shreeve/lyte-loop.sh' || true")"
[[ "$SUPERVISOR" =~ ^[0-9]+$ ]] || {
  echo "refusing: lyte-loop supervisor not found" >&2; exit 1; }
identity_before="$(ssh "$PUP" \
  "sha256sum ~/.config/lyte-host/noise_static.key \
~/.config/lyte-host/paired_clients | sha256sum")"

caps="$(ssh "$PUP" "getcap ~/src/lyte-host/.build/debug/lyte-host")"
[[ "$caps" == *cap_sys_admin* ]] || {
  echo "refusing: pup's lyte-host lacks cap_sys_admin (run: ssh $PUP" \
       "sudo setcap cap_sys_admin+ep '~/src/lyte-host/.build/debug/lyte-host')" >&2
  exit 1
}

DIRECT_PID=""
cleanup() {
  [[ -z "$DIRECT_PID" ]] || \
    ssh -o ConnectTimeout=10 "$PUP" "kill -9 '$DIRECT_PID' 2>/dev/null" || true
  ssh -o ConnectTimeout=10 "$PUP" "kill -CONT '$SUPERVISOR'" || {
    echo "WARNING: could not resume supervisor $SUPERVISOR — fix by hand:" >&2
    echo "  ssh $PUP kill -CONT $SUPERVISOR" >&2
  }
}
trap cleanup EXIT

echo "takeover: pausing supervisor $SUPERVISOR, replacing host $standing"
ssh "$PUP" "kill -STOP '$SUPERVISOR'; kill -9 '$standing'"
DIRECT_PID="$(ssh "$PUP" \
  "cd ~/src/lyte-host && \
XDG_RUNTIME_DIR=/run/user/1000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
WAYLAND_DISPLAY=wayland-0 \
nohup .build/debug/lyte-host --backend direct \
--wire-listen 41151 --wire-rate-mbps 50 \
--seconds '$((SECONDS_ARG + 120))' \
>'$HOST_LOG_REMOTE' 2>&1 & echo \$!")"
[[ "$DIRECT_PID" =~ ^[0-9]+$ ]] || { echo "direct host failed to start" >&2; exit 1; }
sleep 2
ssh "$PUP" "kill -0 '$DIRECT_PID'" || {
  echo "direct host exited at startup — log:" >&2
  ssh "$PUP" "tail -20 '$HOST_LOG_REMOTE'" >&2
  exit 1
}
identity_after="$(ssh "$PUP" \
  "sha256sum ~/.config/lyte-host/noise_static.key \
~/.config/lyte-host/paired_clients | sha256sum")"
[[ "$identity_before" == "$identity_after" ]] || {
  echo "direct host startup changed protected identity files" >&2; exit 1; }
echo "takeover: direct host PID $DIRECT_PID on 41151 (log $HOST_LOG_REMOTE)"

rc=0
LYTE_BENCHMARK_SECONDS="$SECONDS_ARG" \
  "$ROOT/Scripts/benchmark-app.sh" --no-build motion || rc=$?

echo "--- direct host log tail ---"
ssh "$PUP" "tail -15 '$HOST_LOG_REMOTE'" || true
exit "$rc"
