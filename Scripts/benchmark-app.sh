#!/usr/bin/env bash
# Repeatable real Lyte.app glass-path benchmark against the standing pup host.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Lyte.app"
ANALYZER="$ROOT/Scripts/analyze-app-benchmark.py"
PUP="${PUP:-pup}"
HOST="${LYTE_BENCHMARK_HOST:-10.0.0.249}"
BENCH_SECONDS="${LYTE_BENCHMARK_SECONDS:-30}"
OUT_DIR="${LYTE_BENCHMARK_OUT_DIR:-$ROOT/.build/benchmarks}"
SYNTHETIC_BITRATE_MBPS="${LYTE_BENCHMARK_SYNTHETIC_BITRATE_MBPS:-50}"
SYNTHETIC_ENCODER_BITRATE_MBPS="${LYTE_BENCHMARK_SYNTHETIC_ENCODER_BITRATE_MBPS:-$SYNTHETIC_BITRATE_MBPS}"
SYNTHETIC_WIRE_RATE_MBPS="${LYTE_BENCHMARK_SYNTHETIC_WIRE_RATE_MBPS:-$SYNTHETIC_BITRATE_MBPS}"
MOTION_CHROMA_TIER="${LYTE_BENCHMARK_MOTION_CHROMA_TIER:-best}"
QUALITY_PROBE="${LYTE_BENCHMARK_QUALITY_PROBE:-1}"
QUALITY_EXPECTED_WIDTH="${LYTE_BENCHMARK_QUALITY_WIDTH:-}"
QUALITY_EXPECTED_HEIGHT="${LYTE_BENCHMARK_QUALITY_HEIGHT:-}"
QUALITY_WIDTH=""
QUALITY_HEIGHT=""
SOURCE_WITNESS_R_DB=""
SOURCE_WITNESS_G_DB=""
SOURCE_WITNESS_B_DB=""
SOURCE_WITNESS_MIN_DB=""
SOURCE_WITNESS_SSIM=""
SOURCE_WITNESS_SHA256=""
MOTION_PRESENTER_SHA256=""
MOTION_DEFINITION_SHA256=""
MOTION_SOURCE_LOG=""
REMOTE_MOTION_PRESENTER=""
REMOTE_MOTION_DEFINITION=""
REMOTE_MOTION_LOG=""
SYNTHETIC_HOST_PID=""
SYNTHETIC_TRACE_REMOTE=""
SYNTHETIC_HOST_LOG_REMOTE=""
HOST_SUPERVISOR_PID=""
NO_BUILD=0
APP_SHA256=""
HOST_SHA256=""
CLIENT_SOURCE_SHA256=""
HOST_SOURCE_SHA256=""
APP_BUILD_UTC=""

usage() {
  echo "usage: Scripts/benchmark-app.sh [--no-build] [--seconds N] [--out DIR] static|motion|motion-pipeline|handshake-only|quality|all"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) NO_BUILD=1; shift ;;
    --seconds) BENCH_SECONDS="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    static|motion|motion-pipeline|handshake-only|quality|all) MODE="$1"; shift ;;
    *) usage; exit 2 ;;
  esac
done
MODE="${MODE:-}"
[[ "$MODE" =~ ^(static|motion|motion-pipeline|handshake-only|quality|all)$ ]] || { usage; exit 2; }
minimum_seconds=5
[[ "$MODE" != handshake-only ]] || minimum_seconds=1
[[ "$BENCH_SECONDS" =~ ^[0-9]+$ ]] \
  && (( BENCH_SECONDS >= minimum_seconds && BENCH_SECONDS <= 3600 )) \
  || { echo "seconds must be an integer in ${minimum_seconds}...3600" >&2; exit 2; }
[[ "$SYNTHETIC_BITRATE_MBPS" =~ ^[0-9]+$ ]] \
  && (( SYNTHETIC_BITRATE_MBPS >= 5 && SYNTHETIC_BITRATE_MBPS <= 100 )) \
  || { echo "synthetic bitrate must be an integer in 5...100 Mbps" >&2; exit 2; }
[[ "$SYNTHETIC_ENCODER_BITRATE_MBPS" =~ ^[0-9]+$ ]] \
  && (( SYNTHETIC_ENCODER_BITRATE_MBPS >= 5
        && SYNTHETIC_ENCODER_BITRATE_MBPS <= 100 )) \
  || { echo "synthetic encoder bitrate must be an integer in 5...100 Mbps" >&2; exit 2; }
[[ "$SYNTHETIC_WIRE_RATE_MBPS" =~ ^[0-9]+$ ]] \
  && (( SYNTHETIC_WIRE_RATE_MBPS >= 5
        && SYNTHETIC_WIRE_RATE_MBPS <= 100 )) \
  || { echo "synthetic wire rate must be an integer in 5...100 Mbps" >&2; exit 2; }
[[ "$MOTION_CHROMA_TIER" =~ ^(good|best)$ ]] \
  || { echo "motion chroma tier must be good or best" >&2; exit 2; }
[[ "$QUALITY_PROBE" =~ ^[01]$ ]] \
  || { echo "quality probe must be 0 or 1" >&2; exit 2; }
if [[ -n "$QUALITY_EXPECTED_WIDTH" || -n "$QUALITY_EXPECTED_HEIGHT" ]]; then
  [[ "$QUALITY_EXPECTED_WIDTH" =~ ^[0-9]+$ \
      && "$QUALITY_EXPECTED_HEIGHT" =~ ^[0-9]+$ ]] \
    || { echo "quality dimension override requires integer width and height" >&2; exit 2; }
fi

mkdir -p "$OUT_DIR"
if (( ! NO_BUILD )); then
  "$ROOT/Scripts/make-app.sh" release
fi
[[ -x "$APP/Contents/MacOS/Lyte" ]] || {
  echo "missing signed app: run Scripts/make-app.sh release" >&2
  exit 1
}
codesign --verify --strict "$APP"

source_fingerprint() {
  (
    cd "$ROOT"
    git ls-files --cached --others --exclude-standard -- "$@" \
      | LC_ALL=C sort \
      | while IFS= read -r path; do
          if [[ -f "$path" ]]; then
            shasum -a 256 "$path"
          fi
        done
  ) | shasum -a 256 | awk '{print $1}'
}

CLIENT_SOURCE_SHA256="$(source_fingerprint Package.swift Sources)"
recorded_client_source="$APP/Contents/Resources/client-source.sha256"
[[ -s "$recorded_client_source" ]] || {
  echo "benchmark refused: Lyte.app has no signed source provenance" >&2
  echo "rebuild it with Scripts/make-app.sh release" >&2
  exit 1
}
read -r bundled_client_source < "$recorded_client_source"
[[ "$CLIENT_SOURCE_SHA256" == "$bundled_client_source" ]] || {
  echo "benchmark refused: Lyte.app was built from different client source" >&2
  echo "rebuild it with Scripts/make-app.sh release" >&2
  exit 1
}
read -r APP_BUILD_UTC < "$APP/Contents/Resources/build-utc.txt" || {
  echo "benchmark refused: Lyte.app has no signed build timestamp" >&2
  exit 1
}

if (( NO_BUILD )); then
  stale_client_source="$(
    cd "$ROOT"
    git ls-files --cached --others --exclude-standard -- Sources Package.swift \
      | while IFS= read -r path; do
          if [[ -f "$path" && "$path" -nt "$APP/Contents/MacOS/Lyte" ]]; then
            printf '%s\n' "$path"
          fi
        done
  )"
  [[ -z "$stale_client_source" ]] || {
    echo "--no-build refused: client source is newer than Lyte.app:" >&2
    printf '%s\n' "$stale_client_source" >&2
    exit 1
  }
fi

# A benchmark is evidence only when the source under review is exactly what
# pup built. Dry-run checksums catch the otherwise-silent "edit B, run A"
# failure even when mtimes happen to agree.
deployed_delta="$(
  rsync -ani --checksum --no-times --omit-dir-times --delete \
    "$ROOT/Host/Package.swift" \
    "$PUP:src/lyte-host/Package.swift"
  rsync -ani --checksum --no-times --omit-dir-times --delete \
    --exclude .build "$ROOT/Host/Sources/" \
    "$PUP:src/lyte-host/Sources/"
  rsync -ani --checksum --no-times --omit-dir-times --delete \
    "$ROOT/Wire/Package.swift" \
    "$PUP:src/Wire/Package.swift"
  rsync -ani --checksum --no-times --omit-dir-times --delete \
    --exclude .build "$ROOT/Wire/Sources/" \
    "$PUP:src/Wire/Sources/"
)"
[[ -z "$deployed_delta" ]] || {
  echo "benchmark refused: local Host/Wire source differs from pup:" >&2
  printf '%s\n' "$deployed_delta" >&2
  exit 1
}

stale_host_source="$(
  ssh -o ConnectTimeout=10 "$PUP" \
    "python3 -c 'import os
b = os.path.expanduser(\"~/src/lyte-host/.build/debug/lyte-host\")
bm = os.path.getmtime(b)
roots = [
    (os.path.expanduser(\"~/src/lyte-host\"), \"Host\"),
    (os.path.expanduser(\"~/src/Wire\"), \"Wire\"),
]
for root, label in roots:
    paths = [os.path.join(root, \"Package.swift\")]
    for directory, _, files in os.walk(os.path.join(root, \"Sources\")):
        paths.extend(os.path.join(directory, name) for name in files)
    for path in paths:
        if os.path.isfile(path) and os.path.getmtime(path) > bm:
            print(label + \"/\" + os.path.relpath(path, root))'"
)"
[[ -z "$stale_host_source" ]] || {
  echo "benchmark refused: pup Host binary predates deployed source:" >&2
  printf '%s\n' "$stale_host_source" >&2
  exit 1
}

HOST_PID="$(
  ssh -o ConnectTimeout=10 "$PUP" \
    "pgrep -o -f 'lyte-host.*--wire-listen 41151' || true"
)"
[[ "$HOST_PID" =~ ^[0-9]+$ ]] || {
  echo "benchmark refused: no standing pup Host on port 41151" >&2
  exit 1
}
# A capability-tagged host (the direct eye's cap_sys_admin) is
# ptrace-guarded: /proc/PID/exe refuses same-uid readers no matter the
# dumpable flag. sudo -n keeps the witness identical, just readable.
host_hashes="$(
  ssh -o ConnectTimeout=10 "$PUP" \
    "{ sha256sum /proc/$HOST_PID/exe 2>/dev/null \
       || sudo -n sha256sum /proc/$HOST_PID/exe; } \
       | head -1; \
     sha256sum ~/src/lyte-host/.build/debug/lyte-host"
)"
host_hashes="$(printf '%s\n' "$host_hashes" | awk '{print $1}')"
running_host_sha="$(printf '%s\n' "$host_hashes" | awk 'NR == 1 {print}')"
disk_host_sha="$(printf '%s\n' "$host_hashes" | awk 'NR == 2 {print}')"
[[ "$running_host_sha" == "$disk_host_sha" ]] || {
  echo "benchmark refused: running pup Host is not the built binary" >&2
  exit 1
}

APP_SHA256="$(shasum -a 256 "$APP/Contents/MacOS/Lyte" | awk '{print $1}')"
HOST_SHA256="$running_host_sha"
HOST_SOURCE_SHA256="$(source_fingerprint Host)"

FFPLAY_PID=""
REMOTE_QUALITY_IMAGE=""
REMOTE_QUALITY_PRESENTER=""
REMOTE_QUALITY_WORK=""
APP_PID=""
FALLBACK_APP_PID=""
OPEN_PID=""
HANDSHAKE_RUN_ID=""
HANDSHAKE_LOCAL_TCPDUMP_PID=""
HANDSHAKE_REMOTE_TCPDUMP_PID=""
HANDSHAKE_REMOTE_WITNESS=""

start_handshake_evidence() {
  local run_id="$1"
  HANDSHAKE_RUN_ID="$run_id"
  HANDSHAKE_REMOTE_WITNESS="/tmp/$run_id-host-handshake.jsonl"
  route -n get "$HOST" > "$OUT_DIR/$run_id-client-route.txt"
  netstat -s -p udp > "$OUT_DIR/$run_id-client-udp-before.txt"
  sudo -n tcpdump -i en0 -nn -U \
    -w "$OUT_DIR/$run_id-client.pcap" "udp port 41151" \
    >"$OUT_DIR/$run_id-client-tcpdump.stderr" 2>&1 &
  HANDSHAKE_LOCAL_TCPDUMP_PID=$!
  HANDSHAKE_REMOTE_TCPDUMP_PID="$(ssh "$PUP" \
    "rm -f '/tmp/$run_id-host.pcap' '$HANDSHAKE_REMOTE_WITNESS'; \
sudo -n nohup tcpdump -i any -nn -U -w '/tmp/$run_id-host.pcap' \
'udp port 41151' >'/tmp/$run_id-host-tcpdump.stderr' 2>&1 & echo \$!")"
  ssh "$PUP" "date -u +%FT%TZ; \
p=\$(pgrep -o -f '[l]yte-host.*--wire-listen 41151'); \
ps -o pid,lstart,args -p \"\$p\"; \
{ sha256sum /proc/\$p/exe 2>/dev/null || sudo -n sha256sum /proc/\$p/exe; }; \
sha256sum ~/src/lyte-host/.build/debug/lyte-host; \
ss -u -a -n -p; ip -s link show" \
    > "$OUT_DIR/$run_id-host-before.txt"
}

collect_handshake_evidence() {
  local run_id="$HANDSHAKE_RUN_ID"
  [[ -n "$run_id" ]] || return 0
  [[ -z "$HANDSHAKE_LOCAL_TCPDUMP_PID" ]] \
    || kill "$HANDSHAKE_LOCAL_TCPDUMP_PID" 2>/dev/null || true
  [[ -z "$HANDSHAKE_REMOTE_TCPDUMP_PID" ]] \
    || ssh "$PUP" \
      "kill '$HANDSHAKE_REMOTE_TCPDUMP_PID' 2>/dev/null || true" || true
  sleep 1
  netstat -s -p udp > "$OUT_DIR/$run_id-client-udp-after.txt"
  sudo -n tcpdump -nn -tttt -vv \
    -r "$OUT_DIR/$run_id-client.pcap" "udp port 41151" \
    > "$OUT_DIR/$run_id-client-packets.txt" 2>/dev/null || true
  rsync -a "$PUP:/tmp/$run_id-host.pcap" \
    "$OUT_DIR/$run_id-host.pcap" 2>/dev/null || true
  rsync -a "$PUP:$HANDSHAKE_REMOTE_WITNESS" \
    "$OUT_DIR/$run_id-host-handshake.jsonl" 2>/dev/null || true
  rsync -a "$PUP:/tmp/$run_id-host-tcpdump.stderr" \
    "$OUT_DIR/$run_id-host-tcpdump.stderr" 2>/dev/null || true
  if [[ -n "$SYNTHETIC_HOST_LOG_REMOTE" ]]; then
    rsync -a "$PUP:$SYNTHETIC_HOST_LOG_REMOTE" \
      "$OUT_DIR/$run_id-host.log" 2>/dev/null || true
  fi
  if [[ -n "$SYNTHETIC_TRACE_REMOTE" ]]; then
    rsync -a "$PUP:$SYNTHETIC_TRACE_REMOTE" \
      "$OUT_DIR/$run_id-host-trace.jsonl" 2>/dev/null || true
  fi
  tcpdump -nn -tttt -vv -r "$OUT_DIR/$run_id-host.pcap" \
    "udp port 41151" > "$OUT_DIR/$run_id-host-packets.txt" \
    2>/dev/null || true
  ssh "$PUP" "date -u +%FT%TZ; \
p=\$(pgrep -o -f '[l]yte-host.*--wire-listen 41151' || true); \
if test -n \"\$p\"; then ps -o pid,lstart,args -p \"\$p\"; \
{ sha256sum /proc/\$p/exe 2>/dev/null || sudo -n sha256sum /proc/\$p/exe; }; fi; \
ss -u -a -n -p; ip -s link show" \
    > "$OUT_DIR/$run_id-host-after.txt" || true
  shasum -a 256 "$OUT_DIR/$run_id"* \
    > "$OUT_DIR/$run_id-handshake-artifacts.sha256" 2>/dev/null || true
  HANDSHAKE_RUN_ID=""
  HANDSHAKE_LOCAL_TCPDUMP_PID=""
  HANDSHAKE_REMOTE_TCPDUMP_PID=""
  HANDSHAKE_REMOTE_WITNESS=""
}

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$FALLBACK_APP_PID" ]] \
      && kill -0 "$FALLBACK_APP_PID" 2>/dev/null; then
    kill "$FALLBACK_APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$OPEN_PID" ]] && kill -0 "$OPEN_PID" 2>/dev/null; then
    kill "$OPEN_PID" 2>/dev/null || true
  fi
  collect_handshake_evidence
  if [[ -n "$FFPLAY_PID" ]]; then
    ssh -o ConnectTimeout=10 "$PUP" "kill $FFPLAY_PID 2>/dev/null" || true
  fi
  if [[ -n "$REMOTE_QUALITY_IMAGE" ]]; then
    ssh -o ConnectTimeout=10 "$PUP" \
      "rm -f '$REMOTE_QUALITY_IMAGE' '$REMOTE_QUALITY_PRESENTER' \
'$REMOTE_QUALITY_PRESENTER.log' '$REMOTE_QUALITY_WORK.raw' \
'$REMOTE_QUALITY_WORK.hevc' '$REMOTE_QUALITY_WORK.log'" || true
  fi
  if [[ -n "$REMOTE_MOTION_PRESENTER" ]]; then
    ssh -o ConnectTimeout=10 "$PUP" \
      "rm -f '$REMOTE_MOTION_PRESENTER' '$REMOTE_MOTION_DEFINITION' \
'$REMOTE_MOTION_LOG' '$REMOTE_MOTION_LOG.stderr'" || true
  fi
  if [[ -n "$SYNTHETIC_HOST_PID" ]]; then
    ssh -o ConnectTimeout=10 "$PUP" \
      "kill -9 '$SYNTHETIC_HOST_PID' 2>/dev/null || true; \
kill -CONT '$HOST_SUPERVISOR_PID' 2>/dev/null || true" || true
    SYNTHETIC_HOST_PID=""
  fi
  if [[ -n "$HOST_SUPERVISOR_PID" ]]; then
    ssh -o ConnectTimeout=10 "$PUP" \
      "kill -CONT '$HOST_SUPERVISOR_PID' 2>/dev/null || true" || true
    HOST_SUPERVISOR_PID=""
  fi
}
trap cleanup EXIT INT TERM

start_motion() {
  local run_id="$1"
  local monitor_state discovered refresh scale summary
  local presenter="$ROOT/Scripts/motion-presenter.py"
  local definition="$ROOT/Scripts/motion-definition.json"
  monitor_state="$(ssh -o ConnectTimeout=10 "$PUP" \
    'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
--object-path /org/gnome/Mutter/DisplayConfig \
--method org.gnome.Mutter.DisplayConfig.GetCurrentState')"
  discovered="$(printf '%s' "$monitor_state" | python3 -c '
import re, sys
state = sys.stdin.read()
mode = re.search(
    r"\('\''[^'\'']+'\'', ([0-9]+), ([0-9]+), ([0-9.]+), ([0-9.]+), "
    r"[^{}]*\{'\''is-current'\'': <true>",
    state,
)
logical = re.search(
    r"\[\(([0-9-]+), ([0-9-]+), ([0-9.]+), uint32 [0-9]+, true,",
    state,
)
if not mode or not logical:
    raise SystemExit("no current physical/logical monitor state")
print(mode.group(1), mode.group(2), mode.group(3), logical.group(3))
')"
  read -r QUALITY_WIDTH QUALITY_HEIGHT refresh scale <<< "$discovered"
  ssh -o ConnectTimeout=10 "$PUP" \
    'python3 -c '"'"'import gi, numpy
gi.require_version("Gdk", "4.0")
gi.require_version("Graphene", "1.0")
gi.require_version("Gtk", "4.0")
'"'"' && test -S /run/user/1000/wayland-0'
  MOTION_PRESENTER_SHA256="$(shasum -a 256 "$presenter" | awk '{print $1}')"
  MOTION_DEFINITION_SHA256="$(shasum -a 256 "$definition" | awk '{print $1}')"
  REMOTE_MOTION_PRESENTER="/tmp/lyte-benchmark-$run_id-motion.py"
  REMOTE_MOTION_DEFINITION="/tmp/lyte-benchmark-$run_id-motion.json"
  REMOTE_MOTION_LOG="/tmp/lyte-benchmark-$run_id-motion-source.jsonl"
  MOTION_SOURCE_LOG="$OUT_DIR/$run_id-motion-source.jsonl"
  rsync -a "$presenter" "$PUP:$REMOTE_MOTION_PRESENTER"
  rsync -a "$definition" "$PUP:$REMOTE_MOTION_DEFINITION"
  remote_hashes="$(ssh -o ConnectTimeout=10 "$PUP" \
    "sha256sum '$REMOTE_MOTION_PRESENTER' '$REMOTE_MOTION_DEFINITION' \
| awk '{print \$1}'")"
  [[ "$(printf '%s\n' "$remote_hashes" | awk 'NR == 1 {print}')" \
      == "$MOTION_PRESENTER_SHA256" \
      && "$(printf '%s\n' "$remote_hashes" | awk 'NR == 2 {print}')" \
      == "$MOTION_DEFINITION_SHA256" ]] || {
    echo "motion presenter provenance mismatch after upload" >&2
    exit 1
  }
  FFPLAY_PID="$(ssh -o ConnectTimeout=10 "$PUP" \
    "XDG_RUNTIME_DIR=/run/user/1000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
WAYLAND_DISPLAY=wayland-0 nohup python3 '$REMOTE_MOTION_PRESENTER' \
--definition '$REMOTE_MOTION_DEFINITION' \
--width '$QUALITY_WIDTH' --height '$QUALITY_HEIGHT' --refresh '$refresh' \
--log '$REMOTE_MOTION_LOG' >'$REMOTE_MOTION_LOG.stderr' 2>&1 & echo \$!")"
  [[ "$FFPLAY_PID" =~ ^[0-9]+$ ]] || {
    echo "failed to obtain pup ffplay PID" >&2
    exit 1
  }
  sleep 5
  ssh "$PUP" "kill -0 $FFPLAY_PID" || {
    echo "pup motion workload failed to stay alive" >&2
    exit 1
  }
  rsync -a "$PUP:$REMOTE_MOTION_LOG" "$MOTION_SOURCE_LOG"
  summary="$OUT_DIR/$run_id-motion-source-preflight.json"
  source_pass=1
  python3 - "$MOTION_SOURCE_LOG" "$summary" \
      "$QUALITY_WIDTH" "$QUALITY_HEIGHT" "$scale" <<'PY' || source_pass=0
import json, math, sys
from pathlib import Path

source, destination, width, height, scale = sys.argv[1:]
events = [json.loads(line) for line in Path(source).read_text().splitlines()]
rows = [row for row in events if row.get("event") == "sourceTick"][-180:]
if len(rows) < 120:
    raise SystemExit("motion source produced fewer than 120 warm samples")
actual_by_frame = {}
for row in events:
    if row.get("event") == "presentation" \
            and row.get("actualPresentationMicroseconds", 0) > 0:
        actual_by_frame.setdefault(
            row["frameID"], row["actualPresentationMicroseconds"])
presented = [
    (row["frameID"], actual_by_frame[row["frameID"]])
    for row in rows if row["frameID"] in actual_by_frame
]

def percentile(values, rank):
    values = sorted(values)
    return values[max(0, math.ceil(rank / 100 * len(values)) - 1)]

gaps = [
    (right[1] - left[1]) / 1000
    for left, right in zip(presented, presented[1:])
]
if not gaps:
    gaps = [1_000_000_000]
period_us = 1_000_000 / 60
origin_id, origin_us = presented[0] if presented else (0, 0)
drift = [
    abs(presentation - origin_us - (frame_id - origin_id) * period_us) / 1000
    for frame_id, presentation in presented
]
if not drift:
    drift = [1_000_000_000]
scale = float(scale)
dimensions_exact = all(
    row["textureWidth"] == int(width)
    and row["textureHeight"] == int(height)
    and abs(row["allocationWidthPoints"] * scale - int(width)) <= 1
    and abs(row["allocationHeightPoints"] * scale - int(height)) <= 1
    for row in rows
)
result = {
    "samples": len(rows),
    "actualPresentations": len(presented),
    "width": int(width),
    "height": int(height),
    "logicalScale": scale,
    "allocationWidthPoints": rows[-1]["allocationWidthPoints"],
    "allocationHeightPoints": rows[-1]["allocationHeightPoints"],
    "dimensionsExact": dimensions_exact,
    "gapP50Milliseconds": percentile(gaps, 50),
    "gapP95Milliseconds": percentile(gaps, 95),
    "gapP99Milliseconds": percentile(gaps, 99),
    "phaseDriftP99Milliseconds": percentile(drift, 99),
    "skippedSourceFrames": sum(row["skippedSourceFrames"] for row in rows),
}
result["pass"] = (
    dimensions_exact
    and len(presented) >= 120
    and result["skippedSourceFrames"] == 0
    and result["gapP99Milliseconds"] <= 25
    and result["phaseDriftP99Milliseconds"] <= 8
)
Path(destination).write_text(json.dumps(result, separators=(",", ":")) + "\n")
print(json.dumps(result, sort_keys=True))
raise SystemExit(0 if result["pass"] else 1)
PY
  motion_source_sha="$(shasum -a 256 "$MOTION_SOURCE_LOG" | awk '{print $1}')"
  python3 - "$OUT_DIR/$run_id.provenance.json" "$summary" \
      "$MOTION_PRESENTER_SHA256" "$MOTION_DEFINITION_SHA256" \
      "$motion_source_sha" <<'PY'
import json, sys
provenance_path, summary_path, presenter, definition, source_log = sys.argv[1:]
record = json.load(open(provenance_path))
record.update({
    "motionPresenter": "Scripts/motion-presenter.py",
    "motionPresenterSHA256": presenter,
    "motionDefinition": "Scripts/motion-definition.json",
    "motionDefinitionSHA256": definition,
    "motionSourceLogSHA256": source_log,
    "motionSourcePreflight": json.load(open(summary_path)),
    "presentation": "gtk4-wayland-frame-clock-fractional-scale-aware",
})
open(provenance_path, "w").write(json.dumps(record, separators=(",", ":")) + "\n")
PY
  if (( ! source_pass )); then
    echo "motion source/compositor cadence failed before Lyte; see $summary" >&2
    exit 1
  fi
}

stop_motion() {
  [[ -z "$FFPLAY_PID" ]] || \
    ssh -o ConnectTimeout=10 "$PUP" "kill $FFPLAY_PID 2>/dev/null" || true
  FFPLAY_PID=""
}

start_synthetic_pipeline_host() {
  local run_id="$1"
  local standing identity_before identity_after
  SYNTHETIC_TRACE_REMOTE="/tmp/$run_id-host-trace.jsonl"
  SYNTHETIC_HOST_LOG_REMOTE="/tmp/$run_id-host.log"
  standing="$(ssh -o ConnectTimeout=10 "$PUP" \
    "pgrep -o -f 'lyte-host.*--wire-listen 41151' || true")"
  [[ "$standing" =~ ^[0-9]+$ ]] || {
    echo "synthetic pipeline requires the standing Host on 41151" >&2
    exit 1
  }
  identity_before="$(ssh -o ConnectTimeout=10 "$PUP" \
    "sha256sum ~/.config/lyte-host/noise_static.key \
~/.config/lyte-host/paired_clients | awk '{print \$1}'")"
  HOST_SUPERVISOR_PID="$(ssh -o ConnectTimeout=10 "$PUP" \
    "pgrep -o -f '[b]ash /home/shreeve/lyte-loop.sh' || true")"
  [[ "$HOST_SUPERVISOR_PID" =~ ^[0-9]+$ ]] || {
    echo "synthetic pipeline requires the known lyte-loop supervisor" >&2
    exit 1
  }
  ssh -o ConnectTimeout=10 "$PUP" \
    "kill -STOP '$HOST_SUPERVISOR_PID'; \
kill -9 '$standing'; \
XDG_RUNTIME_DIR=/run/user/1000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
WAYLAND_DISPLAY=wayland-0 \
LYTE_ALLOW_SYNTHETIC_CAPTURE=1 \
LYTE_SYNTHETIC_TRACE_JSONL='$SYNTHETIC_TRACE_REMOTE' \
LYTE_HANDSHAKE_WITNESS_JSONL='$HANDSHAKE_REMOTE_WITNESS' \
nohup ~/src/lyte-host/.build/debug/lyte-host --backend portal \
--wire-listen 41151 --ratchet --clipboard=images \
--bitrate-mbps '$SYNTHETIC_ENCODER_BITRATE_MBPS' \
--wire-rate-mbps '$SYNTHETIC_WIRE_RATE_MBPS' \
--synthetic-motion 2048x1280 --seconds '$((BENCH_SECONDS + 5))' \
>'$SYNTHETIC_HOST_LOG_REMOTE' 2>&1 & echo \$!" \
    > "$OUT_DIR/$run_id.synthetic-host.pid"
  read -r SYNTHETIC_HOST_PID < "$OUT_DIR/$run_id.synthetic-host.pid"
  [[ "$SYNTHETIC_HOST_PID" =~ ^[0-9]+$ ]] || {
    echo "failed to start synthetic pipeline Host" >&2
    exit 1
  }
  sleep 1
  ssh "$PUP" "kill -0 '$SYNTHETIC_HOST_PID'" || {
    echo "synthetic pipeline Host exited before client handshake" >&2
    exit 1
  }
  identity_after="$(ssh -o ConnectTimeout=10 "$PUP" \
    "sha256sum ~/.config/lyte-host/noise_static.key \
~/.config/lyte-host/paired_clients | awk '{print \$1}'")"
  [[ "$identity_before" == "$identity_after" ]] || {
    echo "synthetic Host startup changed protected identity files" >&2
    exit 1
  }
}

stop_synthetic_pipeline_host() {
  local run_id="$1"
  local trace="$OUT_DIR/$run_id-host-trace.jsonl"
  local host_log="$OUT_DIR/$run_id-host.log"
  [[ -z "$SYNTHETIC_HOST_PID" ]] || \
    ssh -o ConnectTimeout=10 "$PUP" \
      "kill -9 '$SYNTHETIC_HOST_PID' 2>/dev/null || true"
  sleep 1
  rsync -a "$PUP:$SYNTHETIC_TRACE_REMOTE" "$trace"
  rsync -a "$PUP:$SYNTHETIC_HOST_LOG_REMOTE" "$host_log"
  ssh -o ConnectTimeout=10 "$PUP" \
    "kill -CONT '$HOST_SUPERVISOR_PID'"
  SYNTHETIC_HOST_PID=""
  HOST_SUPERVISOR_PID=""
}

start_quality() {
  local run_id="$1"
  local corpus_dir="$OUT_DIR/$run_id-corpus"
  local cli="$ROOT/.build/release/lyte-cli"
  local monitor_state discovered source_dimensions presenter_b64
  local corpus_gate_log source_witness identity_before identity_after
  if ssh -o ConnectTimeout=10 "$PUP" \
      "pgrep -af '[f]fplay .*testsrc2' >/dev/null"; then
    echo "quality benchmark refused: an existing testsrc2 workload can cover the corpus" >&2
    exit 1
  fi
  monitor_state="$(ssh -o ConnectTimeout=10 "$PUP" \
    'XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
--object-path /org/gnome/Mutter/DisplayConfig \
--method org.gnome.Mutter.DisplayConfig.GetCurrentState')"
  discovered="$(printf '%s' "$monitor_state" | python3 -c '
import re, sys
state = sys.stdin.read()
match = re.search(
    r"\('\''[^'\'']+'\'', ([0-9]+), ([0-9]+), [^{}]*\{'\''is-current'\'': <true>",
    state,
)
if not match:
    raise SystemExit("no current physical monitor mode in Mutter state")
print(match.group(1), match.group(2))
')"
  read -r QUALITY_WIDTH QUALITY_HEIGHT <<< "$discovered"
  [[ "$QUALITY_WIDTH" =~ ^[0-9]+$ && "$QUALITY_HEIGHT" =~ ^[0-9]+$ ]] || {
    echo "failed to derive captured monitor dimensions" >&2
    exit 1
  }
  if [[ -n "$QUALITY_EXPECTED_WIDTH" ]] \
      && [[ "$QUALITY_WIDTH" != "$QUALITY_EXPECTED_WIDTH" \
         || "$QUALITY_HEIGHT" != "$QUALITY_EXPECTED_HEIGHT" ]]; then
    echo "quality dimension override ${QUALITY_EXPECTED_WIDTH}x${QUALITY_EXPECTED_HEIGHT} does not match active capture ${QUALITY_WIDTH}x${QUALITY_HEIGHT}" >&2
    exit 1
  fi
  ssh -o ConnectTimeout=10 "$PUP" \
    'python3 -c '"'"'import os
pid = int(os.popen("pgrep -n gnome-shell").read())
environment = open(f"/proc/{pid}/environ", "rb").read().split(b"\0")
assert b"MUTTER_DEBUG_PAINT=disable-direct-scanout" in environment
'"'" || {
    echo "quality benchmark refused: Mutter direct scanout is not disabled" >&2
    exit 1
  }

  # The reference generator is production CorpusFrames code. Build it even
  # under --no-build so a stale helper cannot bless a different source image.
  (cd "$ROOT" && swift build -c release --product lyte-cli)
  [[ -x "$cli" ]] || {
    echo "quality benchmark requires .build/release/lyte-cli" >&2
    exit 1
  }
  mkdir -p "$corpus_dir"
  "$cli" corpus-gen --out "$corpus_dir" \
    --width "$QUALITY_WIDTH" --height "$QUALITY_HEIGHT" --png
  QUALITY_REFERENCE_RAW="$corpus_dir/text-100.raw"
  local png="$corpus_dir/text-100.png"
  [[ -s "$QUALITY_REFERENCE_RAW" && -s "$png" ]] || {
    echo "controlled quality corpus generation failed" >&2
    exit 1
  }

  REMOTE_QUALITY_IMAGE="/tmp/lyte-benchmark-$run_id-text-100.png"
  REMOTE_QUALITY_PRESENTER="/tmp/lyte-benchmark-$run_id-presenter.py"
  REMOTE_QUALITY_WORK="/tmp/lyte-benchmark-$run_id-source-witness"
  rsync -a "$png" "$PUP:$REMOTE_QUALITY_IMAGE"
  source_dimensions="$(ssh -o ConnectTimeout=10 "$PUP" \
    "ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
-of csv=s=x:p=0 '$REMOTE_QUALITY_IMAGE'")"
  [[ "$source_dimensions" == "${QUALITY_WIDTH}x${QUALITY_HEIGHT}" ]] || {
    echo "quality source $source_dimensions does not match capture ${QUALITY_WIDTH}x${QUALITY_HEIGHT}" >&2
    exit 1
  }
  ssh -o ConnectTimeout=10 "$PUP" \
    'python3 -c '"'"'import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk
'"'" >/dev/null || {
    echo "quality benchmark requires pup GTK4 Python bindings" >&2
    exit 1
  }
  presenter_b64="$(printf '%s' 'import gi, sys
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk

class App(Gtk.Application):
    def do_activate(self):
        window = Gtk.ApplicationWindow(application=self)
        picture = Gtk.Picture.new_for_filename(sys.argv[1])
        picture.set_content_fit(Gtk.ContentFit.FILL)
        window.set_child(picture)
        window.set_cursor_from_name("none")
        window.fullscreen()
        window.present()

App(application_id="dev.shreeve.LyteQualityPresenter").run([])
' | base64)"
  FFPLAY_PID="$(ssh -o ConnectTimeout=10 "$PUP" \
    "printf '%s' '$presenter_b64' | base64 -d >'$REMOTE_QUALITY_PRESENTER'; \
XDG_RUNTIME_DIR=/run/user/1000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
WAYLAND_DISPLAY=wayland-0 nohup python3 '$REMOTE_QUALITY_PRESENTER' \
'$REMOTE_QUALITY_IMAGE' >'$REMOTE_QUALITY_PRESENTER.log' 2>&1 & echo \$!")"
  [[ "$FFPLAY_PID" =~ ^[0-9]+$ ]] || {
    echo "failed to obtain pup controlled-corpus PID" >&2
    exit 1
  }
  sleep 3
  ssh "$PUP" "kill -0 $FFPLAY_PID \
    && test ! -s '$REMOTE_QUALITY_PRESENTER.log'" || {
    echo "pup controlled quality workload failed to stay alive" >&2
    exit 1
  }

  # Fail closed before measuring the client: PipeWire must see the authored
  # corpus without the fractional-scale blur ffplay/SDL introduced.
  identity_before="$(ssh -o ConnectTimeout=10 "$PUP" \
    "sha256sum ~/.config/lyte-host/noise_static.key \
~/.config/lyte-host/paired_clients | awk '{print \$1}'")"
  ssh -o ConnectTimeout=10 "$PUP" \
    "LYTE_DUMP_RAW='$REMOTE_QUALITY_WORK.raw' \
XDG_RUNTIME_DIR=/run/user/1000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
~/src/lyte-host/.build/debug/lyte-host --backend portal --ratchet \
--bitrate-mbps 50 --seconds 4 --out '$REMOTE_QUALITY_WORK.hevc' \
>'$REMOTE_QUALITY_WORK.log' 2>&1"
  source_witness="$corpus_dir/source-witness.bgrx"
  rsync -a "$PUP:$REMOTE_QUALITY_WORK.raw" "$source_witness"
  identity_after="$(ssh -o ConnectTimeout=10 "$PUP" \
    "sha256sum ~/.config/lyte-host/noise_static.key \
~/.config/lyte-host/paired_clients | awk '{print \$1}'")"
  [[ "$identity_before" == "$identity_after" ]] || {
    echo "quality source witness changed host identity secrets" >&2
    exit 1
  }
  corpus_gate_log="$corpus_dir/source-witness-gate.log"
  "$cli" corpus-gate --manifest "$corpus_dir/manifest.json" \
    --frame text-100 --decoded "$source_witness" \
    --chroma 444 --mode baseline --range-posture limited601 \
    > "$corpus_gate_log"
  read -r SOURCE_WITNESS_R_DB SOURCE_WITNESS_G_DB \
    SOURCE_WITNESS_B_DB SOURCE_WITNESS_MIN_DB SOURCE_WITNESS_SSIM \
    <<< "$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
psnr = re.search(
    r"text-psnr-converged: min-ch ([0-9.]+|inf) dB "
    r"\(r ([0-9.]+|inf) g ([0-9.]+|inf) b ([0-9.]+|inf)\)",
    text,
)
ssim = re.search(r"ssim-converged: ([0-9.]+)", text)
if not psnr or not ssim:
    raise SystemExit("source witness metrics missing")
def json_db(value):
    return "999" if value == "inf" else value
print(json_db(psnr.group(2)), json_db(psnr.group(3)),
      json_db(psnr.group(4)), json_db(psnr.group(1)), ssim.group(1))
' "$corpus_gate_log")"
  python3 -c '
import sys
minimum, ssim = map(float, sys.argv[1:])
raise SystemExit(0 if minimum >= 45 and ssim >= 0.995 else 1)
' "$SOURCE_WITNESS_MIN_DB" "$SOURCE_WITNESS_SSIM" || {
    echo "quality source witness failed: ${SOURCE_WITNESS_MIN_DB} dB, SSIM ${SOURCE_WITNESS_SSIM}" >&2
    exit 1
  }
  SOURCE_WITNESS_SHA256="$(
    shasum -a 256 "$source_witness" | awk '{print $1}'
  )"
  # The one-shot portal witness can make the standing loop reopen its capture
  # session. Give that bounded respawn a head start before the app dials.
  sleep 3
}

run_leg() {
  local workload="$1"
  local stamp run_id jsonl pidfile stderr_file provenance_file readback_file
  local quality_reference_sha readback_sha build_badge benchmark_chroma
  local benchmark_reference_name motion_leg synthetic_motion
  local client_pipeline_witness
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  run_id="${workload}-${stamp}-$$"
  jsonl="$OUT_DIR/$run_id.jsonl"
  pidfile="$OUT_DIR/$run_id.pid"
  stderr_file="$OUT_DIR/$run_id.stderr"
  provenance_file="$OUT_DIR/$run_id.provenance.json"
  readback_file="$OUT_DIR/$run_id.readback.bgra"
  rm -f "$jsonl" "$pidfile" "$stderr_file" "$provenance_file" "$readback_file"
  cat > "$provenance_file" <<EOF
{"runID":"$run_id","buildUTC":"$APP_BUILD_UTC","clientExecutableSHA256":"$APP_SHA256","clientSourceSHA256":"$CLIENT_SOURCE_SHA256","hostExecutableSHA256":"$HOST_SHA256","hostSourceSHA256":"$HOST_SOURCE_SHA256"}
EOF

  QUALITY_REFERENCE_RAW=""
  benchmark_chroma=""
  benchmark_reference_name="text-100"
  motion_leg=""
  synthetic_motion=""
  client_pipeline_witness=""
  if [[ "${LYTE_ENABLE_PIPELINE_WITNESS:-0}" == 1 ]]; then
    client_pipeline_witness="$OUT_DIR/$run_id-client-pipeline-witness.jsonl"
  fi
  [[ "$workload" != motion ]] || start_motion "$run_id"
  if [[ "$workload" == motion-pipeline || "$workload" == handshake-only ]]; then
    QUALITY_WIDTH=2048
    QUALITY_HEIGHT=1280
    if [[ "$workload" == motion-pipeline ]]; then
      benchmark_chroma="$MOTION_CHROMA_TIER"
      benchmark_reference_name="synthetic-motion-v1"
      motion_leg="synthetic-host-pipeline"
      synthetic_motion="1"
    fi
    start_handshake_evidence "$run_id"
    start_synthetic_pipeline_host "$run_id"
  fi
  [[ "$workload" != quality-static ]] || start_quality "$run_id"
  if [[ "$workload" == quality-static ]]; then
    benchmark_chroma="best"
    quality_reference_sha="$(
      shasum -a 256 "$QUALITY_REFERENCE_RAW" | awk '{print $1}'
    )"
    cat > "$provenance_file" <<EOF
{"runID":"$run_id","buildUTC":"$APP_BUILD_UTC","clientExecutableSHA256":"$APP_SHA256","clientSourceSHA256":"$CLIENT_SOURCE_SHA256","hostExecutableSHA256":"$HOST_SHA256","hostSourceSHA256":"$HOST_SOURCE_SHA256","chromaTier":"best","qualityReference":"CorpusFrames/v1/text-100","qualityReferenceSHA256":"$quality_reference_sha","qualityWidth":$QUALITY_WIDTH,"qualityHeight":$QUALITY_HEIGHT,"capturedMonitorWidth":$QUALITY_WIDTH,"capturedMonitorHeight":$QUALITY_HEIGHT,"presentation":"gtk4-wayland-fullscreen-fractional-scale-aware","mutterDirectScanoutDisabled":true,"sourceWitnessSHA256":"$SOURCE_WITNESS_SHA256","sourceWitnessRDB":$SOURCE_WITNESS_R_DB,"sourceWitnessGDB":$SOURCE_WITNESS_G_DB,"sourceWitnessBDB":$SOURCE_WITNESS_B_DB,"sourceWitnessMinDB":$SOURCE_WITNESS_MIN_DB,"sourceWitnessLumaSSIM":$SOURCE_WITNESS_SSIM}
EOF
  fi
  if [[ "$workload" == motion-pipeline || "$workload" == handshake-only ]]; then
    python3 - "$provenance_file" <<PY
import json, pathlib
path = pathlib.Path("$provenance_file")
record = json.loads(path.read_text())
record.update({
    "motionLeg": "$workload",
    "captureBypass": "PipeWire+Mutter only",
    "syntheticSource": "HostCore.SyntheticMotionSource/v1",
    "syntheticSourceSHA256": "$(shasum -a 256 "$ROOT/Host/Sources/HostCore/SyntheticMotionSource.swift" | awk '{print $1}')",
    "clientReferenceSHA256": "$(shasum -a 256 "$ROOT/Sources/LyteTransport/SyntheticMotionReference.swift" | awk '{print $1}')",
    "qualityWidth": 2048,
    "qualityHeight": 1280,
    "chromaTier": "$benchmark_chroma",
    "encoderBitrateMbps": $SYNTHETIC_ENCODER_BITRATE_MBPS,
    "wireRateMbps": $SYNTHETIC_WIRE_RATE_MBPS,
    "qualityProbe": $QUALITY_PROBE,
})
path.write_text(json.dumps(record, separators=(",", ":")) + "\n")
PY
  fi
  build_badge="build $APP_BUILD_UTC · C ${CLIENT_SOURCE_SHA256:0:12}/${APP_SHA256:0:12} · H ${HOST_SOURCE_SHA256:0:12}/${HOST_SHA256:0:12} · $run_id"
  open -n -F -W \
    --env "LYTE_AUTOCONNECT=$HOST" \
    --env "LYTE_BENCHMARK_JSONL=$jsonl" \
    --env "LYTE_BENCHMARK_PIDFILE=$pidfile" \
    --env "LYTE_BENCHMARK_RUN_ID=$run_id" \
    --env "LYTE_BENCHMARK_WORKLOAD=$workload" \
    --env "LYTE_BENCHMARK_SECONDS=$BENCH_SECONDS" \
    --env "LYTE_BENCHMARK_REFERENCE_RAW=$QUALITY_REFERENCE_RAW" \
    --env "LYTE_BENCHMARK_REFERENCE_NAME=$benchmark_reference_name" \
    --env "LYTE_BENCHMARK_REFERENCE_WIDTH=$QUALITY_WIDTH" \
    --env "LYTE_BENCHMARK_REFERENCE_HEIGHT=$QUALITY_HEIGHT" \
    --env "LYTE_BENCHMARK_READBACK_RAW=$readback_file" \
    --env "LYTE_BENCHMARK_SOURCE_WITNESS_SHA256=$SOURCE_WITNESS_SHA256" \
    --env "LYTE_BENCHMARK_SOURCE_WITNESS_R_DB=$SOURCE_WITNESS_R_DB" \
    --env "LYTE_BENCHMARK_SOURCE_WITNESS_G_DB=$SOURCE_WITNESS_G_DB" \
    --env "LYTE_BENCHMARK_SOURCE_WITNESS_B_DB=$SOURCE_WITNESS_B_DB" \
    --env "LYTE_BENCHMARK_SOURCE_WITNESS_MIN_DB=$SOURCE_WITNESS_MIN_DB" \
    --env "LYTE_BENCHMARK_SOURCE_WITNESS_SSIM=$SOURCE_WITNESS_SSIM" \
    --env "LYTE_BENCHMARK_MOTION_SOURCE_SUMMARY=$OUT_DIR/$run_id-motion-source-preflight.json" \
    --env "LYTE_BENCHMARK_MOTION_LEG=$motion_leg" \
    --env "LYTE_BENCHMARK_SYNTHETIC_MOTION=$synthetic_motion" \
    --env "LYTE_BENCHMARK_QUALITY_PROBE=$QUALITY_PROBE" \
    --env "LYTE_HANDSHAKE_WITNESS_JSONL=$OUT_DIR/$run_id-client-handshake.jsonl" \
    --env "LYTE_PIPELINE_WITNESS_JSONL=$client_pipeline_witness" \
    --env "LYTE_BENCHMARK_CHROMA_TIER=$benchmark_chroma" \
    --env "LYTE_DIAGNOSTIC_BUILD_BADGE=$build_badge" \
    --stderr "$stderr_file" "$APP" &
  OPEN_PID=$!
  sleep 0.2
  FALLBACK_APP_PID="$(pgrep -n -f "$APP/Contents/MacOS/Lyte" || true)"

  for _ in {1..600}; do
    [[ -s "$pidfile" ]] && break
    kill -0 "$OPEN_PID" 2>/dev/null || break
    sleep 0.1
  done
  [[ -s "$pidfile" ]] || {
    echo "Lyte.app did not publish its benchmark PID" >&2
    exit 1
  }
  read -r APP_PID published_run_id < "$pidfile"
  [[ "$published_run_id" == "$run_id" && "$APP_PID" =~ ^[0-9]+$ ]] || {
    echo "benchmark PID/run identity mismatch" >&2
    exit 1
  }

  local deadline=$(( $(date +%s) + BENCH_SECONDS + 45 ))
  while kill -0 "$APP_PID" 2>/dev/null; do
    (( $(date +%s) < deadline )) || {
      echo "Lyte.app exceeded bounded run deadline (PID $APP_PID)" >&2
      exit 1
    }
    sleep 1
  done
  wait "$OPEN_PID" || true
  OPEN_PID=""
  APP_PID=""
  FALLBACK_APP_PID=""
  [[ "$workload" != motion-pipeline && "$workload" != handshake-only ]] \
    || collect_handshake_evidence
  [[ "$workload" != motion ]] || stop_motion
  [[ "$workload" != motion-pipeline && "$workload" != handshake-only ]] \
    || stop_synthetic_pipeline_host "$run_id"
  [[ "$workload" != quality-static ]] || stop_motion
  if [[ "$workload" == quality-static && -s "$readback_file" ]]; then
    readback_sha="$(shasum -a 256 "$readback_file" | awk '{print $1}')"
    python3 -c '
import json, sys
path, digest = sys.argv[1:]
record = json.load(open(path))
record["nativeReadbackSHA256"] = digest
open(path, "w").write(json.dumps(record, separators=(",", ":")) + "\n")
' "$provenance_file" "$readback_sha"
  fi
  if [[ "$workload" == motion-pipeline ]]; then
    python3 - "$OUT_DIR/$run_id-host-trace.jsonl" \
        "$OUT_DIR/$run_id-host-summary.json" "$provenance_file" \
        "$jsonl" <<'PY'
import json, math, sys
from pathlib import Path

trace_path, summary_path, provenance_path, benchmark_path = sys.argv[1:]
events = [json.loads(line) for line in Path(trace_path).read_text().splitlines()]
source = [event for event in events if event["type"] == "source"]
encodes = [event for event in events if event["type"] == "encode"]
wires = [event for event in events if event["type"] == "wire"]

def percentile(values, rank):
    if not values:
        return None
    values = sorted(values)
    return values[max(0, math.ceil(rank / 100 * len(values)) - 1)]

def stats(values):
    return {
        "p50Milliseconds": percentile(values, 50),
        "p95Milliseconds": percentile(values, 95),
        "p99Milliseconds": percentile(values, 99),
    }

source_late = [event["latenessNS"] / 1e6 for event in source]
render_time = [
    (event["renderFinishedNS"] - event["renderStartNS"]) / 1e6
    for event in source
]
encode_time = [
    (event["encodeFinishedNS"] - event["encodeStartNS"]) / 1e6
    for event in encodes
]
deadline_by_us = {
    event["deadlineNS"] // 1000: event["deadlineNS"] for event in source
}
deadline_to_admission = [
    (event["admittedNS"] - deadline_by_us[event["captureMicroseconds"]]) / 1e6
    for event in wires if event["captureMicroseconds"] in deadline_by_us
]
admission_to_first = [
    (event["firstTransmitNS"] - event["admittedNS"]) / 1e6
    for event in wires if event["firstTransmitNS"]
]
first_to_last = [
    (event["lastTransmitNS"] - event["firstTransmitNS"]) / 1e6
    for event in wires if event["firstTransmitNS"] and event["lastTransmitNS"]
]
summary = {
    "sourceFrames": len(source),
    "encodedFrames": len(encodes),
    "wireFrames": len(wires),
    "sourceDeadlineLateness": stats(source_late),
    "sourceRenderDuration": stats(render_time),
    "encodeDuration": stats(encode_time),
    "deadlineToAdmission": stats(deadline_to_admission),
    "admissionToFirstTransmit": stats(admission_to_first),
    "firstToLastTransmit": stats(first_to_last),
    "purgedFrames": sum(event["purged"] for event in wires),
    "keyframes": sum(event["keyframe"] for event in wires),
}
Path(summary_path).write_text(json.dumps(summary, separators=(",", ":")) + "\n")
record = json.loads(Path(provenance_path).read_text())
record["hostTraceSHA256"] = __import__("hashlib").sha256(
    Path(trace_path).read_bytes()).hexdigest()
record["hostPipelineSummary"] = summary
Path(provenance_path).write_text(json.dumps(record, separators=(",", ":")) + "\n")
records = [
    json.loads(line) for line in Path(benchmark_path).read_text().splitlines()
]
for item in records:
    if item.get("type") == "sample":
        item["hostPipeline"] = summary
Path(benchmark_path).write_text(
    "".join(json.dumps(item, separators=(",", ":")) + "\n" for item in records)
)
print(json.dumps(summary, sort_keys=True))
PY
  fi

  echo "benchmark JSONL: $jsonl"
  echo "benchmark provenance: $provenance_file"
  if [[ "$workload" == handshake-only ]]; then
    python3 - "$jsonl" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
end = next((item for item in reversed(records) if item.get("type") == "end"), None)
if end is None or not end.get("everStreaming", False):
    raise SystemExit("handshake-only attempt never reached streaming")
print(json.dumps({
    "runID": end["runID"],
    "everStreaming": True,
    "elapsedSeconds": end["elapsedSeconds"],
}, sort_keys=True))
PY
    return
  fi
  python3 "$ANALYZER" --pretty "$jsonl"
}

case "$MODE" in
  static) run_leg static ;;
  motion) run_leg motion ;;
  motion-pipeline) run_leg motion-pipeline ;;
  handshake-only) run_leg handshake-only ;;
  quality) run_leg quality-static ;;
  all)
    rc=0
    run_leg static || rc=1
    run_leg motion || rc=1
    run_leg quality-static || rc=1
    exit "$rc"
    ;;
esac
