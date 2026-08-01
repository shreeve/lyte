#!/usr/bin/env bash
# The impairment SLO gate (buttery-smooth program, step 9's live half).
# Shapes the host's egress with tc netem ON PUP around one real
# motion-pipeline benchmark leg, then judges the analyzer verdict
# against the program's IMPAIRMENT SLOs — not the clean-air gates
# (under deliberate 20 ms jitter the clean transport rung fails by
# design; the contract under impairment is bounded presentation cadence
# and fully concealed audio, which is exactly what this asserts).
#
# Profiles (plan SLO #2 is the shipped default):
#   moderate — delay 20ms jitter 10ms, loss 1%  →  presentation-gap
#              p99 ≤ 50 ms, audio concealment intact, renderer clean,
#              decoded ≥ 30 fps.
#
# Safety: the qdisc is removed by an EXIT trap and verified gone; the
# script refuses to start if any qdisc other than the default is
# already installed (never stack shaping on a stranger's experiment).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUP="${LYTE_BENCHMARK_PUP:-pup}"
HOST="${LYTE_BENCHMARK_HOST:-10.0.0.232}"
PROFILE="${1:-moderate}"

case "$PROFILE" in
  moderate) NETEM="delay 20ms 10ms loss 1%" ;;
  *) echo "usage: Scripts/benchmark-netem.sh [moderate]" >&2; exit 2 ;;
esac

# The interface pup reaches the client through (the wired leg today;
# resolves whatever routing says tomorrow).
CLIENT_IP=$(route -n get "$HOST" 2>/dev/null | awk '/interface/{print $2}' \
  | xargs -I{} ipconfig getifaddr {} 2>/dev/null || true)
IFACE=$(ssh "$PUP" "ip -o route get ${CLIENT_IP:-10.0.0.1} | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p'")
[ -n "$IFACE" ] || { echo "cannot resolve pup egress interface" >&2; exit 1; }

EXISTING=$(ssh "$PUP" "tc qdisc show dev $IFACE" | head -1)
case "$EXISTING" in
  *netem*|*htb*|*tbf*)
    echo "refusing: $IFACE already shaped: $EXISTING" >&2; exit 1 ;;
esac

cleanup() {
  ssh "$PUP" "sudo -n tc qdisc del dev $IFACE root 2>/dev/null" || true
  LEFT=$(ssh "$PUP" "tc qdisc show dev $IFACE" | head -1 || true)
  case "$LEFT" in
    *netem*) echo "WARNING: netem still installed on $IFACE — remove by hand:" >&2
             echo "  ssh $PUP sudo tc qdisc del dev $IFACE root" >&2 ;;
  esac
}
trap cleanup EXIT

echo "netem[$PROFILE] on $PUP/$IFACE: $NETEM"
ssh "$PUP" "sudo -n tc qdisc add dev $IFACE root netem $NETEM"

VERDICT_JSON=$(mktemp)
BEFORE=$(ls -t "$ROOT/.build/benchmarks/" \
  | grep -E '^motion-pipeline.*[0-9]\.jsonl$' | head -1 || true)
LOG=$(mktemp)
# The clean-air gates are allowed to fail under deliberate impairment —
# the SLO judgment below is ours — but the leg must actually RUN.
LYTE_BENCHMARK_HOST="$HOST" "$ROOT/Scripts/benchmark-app.sh" \
  --no-build motion-pipeline >"$LOG" 2>&1 || true
LATEST=$(ls -t "$ROOT/.build/benchmarks/" \
  | grep -E '^motion-pipeline.*[0-9]\.jsonl$' | head -1)
if [ -z "$LATEST" ] || [ "$LATEST" = "$BEFORE" ]; then
  echo "the impaired benchmark leg produced no new artifact — log tail:" >&2
  tail -15 "$LOG" >&2
  exit 1
fi
python3 "$ROOT/Scripts/analyze-app-benchmark.py" \
  "$ROOT/.build/benchmarks/$LATEST" > "$VERDICT_JSON"

python3 - "$VERDICT_JSON" "$PROFILE" <<'PY'
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
