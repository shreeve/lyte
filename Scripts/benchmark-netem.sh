#!/usr/bin/env bash
# The impairment SLO gate: shapes one host UDP flow to this client with tc
# netem on pup around one real motion benchmark leg, then judges the result
# against the impairment SLOs (clean-air rungs fail by design under jitter).
#
# Profiles:
#   moderate — delay 20ms jitter 10ms, loss 1%  →  presentation-gap
#              p99 ≤ 50 ms, audio concealment within its bounds, renderer
#              clean, decoded ≥ 30 fps (analyze-app-benchmark.py
#              --netem-profile).
#
# LYTE_BENCHMARK_PORT is both the impaired and the benchmarked port; both
# scripts refuse unless lyte-host.service owns it, and the standing 41151
# also needs LYTE_BENCHMARK_ALLOW_STANDING_PORT=1.
#
# The cleanup trap is armed before the remote apply, so an ssh drop or
# signal still removes the qdisc. The run refuses to start when this
# helper's qdisc is already installed. A signal exits 128+signal.
#
# Environment: LYTE_PUP_HOST (default pup), LYTE_BENCHMARK_HOST (host
# address the client dials), LYTE_BENCHMARK_PORT, LYTE_BENCHMARK_ALLOW_STANDING_PORT,
# LYTE_BENCHMARK_OUT_DIR (evidence root; default .build/benchmarks).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/lib/pup.sh"
PUP="$(lyte_pup_host)"
HOST="${LYTE_BENCHMARK_HOST:-10.0.0.232}"
PROFILE="${1:-moderate}"
HOST_PORT="${LYTE_BENCHMARK_PORT:-}"
NETEM_HELPER="$ROOT/Scripts/netem/port-netem.sh"

case "$PROFILE" in
  moderate) DELAY_MS=20; JITTER_MS=10; LOSS_PCT=1 ;;
  *) echo "usage: LYTE_BENCHMARK_PORT=<port> Scripts/benchmark-netem.sh [moderate]" >&2; exit 2 ;;
esac

[[ "$HOST_PORT" =~ ^[0-9]+$ ]] && (( HOST_PORT >= 1 && HOST_PORT <= 65535 )) || {
  echo "set LYTE_BENCHMARK_PORT to the benchmarked host's UDP port" >&2
  exit 2
}
if [[ "$HOST_PORT" == "41151" && "${LYTE_BENCHMARK_ALLOW_STANDING_PORT:-}" != "1" ]]; then
  echo "refusing standing port 41151 without LYTE_BENCHMARK_ALLOW_STANDING_PORT=1" >&2
  exit 2
fi

# The interface pup reaches the client through (whatever routing says).
CLIENT_IP=$(route -n get "$HOST" 2>/dev/null | awk '/interface/{print $2}' \
  | xargs -I{} ipconfig getifaddr {} 2>/dev/null || true)
[[ "$CLIENT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  echo "cannot resolve the benchmark client's IPv4 address" >&2
  exit 1
}
IFACE=$(pup_ssh \
  "ip -o route get '$CLIENT_IP' | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p'")
[[ "$IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
  echo "cannot resolve pup egress interface" >&2
  exit 1
}
pup_service_owns_port "$HOST_PORT" || {
  echo "refusing: lyte-host.service does not own UDP $HOST_PORT on $PUP;" \
    "impairing it would benchmark clean air" >&2
  exit 1
}

OUT_ROOT="${LYTE_BENCHMARK_OUT_DIR:-$ROOT/.build/benchmarks}"
mkdir -p "$OUT_ROOT"
RUN_DIR=$(mktemp -d \
  "$OUT_ROOT/netem-${PROFILE}-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
echo "netem evidence: $RUN_DIR"
REMOTE_HELPER="/tmp/lyte-port-netem-$$.sh"
NETEM_APPLIED=0
pup_ssh "tc qdisc show dev '$IFACE'" > "$RUN_DIR/qdisc-before.txt"
if grep -q 'qdisc prio 1a7e: root' "$RUN_DIR/qdisc-before.txt"; then
  echo "refusing: a port-netem qdisc is already installed on $PUP/$IFACE" >&2
  exit 1
fi
pup_rsync -a "$NETEM_HELPER" "$PUP:$REMOTE_HELPER"

cleanup() {
  local initial_status="${1:-$?}"
  trap - EXIT INT TERM HUP
  set +e
  cleanup_failed=0
  if (( NETEM_APPLIED )); then
    pup_ssh "sudo -n sh '$REMOTE_HELPER' remove '$IFACE'" \
      > "$RUN_DIR/netem-remove.txt" 2>&1 || cleanup_failed=1
  fi
  pup_ssh "tc qdisc show dev '$IFACE'" \
    > "$RUN_DIR/qdisc-after.txt" 2>&1 || cleanup_failed=1
  if grep -q 'qdisc prio 1a7e: root' "$RUN_DIR/qdisc-after.txt"; then
    echo "netem cleanup FAILED: owned qdisc remains on $PUP/$IFACE" >&2
    cleanup_failed=1
  fi
  pup_ssh "rm -f '$REMOTE_HELPER'" >/dev/null 2>&1 || true
  if (( cleanup_failed )); then
    echo "netem cleanup evidence: $RUN_DIR" >&2
    exit 1
  fi
  exit "$initial_status"
}
trap 'cleanup' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

echo "netem[$PROFILE] on $PUP/$IFACE: udp sport $HOST_PORT to $CLIENT_IP"
# Armed before the apply: from here on the qdisc may exist on pup even if
# this side never hears back.
NETEM_APPLIED=1
pup_ssh \
  "sudo -n sh '$REMOTE_HELPER' apply '$IFACE' '$CLIENT_IP' '$HOST_PORT' \
'$DELAY_MS' '$JITTER_MS' '$LOSS_PCT'" \
  | tee "$RUN_DIR/netem-apply.txt"
pup_ssh "sudo -n sh '$REMOTE_HELPER' status '$IFACE'" \
  > "$RUN_DIR/qdisc-impaired.txt"

LOG="$RUN_DIR/benchmark.log"
# The clean-air gates may fail under deliberate impairment (the leg's own
# clean-air verdict lands in its log; the SLO judgment below is ours), but
# the leg must actually run and name its benchmark JSONL.
LYTE_BENCHMARK_HOST="$HOST" LYTE_BENCHMARK_PORT="$HOST_PORT" \
  LYTE_PUP_HOST="$PUP" "$ROOT/Scripts/benchmark-app.sh" \
  --no-build --out "$RUN_DIR" motion >"$LOG" 2>&1 || true
ARTIFACT="$(sed -n 's/^benchmark JSONL: //p' "$LOG")"
[[ -f "$ARTIFACT" ]] || {
  echo "the impaired benchmark leg named no benchmark JSONL — log tail:" >&2
  tail -15 "$LOG" >&2
  exit 1
}

# The impairment SLOs (analyze-app-benchmark.py NETEM_PROFILES) decide.
python3 "$ROOT/Scripts/analyze-app-benchmark.py" --pretty \
  --netem-profile "$PROFILE" "$ARTIFACT" \
  | tee "$RUN_DIR/netem-verdict.json"
