#!/usr/bin/env bash

# Reference-host (pup) access shared by every live-rig script.
# LYTE_PUP_HOST is the single ssh destination; retired per-script host
# variables are refused rather than silently ignored.

lyte_pup_side="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pup-side.sh"

lyte_pup_host() {
  local legacy
  for legacy in PUP LYTE_BENCHMARK_PUP; do
    if [[ -n "${!legacy:-}" ]]; then
      echo "refusing $legacy=${!legacy}: set LYTE_PUP_HOST instead" >&2
      return 1
    fi
  done
  printf '%s\n' "${LYTE_PUP_HOST:-pup}"
}

# Every ssh to pup, rsync's included, carries a connect timeout and a
# keepalive, including cleanup paths, so a link that is dead at connect or
# dies mid-run fails the run instead of hanging it.
pup_ssh() {
  ssh -o ConnectTimeout=10 -o ServerAliveInterval=10 \
    -o ServerAliveCountMax=3 "$PUP" "$@"
}

pup_rsync() {
  rsync -e 'ssh -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3' "$@"
}

# pup_run SCRIPT: runs SCRIPT in bash on pup with lib/pup-side.sh loaded.
# `bash -s` reads its script as it runs, so SCRIPT is one group, parsed
# whole before it starts, whose stdin is /dev/null: a command in it that
# reads stdin cannot swallow the lines after it.
pup_run() {
  { cat "$lyte_pup_side"; printf '{\n%s\n} </dev/null\n' "$1"; } \
    | pup_ssh 'bash -s'
}

# True when the standing lyte-host.service MainPID owns UDP <port> on pup
# (the only flow a benchmark leg can measure).
pup_service_owns_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
  pup_run "pid=\$(lyte_host_main_pid) && lyte_host_owns_port $port \"\$pid\""
}
