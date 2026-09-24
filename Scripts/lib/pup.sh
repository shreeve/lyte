#!/usr/bin/env bash

# Reference-host (pup) access shared by every live-rig script.
#
# LYTE_PUP_HOST is the single ssh destination for the benchmark, netem and
# pup-gate scripts. A script that shapes one host while its child benchmarks
# another produces evidence about neither, so the retired per-script names
# are refused rather than silently ignored.

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

# Every ssh to pup carries a connect timeout, including cleanup paths, so a
# dead link fails the run instead of hanging it.
pup_ssh() {
  ssh -o ConnectTimeout=10 "$PUP" "$@"
}

# True when the standing lyte-host.service MainPID owns UDP <port> on pup.
# The benchmark app dials its pinned host, so this is the only flow a
# benchmark leg can measure.
pup_service_owns_port() {
  local port="$1" pid
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
  pid="$(pup_ssh "systemctl is-active --quiet lyte-host \
&& systemctl show lyte-host --property MainPID --value || true")" || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  pup_ssh "sudo -n ss -H -lunp 'sport = :$port' | grep -q 'pid=$pid,'"
}
