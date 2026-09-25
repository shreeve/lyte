#!/usr/bin/env bash
# Repeatable real Lyte.app glass-path benchmark against the standing pup host.
#
# Environment: LYTE_PUP_HOST (default pup), LYTE_BENCHMARK_HOST (address the
# app dials), LYTE_BENCHMARK_PORT (UDP port lyte-host.service must own;
# default 41151), LYTE_BENCHMARK_{SECONDS,OUT_DIR,QUALITY_PROBE,
# FREEZE_FRAME_ID,CHROMA_TIER}, LYTE_ENABLE_PIPELINE_WITNESS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The one physical Lyte.app: a second copy with the same bundle identity
# breaks macOS Local Network privacy. A benchmark that builds turns it into
# a diagnostic build for the run and restores the plain build at exit.
APP="$ROOT/.build/Lyte.app"
MAKE_APP="${LYTE_MAKE_APP:-$ROOT/Scripts/make-app.sh}"
REBUILD="Scripts/benchmark-app.sh without --no-build (it restores the plain app at exit)"
APP_EXECUTABLE="$APP/Contents/MacOS/Lyte"
ANALYZER="$ROOT/Scripts/analyze-app-benchmark.py"
source "$ROOT/Scripts/lib/benchmark-process.sh"
source "$ROOT/Scripts/lib/pup.sh"
source "$ROOT/Scripts/lib/benchmark-handshake.sh"
source "$ROOT/Scripts/AppArtifact/app-artifact.sh"
source "$ROOT/Scripts/lib/source-fingerprint.sh"
LSREGISTER="${LYTE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
PUP="$(lyte_pup_host)"
# The standing host advertises on the ethernet leg (10.0.0.232); over wifi
# replies can source from the wrong interface and the handshake dies.
HOST="${LYTE_BENCHMARK_HOST:-10.0.0.232}"
BENCH_PORT="${LYTE_BENCHMARK_PORT:-41151}"
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
[[ "$BENCH_PORT" =~ ^[0-9]+$ ]] && (( BENCH_PORT >= 1 && BENCH_PORT <= 65535 )) \
  || { echo "LYTE_BENCHMARK_PORT must be a UDP port" >&2; exit 2; }

refuse_if_lyte_is_running() {
  local pids status
  if pids="$(lyte_benchmark_app_pids 2>/dev/null)"; then
    echo "benchmark refused: Lyte is already running (PID(s):" \
      "$(printf '%s' "$pids" | tr '\n' ' ' | sed 's/ $//'))" >&2
    echo "quit the interactive client before running diagnostics" >&2
    exit 1
  else
    status=$?
  fi
  (( status == 1 )) || {
    echo "benchmark refused: cannot inspect running Lyte processes" >&2
    exit 1
  }
}

bundle_is_diagnostic() {
  local value
  value="$(plutil -extract LyteDiagnosticEntryPoints raw \
    -o - "$1/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$value" == true ]] || return 1
}

# Set once this process starts the diagnostic build: from then on every exit
# — success, failure or signal — restores the plain everyday bundle, after
# the app-artifact lock is released and the benchmark app has exited. A
# `--no-build` run (every leg of `all`) built nothing and restores nothing.
RESTORE_PLAIN_APP=0
restore_plain_app() {
  (( RESTORE_PLAIN_APP )) || return 0
  RESTORE_PLAIN_APP=0
  exec 9>&-
  local waited=0
  while lyte_benchmark_app_pids >/dev/null 2>&1 && (( waited < 100 )); do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  bundle_is_diagnostic "$APP" || return 0
  # A subprocess that inherited the lock descriptor (a tool the signal just
  # killed) can hold it a moment longer; wait for it, boundedly.
  (
    exec 8>"${LYTE_APP_LOCK_FILE:-$ROOT/.build/.lyte-app-artifact.lock}"
    "${LYTE_LOCKF:-lockf}" -s -t 10 8
  ) || true
  echo "==> restoring the everyday app: Scripts/make-app.sh release" >&2
  if (cd "$ROOT" && env -u LYTE_APP_DESTINATION "$MAKE_APP" release); then
    return 0
  fi
  cat >&2 <<EOF
WARNING: ============================================================
WARNING: .build/Lyte.app is STILL A DIAGNOSTIC BUILD. It obeys the
WARNING: autoconnect and benchmark environment. Restore the everyday
WARNING: app before using it, from $ROOT:
WARNING:
WARNING:     Scripts/make-app.sh release
WARNING: ============================================================
EOF
}

handle_early_signal() {
  trap - EXIT
  trap '' INT TERM
  restore_plain_app
  exit "$1"
}

trap restore_plain_app EXIT
trap 'handle_early_signal 130' INT
trap 'handle_early_signal 143' TERM

# Precedes directory creation, builds, remote work, and service restart;
# each leg re-checks for an app launched during preflight.
refuse_if_lyte_is_running
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
if (( ! NO_BUILD )); then
  mkdir -p "$ROOT/.build"
  RESTORE_PLAIN_APP=1
  (cd "$ROOT" && env -u LYTE_APP_DESTINATION "$MAKE_APP" --diagnostics release)
fi
[[ -x "$APP/Contents/MacOS/Lyte" ]] || {
  echo "missing signed app $APP: run $REBUILD" >&2
  exit 1
}
# The app obeys the benchmark environment only when its signed Info.plist
# enables the diagnostic entry points; any other bundle would never start.
bundle_is_diagnostic "$APP" || {
  echo "benchmark refused: $APP is not a diagnostic build" >&2
  echo "rebuild it with $REBUILD" >&2
  exit 1
}
# Hold the app-artifact lock for the whole leg so no assembly swaps the
# bundle under a running benchmark. `all` re-execs one process per leg, and
# each child takes the lock itself.
if [[ "$MODE" != all ]]; then
  lyte_acquire_app_artifact_lock
fi
codesign --verify --strict "$APP"

# shellcheck disable=SC2086  # the path list is space-separated by design
CLIENT_SOURCE_SHA256="$(lyte_source_fingerprint "$ROOT" $LYTE_CLIENT_SOURCE_PATHS)"
recorded_client_source="$APP/Contents/Resources/client-source.sha256"
[[ -s "$recorded_client_source" ]] || {
  echo "benchmark refused: $APP has no signed source provenance" >&2
  echo "rebuild it with $REBUILD" >&2
  exit 1
}
read -r bundled_client_source < "$recorded_client_source"
[[ "$CLIENT_SOURCE_SHA256" == "$bundled_client_source" ]] || {
  echo "benchmark refused: $APP was built from different client source" >&2
  echo "rebuild it with $REBUILD" >&2
  exit 1
}
read -r APP_BUILD_UTC < "$APP/Contents/Resources/build-utc.txt" || {
  echo "benchmark refused: $APP has no signed build timestamp" >&2
  exit 1
}

if (( NO_BUILD )); then
  # shellcheck disable=SC2086
  stale_client_source="$(
    lyte_source_files "$ROOT" $LYTE_CLIENT_SOURCE_PATHS \
      | while IFS= read -r path; do
          if [[ -f "$ROOT/$path" && "$ROOT/$path" -nt "$APP/Contents/MacOS/Lyte" ]]; then
            printf '%s\n' "$path"
          fi
        done
  )"
  [[ -z "$stale_client_source" ]] || {
    echo "--no-build refused: client source is newer than $APP:" >&2
    printf '%s\n' "$stale_client_source" >&2
    exit 1
  }
fi

# A benchmark is evidence only when pup built exactly the source under
# review; dry-run checksums catch "edit B, run A" even when mtimes agree.
# Each path is checked on its own so a failed ssh cannot pass as no delta.
# pup keeps Host at ~/src/lyte-host and each other package at ~/src/<name>.
pup_host_sources=""
deployed_delta=""
for path in $LYTE_HOST_SOURCE_PATHS; do
  case "$path" in
    Host/*) remote="src/lyte-host/${path#Host/}" ;;
    *) remote="src/$path" ;;
  esac
  pup_host_sources+=" $remote"
  if [[ -d "$ROOT/$path" ]]; then
    path+=/
    remote+=/
  fi
  delta="$(pup_rsync -ani --checksum --no-times --omit-dir-times --delete \
    --exclude .build "$ROOT/$path" "$PUP:$remote")" || {
    echo "benchmark refused: cannot compare $path with pup" >&2
    exit 1
  }
  deployed_delta+="$delta"
done
[[ -z "$deployed_delta" ]] || {
  echo "benchmark refused: local Host/Wire/Common source differs from pup:" >&2
  printf '%s\n' "$deployed_delta" >&2
  exit 1
}

stale_host_source="$(pup_ssh "cd && find$pup_host_sources -type f \
  -newer src/lyte-host/.build/release/lyte-host")"
[[ -z "$stale_host_source" ]] || {
  echo "benchmark refused: pup Host binary predates deployed source:" >&2
  printf '%s\n' "$stale_host_source" >&2
  exit 1
}

pup_service_owns_port "$BENCH_PORT" || {
  echo "benchmark refused: lyte-host.service is not active or does not own UDP $BENCH_PORT" >&2
  exit 1
}
# The deployed ~/.local/bin/lyte-host must be built from the checked source.
host_hashes="$(pup_run 'pid="$(lyte_host_main_pid)"
built="$(sha256sum ~/src/lyte-host/.build/release/lyte-host)"
echo "${pid:+$(lyte_host_exe_sha "$pid")}:$(lyte_deployed_host_sha):${built%% *}"')"
IFS=: read -r running_host_sha deployed_host_sha built_host_sha <<< "$host_hashes"
[[ "$deployed_host_sha" == "$built_host_sha" ]] || {
  echo "benchmark refused: the deployed pup Host is not the built binary (run Host/Scripts/deploy-host.sh --restart)" >&2
  exit 1
}
[[ -n "$running_host_sha" && "$running_host_sha" == "$deployed_host_sha" ]] || {
  echo "benchmark refused: running pup Host is not the deployed binary (restart lyte-host)" >&2
  exit 1
}

APP_SHA256="$(shasum -a 256 "$APP/Contents/MacOS/Lyte" | awk '{print $1}')"
HOST_SHA256="$running_host_sha"
# shellcheck disable=SC2086
HOST_SOURCE_SHA256="$(lyte_source_fingerprint "$ROOT" $LYTE_HOST_SOURCE_PATHS)"

PRESENTER_PID=""
APP_PID=""
APP_RUN_ID=""
APP_PIDFILE=""
OPEN_PID=""
CLEANUP_STARTED=0

# provenance_merge FILE KEY=STRING|KEY:=JSON...: sets each KEY in the JSON
# provenance record FILE (created when absent).
provenance_merge() {
  python3 - "$@" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text()) if path.exists() else {}
for item in sys.argv[2:]:
    key, value = item.split("=", 1)
    if key.endswith(":"):
        key, value = key[:-1], json.loads(value)
    record[key] = value
path.write_text(json.dumps(record, separators=(",", ":")) + "\n")
PY
}

cleanup() {
  (( CLEANUP_STARTED == 0 )) || return 0
  CLEANUP_STARTED=1
  trap '' INT TERM
  local claimed_pid="" claimed_run_id="" extra="" candidate_pid=""
  if [[ -n "$APP_RUN_ID" && -n "$APP_PIDFILE" ]]; then
    # An interrupt may land between `open` and the PID-file read; give that
    # exact claim a short chance to appear, never guess a process by name.
    for _ in {1..40}; do
      [[ -s "$APP_PIDFILE" ]] && break
      sleep 0.05
    done
    if [[ -s "$APP_PIDFILE" ]]; then
      read -r claimed_pid claimed_run_id extra < "$APP_PIDFILE" || true
    fi
    candidate_pid="${APP_PID:-$claimed_pid}"
    if [[ -n "$extra" || -z "$candidate_pid" ]]; then
      echo "WARNING: refusing to terminate a benchmark with a stale claim" >&2
    elif kill -0 "$candidate_pid" 2>/dev/null \
        && ! lyte_benchmark_terminate_claimed \
          "$APP_PIDFILE" "$candidate_pid" "$APP_EXECUTABLE" "$APP_RUN_ID"
    then
      echo "WARNING: refusing to terminate unattested PID $candidate_pid" >&2
    fi
  fi
  if [[ -n "$OPEN_PID" ]] && kill -0 "$OPEN_PID" 2>/dev/null; then
    kill "$OPEN_PID" 2>/dev/null || true
  fi
  collect_handshake_evidence
  if [[ -n "$PRESENTER_PID" ]]; then
    pup_ssh "kill $PRESENTER_PID 2>/dev/null" || true
  fi
  if [[ -n "$REMOTE_MOTION_PRESENTER" ]]; then
    pup_ssh \
      "rm -f '$REMOTE_MOTION_PRESENTER' '$REMOTE_MOTION_DEFINITION' \
'$REMOTE_MOTION_LOG' '$REMOTE_MOTION_LOG.stderr'" || true
  fi
  if (( FRESH_HOST_RECOVERY_NEEDED )); then
    pup_ssh \
      "sudo -n systemctl start lyte-host; \
systemctl is-active --quiet lyte-host" || {
      echo "WARNING: failed to restore lyte-host.service" >&2
    }
    FRESH_HOST_RECOVERY_NEEDED=0
  fi
}

handle_signal() {
  local status="$1"
  trap - EXIT
  trap '' INT TERM
  cleanup
  restore_plain_app
  exit "$status"
}

trap 'cleanup; restore_plain_app' EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

start_motion() {
  local run_id="$1"
  local freeze="${2:-}"
  local monitor_state discovered scale summary
  local presenter="$ROOT/Scripts/motion-presenter.py"
  local definition="$ROOT/Scripts/motion-definition.json"
  refuse_if_lyte_is_running
  monitor_state="$(pup_ssh \
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
print(mode.group(1), mode.group(2), logical.group(3))
')"
  read -r QUALITY_WIDTH QUALITY_HEIGHT scale <<< "$discovered"
  pup_ssh \
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
  pup_rsync -a "$presenter" "$PUP:$REMOTE_MOTION_PRESENTER"
  pup_rsync -a "$definition" "$PUP:$REMOTE_MOTION_DEFINITION"
  remote_hashes="$(pup_ssh \
    "sha256sum '$REMOTE_MOTION_PRESENTER' '$REMOTE_MOTION_DEFINITION' \
| awk '{print \$1}'")"
  [[ "$(printf '%s\n' "$remote_hashes" | awk 'NR == 1 {print}')" \
      == "$MOTION_PRESENTER_SHA256" \
      && "$(printf '%s\n' "$remote_hashes" | awk 'NR == 2 {print}')" \
      == "$MOTION_DEFINITION_SHA256" ]] || {
    echo "motion presenter provenance mismatch after upload" >&2
    exit 1
  }
  PRESENTER_PID="$(pup_ssh \
    "XDG_RUNTIME_DIR=/run/user/1000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
WAYLAND_DISPLAY=wayland-0 nohup python3 '$REMOTE_MOTION_PRESENTER' \
--definition '$REMOTE_MOTION_DEFINITION' \
--width '$QUALITY_WIDTH' --height '$QUALITY_HEIGHT' \
${freeze:+--freeze $freeze} \
--log '$REMOTE_MOTION_LOG' >'$REMOTE_MOTION_LOG.stderr' 2>&1 & echo \$!")"
  [[ "$PRESENTER_PID" =~ ^[0-9]+$ ]] || {
    echo "failed to obtain the pup motion presenter PID" >&2
    exit 1
  }
  sleep 5
  pup_ssh "kill -0 $PRESENTER_PID" || {
    echo "pup motion workload failed to stay alive" >&2
    exit 1
  }
  pup_rsync -a "$PUP:$REMOTE_MOTION_LOG" "$MOTION_SOURCE_LOG"
  summary="$OUT_DIR/$run_id-motion-source-preflight.json"
  source_pass=1
  python3 "$ROOT/Scripts/motion_preflight.py" "$MOTION_SOURCE_LOG" "$summary" \
      "$QUALITY_WIDTH" "$QUALITY_HEIGHT" "$scale" "$freeze" || source_pass=0
  provenance_merge "$OUT_DIR/$run_id.provenance.json" \
    motionPresenter=Scripts/motion-presenter.py \
    motionPresenterSHA256="$MOTION_PRESENTER_SHA256" \
    motionDefinition=Scripts/motion-definition.json \
    motionDefinitionSHA256="$MOTION_DEFINITION_SHA256" \
    motionSourceLogSHA256="$(shasum -a 256 "$MOTION_SOURCE_LOG" | awk '{print $1}')" \
    motionSourcePreflight:="$(cat "$summary" 2>/dev/null \
      || echo '{"pass":false,"error":"preflight wrote no summary"}')" \
    presentation=gtk4-wayland-frame-clock-fractional-scale-aware
  if (( ! source_pass )); then
    echo "motion source/compositor cadence failed before Lyte; see $summary" >&2
    exit 1
  fi
}

stop_motion() {
  [[ -z "$PRESENTER_PID" ]] || \
    pup_ssh "kill $PRESENTER_PID 2>/dev/null" || true
  PRESENTER_PID=""
}

run_leg() {
  local workload="$1"
  local stamp nonce run_id jsonl pidfile stderr_file provenance_file readback_file
  local build_badge benchmark_chroma benchmark_reference_name synthetic_motion
  local client_pipeline_witness old_pid new_pid
  refuse_if_lyte_is_running
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  nonce="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  run_id="${workload}-${stamp}-$$-${nonce:0:12}"
  [[ "$run_id" =~ ^[A-Za-z0-9._:-]+$ && ${#run_id} -le 128 ]] || {
    echo "benchmark refused: generated an invalid run identity" >&2
    exit 1
  }
  jsonl="$OUT_DIR/$run_id.jsonl"
  pidfile="$OUT_DIR/$run_id.pid"
  stderr_file="$OUT_DIR/$run_id.stderr"
  provenance_file="$OUT_DIR/$run_id.provenance.json"
  readback_file="$OUT_DIR/$run_id.readback.bgra"
  rm -f "$jsonl" "$pidfile" "$stderr_file" "$provenance_file" "$readback_file"
  provenance_merge "$provenance_file" runID="$run_id" \
    buildUTC="$APP_BUILD_UTC" clientExecutableSHA256="$APP_SHA256" \
    clientSourceSHA256="$CLIENT_SOURCE_SHA256" \
    hostExecutableSHA256="$HOST_SHA256" hostSourceSHA256="$HOST_SOURCE_SHA256"

  # Pin the leg's chroma tier (good|best — ChromaTier rawValues). Empty
  # keeps the app's persisted tier: fine for smoke, ambiguous for an A/B.
  benchmark_chroma="${LYTE_BENCHMARK_CHROMA_TIER:-}"
  benchmark_reference_name=""
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
  elif [[ "$workload" == handshake-only ]]; then
    QUALITY_WIDTH=2048
    QUALITY_HEIGHT=1280
    start_handshake_evidence "$run_id"
    refuse_if_lyte_is_running
    start_fresh_host "$run_id"
    read -r old_pid new_pid < "$OUT_DIR/$run_id.fresh-host.pids"
    provenance_merge "$provenance_file" hostLifecycle=systemd-restart \
      hostMainPIDBefore:="$old_pid" hostMainPIDAfter:="$new_pid" \
      qualityWidth:="$QUALITY_WIDTH" qualityHeight:="$QUALITY_HEIGHT"
  fi
  build_badge="build $APP_BUILD_UTC · C ${CLIENT_SOURCE_SHA256:0:12}/${APP_SHA256:0:12} · H ${HOST_SOURCE_SHA256:0:12}/${HOST_SHA256:0:12} · $run_id"
  refuse_if_lyte_is_running
  APP_RUN_ID="$run_id"
  APP_PIDFILE="$pidfile"
  # Register this exact bundle first so Local Network privacy evaluates this
  # build's identity (same rule as launch-app.sh).
  "$LSREGISTER" -f "$APP"
  open -n -F -W \
    --env "LYTE_AUTOCONNECT=$HOST" \
    --env "LYTE_BENCHMARK_JSONL=$jsonl" \
    --env "LYTE_BENCHMARK_PIDFILE=$pidfile" \
    --env "LYTE_BENCHMARK_RUN_ID=$run_id" \
    --env "LYTE_BENCHMARK_WORKLOAD=$workload" \
    --env "LYTE_BENCHMARK_SECONDS=$BENCH_SECONDS" \
    --env "LYTE_BENCHMARK_REFERENCE_NAME=$benchmark_reference_name" \
    --env "LYTE_BENCHMARK_REFERENCE_WIDTH=$QUALITY_WIDTH" \
    --env "LYTE_BENCHMARK_REFERENCE_HEIGHT=$QUALITY_HEIGHT" \
    --env "LYTE_BENCHMARK_READBACK_RAW=$readback_file" \
    --env "LYTE_BENCHMARK_MOTION_SOURCE_SUMMARY=$OUT_DIR/$run_id-motion-source-preflight.json" \
    --env "LYTE_BENCHMARK_SYNTHETIC_MOTION=$synthetic_motion" \
    --env "LYTE_BENCHMARK_QUALITY_PROBE=$QUALITY_PROBE" \
    --env "LYTE_HANDSHAKE_WITNESS_JSONL=$OUT_DIR/$run_id-client-handshake.jsonl" \
    --env "LYTE_PIPELINE_WITNESS_JSONL=$client_pipeline_witness" \
    --env "LYTE_BENCHMARK_CHROMA_TIER=$benchmark_chroma" \
    --env "LYTE_DIAGNOSTIC_BUILD_BADGE=$build_badge" \
    --stderr "$stderr_file" "$APP" \
    --args --lyte-benchmark-run-id "$run_id" &
  OPEN_PID=$!

  for _ in {1..600}; do
    [[ -s "$pidfile" ]] && break
    kill -0 "$OPEN_PID" 2>/dev/null || break
    sleep 0.1
  done
  [[ -s "$pidfile" ]] || {
    echo "Lyte.app did not publish its benchmark PID" >&2
    exit 1
  }
  local published_run_id="" published_extra=""
  read -r APP_PID published_run_id published_extra < "$pidfile"
  [[ -z "$published_extra" && "$published_run_id" == "$run_id" \
      && "$APP_PID" =~ ^[0-9]+$ ]] || {
    echo "benchmark PID/run identity mismatch" >&2
    exit 1
  }
  lyte_benchmark_claim_matches \
    "$APP_PID" "$APP_EXECUTABLE" "$APP_RUN_ID" || {
    echo "benchmark process did not attest its PID/run identity" >&2
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
  APP_RUN_ID=""
  APP_PIDFILE=""
  [[ "$workload" != handshake-only ]] || collect_handshake_evidence
  [[ "$workload" != motion && "$workload" != quality-static ]] || stop_motion
  [[ "$workload" != handshake-only ]] || finish_fresh_host "$run_id"

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
  static|motion|quality-static|handshake-only) run_leg "$MODE" ;;
  all)
    # One process per leg: `run_leg x || rc=1` would disable set -e inside
    # the whole leg, so provenance and pup failures would be ignored.
    rc=0
    for leg in static motion quality-static; do
      LYTE_PUP_HOST="$PUP" "$BASH" "$ROOT/Scripts/benchmark-app.sh" \
        --no-build --seconds "$BENCH_SECONDS" --out "$OUT_DIR" "$leg" \
        || rc=1
    done
    exit "$rc"
    ;;
esac
