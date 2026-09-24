#!/usr/bin/env bash
# The impairment SLO gate. Shapes one host UDP flow to this client with tc
# netem on pup around one real motion benchmark leg, then judges the result
# against the IMPAIRMENT SLOs rather than the clean-air gates (under
# deliberate 20 ms jitter the clean transport rung fails by design; the
# contract under impairment is bounded presentation cadence and fully
# concealed audio).
#
# Profiles:
#   moderate — delay 20ms jitter 10ms, loss 1%  →  presentation-gap
#              p99 ≤ 50 ms, audio concealment intact, renderer clean,
#              decoded ≥ 30 fps.
#
# The impaired port and the benchmarked port are one value:
# LYTE_BENCHMARK_PORT is passed to benchmark-app.sh, and both refuse to run
# unless lyte-host.service owns that port. Today the app dials its pinned
# host on the standing port, so the only measurable flow is 41151, which
# additionally needs LYTE_BENCHMARK_ALLOW_STANDING_PORT=1.
#
# Safety: the cleanup trap is armed before the remote apply, so an ssh drop
# or signal after a successful apply still removes the qdisc (removing when
# nothing is installed is a no-op). The run refuses to start when this
# helper's qdisc is already on the interface. A signal exits 128+signal.
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
rsync -a "$NETEM_HELPER" "$PUP:$REMOTE_HELPER"

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

VERDICT_JSON="$RUN_DIR/analyzer-verdict.json"
LOG="$RUN_DIR/benchmark.log"
# The clean-air gates are allowed to fail under deliberate impairment —
# the SLO judgment below is ours — but the leg must actually RUN.
LYTE_BENCHMARK_HOST="$HOST" LYTE_BENCHMARK_PORT="$HOST_PORT" \
  LYTE_PUP_HOST="$PUP" "$ROOT/Scripts/benchmark-app.sh" \
  --no-build --out "$RUN_DIR" motion >"$LOG" 2>&1 || true
shopt -s nullglob
artifacts=()
for candidate in "$RUN_DIR"/motion-*.jsonl; do
  case "$candidate" in
    *-client-handshake.jsonl|*-motion-source.jsonl) continue ;;
    *) artifacts+=("$candidate") ;;
  esac
done
shopt -u nullglob
if (( ${#artifacts[@]} != 1 )); then
  echo "the impaired benchmark leg produced ${#artifacts[@]} artifacts; expected exactly one — log tail:" >&2
  tail -15 "$LOG" >&2
  exit 1
fi
if ! python3 "$ROOT/Scripts/analyze-app-benchmark.py" \
    "${artifacts[0]}" > "$VERDICT_JSON"; then
  echo "clean-air analyzer failed as permitted under impairment; applying netem SLO" \
    >> "$LOG"
fi

python3 - "$VERDICT_JSON" "$PROFILE" <<'PY' \
  | tee "$RUN_DIR/netem-verdict.json"
import json
import sys

verdict = json.load(open(sys.argv[1]))
profile = sys.argv[2]
motion = verdict.get("motion", {})
audio = verdict.get("audio", {})
renderer = verdict.get("renderer", {})
quality = verdict.get("quality", {})
steady = (audio.get("intervalAnalysis", {}) or {}).get("steadyState", {})

failures = []

gap_p99 = motion.get("presentationGapP99Milliseconds")
if gap_p99 is None or gap_p99 > 50:
    failures.append(f"presentation_gap_p99_{gap_p99}ms_over_50ms")

underruns = steady.get("underrunFrames", 0)
protected = steady.get("declickProtectedUnderrunFrames", 0)
if underruns != protected:
    failures.append("audio_underruns_not_fully_declick_protected")

if renderer.get("appFailures", 0) or renderer.get("appleCorruptedFrames", 0):
    failures.append("renderer_failure_or_corruption")

fps = quality.get("decodedProgressFPS", 0)
if fps < 30:
    failures.append(f"decoded_fps_{fps:.1f}_below_30")

result = {
    "type": "lyte_netem_slo_verdict",
    "profile": profile,
    "runID": verdict.get("runID"),
    "verdict": "PASS" if not failures else "FAIL",
    "failures": failures,
    "presentationGapP99Milliseconds": gap_p99,
    "audioSteadyState": {
        "plcInvocations": steady.get("plcInvocations"),
        "underrunFrames": underruns,
        "declickProtected": protected,
    },
    "decodedProgressFPS": fps,
    "cleanAirVerdictForReference": verdict.get("verdict"),
    "cleanAirFailuresForReference": verdict.get("failures"),
}
print(json.dumps(result, indent=2, sort_keys=True))
sys.exit(0 if not failures else 1)
PY
