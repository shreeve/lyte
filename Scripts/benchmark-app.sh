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
NO_BUILD=0

usage() {
  echo "usage: Scripts/benchmark-app.sh [--no-build] [--seconds N] [--out DIR] static|motion|all"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) NO_BUILD=1; shift ;;
    --seconds) BENCH_SECONDS="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    static|motion|all) MODE="$1"; shift ;;
    *) usage; exit 2 ;;
  esac
done
MODE="${MODE:-}"
[[ "$MODE" =~ ^(static|motion|all)$ ]] || { usage; exit 2; }
[[ "$BENCH_SECONDS" =~ ^[0-9]+$ ]] \
  && (( BENCH_SECONDS >= 5 && BENCH_SECONDS <= 3600 )) \
  || { echo "seconds must be an integer in 5...3600" >&2; exit 2; }

mkdir -p "$OUT_DIR"
if (( ! NO_BUILD )); then
  "$ROOT/Scripts/make-app.sh" release
fi
[[ -x "$APP/Contents/MacOS/Lyte" ]] || {
  echo "missing signed app: run Scripts/make-app.sh release" >&2
  exit 1
}
codesign --verify --strict "$APP"

FFPLAY_PID=""
APP_PID=""
OPEN_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$OPEN_PID" ]] && kill -0 "$OPEN_PID" 2>/dev/null; then
    kill "$OPEN_PID" 2>/dev/null || true
  fi
  if [[ -n "$FFPLAY_PID" ]]; then
    ssh -o ConnectTimeout=10 "$PUP" "kill $FFPLAY_PID 2>/dev/null" || true
  fi
}
trap cleanup EXIT INT TERM

start_motion() {
  ssh -o ConnectTimeout=10 "$PUP" \
    'command -v ffplay >/dev/null && test -S /run/user/1000/wayland-0'
  FFPLAY_PID="$(ssh -o ConnectTimeout=10 "$PUP" \
    "XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
SDL_VIDEODRIVER=wayland nohup ffplay -loglevel error -f lavfi \
-i 'testsrc2=size=1920x1080:rate=60' >/tmp/lyte-benchmark-ffplay.log 2>&1 & echo \$!")"
  [[ "$FFPLAY_PID" =~ ^[0-9]+$ ]] || {
    echo "failed to obtain pup ffplay PID" >&2
    exit 1
  }
  sleep 3
  ssh "$PUP" "kill -0 $FFPLAY_PID" || {
    echo "pup motion workload failed to stay alive" >&2
    exit 1
  }
}

stop_motion() {
  [[ -z "$FFPLAY_PID" ]] || \
    ssh -o ConnectTimeout=10 "$PUP" "kill $FFPLAY_PID 2>/dev/null" || true
  FFPLAY_PID=""
}

run_leg() {
  local workload="$1"
  local stamp run_id jsonl pidfile stderr_file
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  run_id="${workload}-${stamp}-$$"
  jsonl="$OUT_DIR/$run_id.jsonl"
  pidfile="$OUT_DIR/$run_id.pid"
  stderr_file="$OUT_DIR/$run_id.stderr"
  rm -f "$jsonl" "$pidfile" "$stderr_file"

  [[ "$workload" != motion ]] || start_motion
  open -n -F -W \
    --env "LYTE_AUTOCONNECT=$HOST" \
    --env "LYTE_BENCHMARK_JSONL=$jsonl" \
    --env "LYTE_BENCHMARK_PIDFILE=$pidfile" \
    --env "LYTE_BENCHMARK_RUN_ID=$run_id" \
    --env "LYTE_BENCHMARK_WORKLOAD=$workload" \
    --env "LYTE_BENCHMARK_SECONDS=$BENCH_SECONDS" \
    --stderr "$stderr_file" "$APP" &
  OPEN_PID=$!

  for _ in {1..200}; do
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
  [[ "$workload" != motion ]] || stop_motion

  echo "benchmark JSONL: $jsonl"
  python3 "$ANALYZER" --pretty "$jsonl"
}

case "$MODE" in
  static) run_leg static ;;
  motion) run_leg motion ;;
  all)
    rc=0
    run_leg static || rc=1
    run_leg motion || rc=1
    exit "$rc"
    ;;
esac
