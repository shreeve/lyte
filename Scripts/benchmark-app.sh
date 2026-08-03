#!/usr/bin/env bash
# Repeatable real Lyte.app glass-path benchmark against the standing pup host.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Lyte.app"
ANALYZER="$ROOT/Scripts/analyze-app-benchmark.py"
PUP="${PUP:-pup}"
# The standing host advertises on the ethernet leg (enxf8e43b7ede7c =
# 10.0.0.232); the wifi address answers ICMP but replies can source
# from the wrong interface and the handshake dies silently.
HOST="${LYTE_BENCHMARK_HOST:-10.0.0.232}"
BENCH_SECONDS="${LYTE_BENCHMARK_SECONDS:-30}"
OUT_DIR="${LYTE_BENCHMARK_OUT_DIR:-$ROOT/.build/benchmarks}"
QUALITY_PROBE="${LYTE_BENCHMARK_QUALITY_PROBE:-1}"
# The authored frame the quality-static leg holds on the glass (any ID
# works; mid-pattern keeps the moving elements clear of the marker strip).
FREEZE_FRAME_ID="${LYTE_BENCHMARK_FREEZE_FRAME_ID:-900}"
QUALITY_WIDTH=""
QUALITY_HEIGHT=""
MOTION_PRESENTER_SHA256=""
MOTION_DEFINITION_SHA256=""
MOTION_SOURCE_LOG=""
REMOTE_MOTION_PRESENTER=""
REMOTE_MOTION_DEFINITION=""
REMOTE_MOTION_LOG=""
TAKEOVER_HOST_PID=""
TAKEOVER_HOST_LOG_REMOTE=""
HOST_SUPERVISOR_PID=""
NO_BUILD=0
APP_SHA256=""
HOST_SHA256=""
CLIENT_SOURCE_SHA256=""
HOST_SOURCE_SHA256=""
APP_BUILD_UTC=""

usage() {
  echo "usage: Scripts/benchmark-app.sh [--no-build] [--seconds N] [--out DIR] static|motion|quality-static|handshake-only|all"
  echo "  (static = the idle desktop; motion = compositor motion scored by"
  echo "   the GPU-readback quality witness; quality-static = the presenter"
  echo "   frozen on one authored frame, witness held to the static bar)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) NO_BUILD=1; shift ;;
    --seconds) BENCH_SECONDS="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    static|motion|quality-static|handshake-only|all) MODE="$1"; shift ;;
    *) usage; exit 2 ;;
  esac
done
MODE="${MODE:-}"
[[ "$MODE" =~ ^(static|motion|quality-static|handshake-only|all)$ ]] || { usage; exit 2; }
minimum_seconds=5
[[ "$MODE" != handshake-only ]] || minimum_seconds=1
[[ "$BENCH_SECONDS" =~ ^[0-9]+$ ]] \
  && (( BENCH_SECONDS >= minimum_seconds && BENCH_SECONDS <= 3600 )) \
  || { echo "seconds must be an integer in ${minimum_seconds}...3600" >&2; exit 2; }
[[ "$QUALITY_PROBE" =~ ^[01]$ ]] \
  || { echo "quality probe must be 0 or 1" >&2; exit 2; }
[[ "$FREEZE_FRAME_ID" =~ ^[0-9]+$ ]] \
  || { echo "freeze frame must be a non-negative integer" >&2; exit 2; }
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
  if [[ -n "$TAKEOVER_HOST_LOG_REMOTE" ]]; then
    rsync -a "$PUP:$TAKEOVER_HOST_LOG_REMOTE" \
      "$OUT_DIR/$run_id-host.log" 2>/dev/null || true
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
  if [[ -n "$TAKEOVER_HOST_PID" ]]; then
    ssh -o ConnectTimeout=10 "$PUP" \
      "kill -9 '$TAKEOVER_HOST_PID' 2>/dev/null || true; \
kill -CONT '$HOST_SUPERVISOR_PID' 2>/dev/null || true" || true
    TAKEOVER_HOST_PID=""
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
  local freeze="${2:-}"
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
${freeze:+--freeze $freeze} \
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
      "$QUALITY_WIDTH" "$QUALITY_HEIGHT" "$scale" "$freeze" <<'PY' || source_pass=0
import json, math, sys
from pathlib import Path

source, destination, width, height, scale, freeze = sys.argv[1:]
events = [json.loads(line) for line in Path(source).read_text().splitlines()]

if freeze:
    # Frozen presenter: the preflight proves the single authored frame
    # reached the glass at exact dimensions; cadence has no meaning.
    frozen_id = int(freeze)
    rows = [row for row in events if row.get("event") == "sourceTick"]
    if not rows:
        raise SystemExit("frozen source never ticked")
    if any(row["frameID"] != frozen_id for row in rows):
        raise SystemExit("frozen source presented a foreign frame")
    presented = [
        row for row in events
        if row.get("event") == "presentation"
        and row.get("frameID") == frozen_id
        and row.get("actualPresentationMicroseconds", 0) > 0
    ]
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
        "gapP50Milliseconds": 0.0,
        "gapP95Milliseconds": 0.0,
        "gapP99Milliseconds": 0.0,
        "phaseDriftP99Milliseconds": 0.0,
        "skippedSourceFrames": 0,
        "kind": "frozen-frame",
        "frozenFrameID": frozen_id,
    }
    result["pass"] = dimensions_exact and len(presented) >= 1
    Path(destination).write_text(
        json.dumps(result, separators=(",", ":")) + "\n")
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["pass"] else 1)

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

# handshake-only measures connect latency against a fresh host on the
# standing port: pause the supervisor, replace the standing host with a
# direct-eye takeover host (E5: the direct eye is the only backend), and
# restore the loop afterwards. Identity files must be untouched.
start_takeover_host() {
  local run_id="$1"
  local standing identity_before identity_after
  TAKEOVER_HOST_LOG_REMOTE="/tmp/$run_id-host.log"
  standing="$(ssh -o ConnectTimeout=10 "$PUP" \
    "pgrep -o -f 'lyte-host.*--wire-listen 41151' || true")"
  [[ "$standing" =~ ^[0-9]+$ ]] || {
    echo "takeover requires the standing Host on 41151" >&2
    exit 1
  }
  identity_before="$(ssh -o ConnectTimeout=10 "$PUP" \
    "sha256sum ~/.config/lyte-host/noise_static.key \
~/.config/lyte-host/paired_clients | awk '{print \$1}'")"
  HOST_SUPERVISOR_PID="$(ssh -o ConnectTimeout=10 "$PUP" \
    "pgrep -o -f '[b]ash /home/shreeve/lyte-loop.sh' || true")"
  [[ "$HOST_SUPERVISOR_PID" =~ ^[0-9]+$ ]] || {
    echo "takeover requires the known lyte-loop supervisor" >&2
    exit 1
  }
  ssh -o ConnectTimeout=10 "$PUP" \
    "kill -STOP '$HOST_SUPERVISOR_PID'; \
kill -9 '$standing'; \
XDG_RUNTIME_DIR=/run/user/1000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
WAYLAND_DISPLAY=wayland-0 \
LYTE_HANDSHAKE_WITNESS_JSONL='$HANDSHAKE_REMOTE_WITNESS' \
nohup ~/src/lyte-host/.build/debug/lyte-host --backend direct \
--wire-listen 41151 --clipboard=images \
--wire-rate-mbps 50 --seconds '$((BENCH_SECONDS + 5))' \
>'$TAKEOVER_HOST_LOG_REMOTE' 2>&1 & echo \$!" \
    > "$OUT_DIR/$run_id.takeover-host.pid"
  read -r TAKEOVER_HOST_PID < "$OUT_DIR/$run_id.takeover-host.pid"
  [[ "$TAKEOVER_HOST_PID" =~ ^[0-9]+$ ]] || {
    echo "failed to start takeover Host" >&2
    exit 1
  }
  sleep 1
  ssh "$PUP" "kill -0 '$TAKEOVER_HOST_PID'" || {
    echo "takeover Host exited before client handshake" >&2
    exit 1
  }
  identity_after="$(ssh -o ConnectTimeout=10 "$PUP" \
    "sha256sum ~/.config/lyte-host/noise_static.key \
~/.config/lyte-host/paired_clients | awk '{print \$1}'")"
  [[ "$identity_before" == "$identity_after" ]] || {
    echo "takeover Host startup changed protected identity files" >&2
    exit 1
  }
}

stop_takeover_host() {
  local run_id="$1"
  local host_log="$OUT_DIR/$run_id-host.log"
  [[ -z "$TAKEOVER_HOST_PID" ]] || \
    ssh -o ConnectTimeout=10 "$PUP" \
      "kill -9 '$TAKEOVER_HOST_PID' 2>/dev/null || true"
  sleep 1
  rsync -a "$PUP:$TAKEOVER_HOST_LOG_REMOTE" "$host_log"
  ssh -o ConnectTimeout=10 "$PUP" \
    "kill -CONT '$HOST_SUPERVISOR_PID'"
  TAKEOVER_HOST_PID=""
  HOST_SUPERVISOR_PID=""
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
  # V-4: pin the leg's chroma tier from the caller's environment
  # (good|best — ChromaTier rawValues). Empty = the app's own seeding
  # (the pinned host's persisted tier) — fine for smoke, ambiguous
  # for an A/B.
  benchmark_chroma="${LYTE_BENCHMARK_CHROMA_TIER:-}"
  benchmark_reference_name=""
  motion_leg=""
  synthetic_motion=""
  client_pipeline_witness=""
  if [[ "${LYTE_ENABLE_PIPELINE_WITNESS:-0}" == 1 ]]; then
    client_pipeline_witness="$OUT_DIR/$run_id-client-pipeline-witness.jsonl"
  fi
  if [[ "$workload" == motion ]]; then
    start_motion "$run_id"
    synthetic_motion=1
    benchmark_reference_name="motion-definition-v1"
  elif [[ "$workload" == quality-static ]]; then
    start_motion "$run_id" "$FREEZE_FRAME_ID"
    synthetic_motion=1
    benchmark_reference_name="motion-definition-v1"
  fi
  if [[ "$workload" == handshake-only ]]; then
    QUALITY_WIDTH=2048
    QUALITY_HEIGHT=1280
    start_handshake_evidence "$run_id"
    start_takeover_host "$run_id"
  fi
  if [[ "$workload" == handshake-only ]]; then
    python3 - "$provenance_file" <<PY
import json, pathlib
path = pathlib.Path("$provenance_file")
record = json.loads(path.read_text())
record.update({
    "motionLeg": "handshake-only",
    "qualityWidth": 2048,
    "qualityHeight": 1280,
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
  [[ "$workload" != handshake-only ]] || collect_handshake_evidence
  [[ "$workload" != motion && "$workload" != quality-static ]] || stop_motion
  [[ "$workload" != handshake-only ]] || stop_takeover_host "$run_id"

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
  quality-static) run_leg quality-static ;;
  handshake-only) run_leg handshake-only ;;
  all)
    rc=0
    run_leg static || rc=1
    run_leg motion || rc=1
    run_leg quality-static || rc=1
    exit "$rc"
    ;;
esac
