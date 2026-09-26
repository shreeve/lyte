#!/usr/bin/env bash
# The handshake-only benchmark leg's host side: packet captures and counters
# at both ends, and a restart of the real systemd unit (keeping its
# arguments, seat environment and ambient CAP_SYS_ADMIN) to measure connect
# latency. Protected host state must stay byte-identical across the leg.
#
# Needs lib/pup.sh and PUP, HOST, BENCH_PORT, BENCH_SECONDS and OUT_DIR.

HANDSHAKE_RUN_ID=""
HANDSHAKE_LOCAL_TCPDUMP_PID=""
HANDSHAKE_REMOTE_TCPDUMP_PID=""
FRESH_HOST_RECOVERY_NEEDED=0
FRESH_HOST_PROTECTED_STATE=""
FRESH_HOST_JOURNAL_SINCE=""
FRESH_HOST_LOG_OFFSET=0

start_handshake_evidence() {
  local run_id="$1" interface
  HANDSHAKE_RUN_ID="$run_id"
  route -n get "$HOST" > "$OUT_DIR/$run_id-client-route.txt"
  interface="$(awk '/interface:/ {print $2}' "$OUT_DIR/$run_id-client-route.txt")"
  [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]] || {
    echo "cannot resolve the interface that reaches $HOST" >&2
    return 1
  }
  netstat -s -p udp > "$OUT_DIR/$run_id-client-udp-before.txt"
  sudo -n tcpdump -i "$interface" -nn -U \
    -w "$OUT_DIR/$run_id-client.pcap" "udp port $BENCH_PORT" \
    >"$OUT_DIR/$run_id-client-tcpdump.stderr" 2>&1 &
  HANDSHAKE_LOCAL_TCPDUMP_PID=$!
  # Both captures run as root under sudo, and $! is the sudo process: only
  # `sudo -n kill` can signal it (sudo relays the signal to tcpdump). The
  # pup capture is also bounded by timeout in case this side never returns.
  HANDSHAKE_REMOTE_TCPDUMP_PID="$(pup_ssh \
    "sudo -n rm -f '/tmp/$run_id-host.pcap'; \
sudo -n nohup timeout $((BENCH_SECONDS + 300)) \
tcpdump -i any -nn -U -w '/tmp/$run_id-host.pcap' \
'udp port $BENCH_PORT' >'/tmp/$run_id-host-tcpdump.stderr' 2>&1 & echo \$!")"
  pup_run lyte_host_snapshot > "$OUT_DIR/$run_id-host-before.txt"
}

collect_handshake_evidence() {
  local run_id="$HANDSHAKE_RUN_ID" file
  [[ -n "$run_id" ]] || return 0
  [[ -z "$HANDSHAKE_LOCAL_TCPDUMP_PID" ]] \
    || sudo -n kill "$HANDSHAKE_LOCAL_TCPDUMP_PID" 2>/dev/null || true
  [[ -z "$HANDSHAKE_REMOTE_TCPDUMP_PID" ]] \
    || pup_ssh \
      "sudo -n kill '$HANDSHAKE_REMOTE_TCPDUMP_PID' 2>/dev/null || true" || true
  sleep 1
  if [[ -n "$HANDSHAKE_LOCAL_TCPDUMP_PID" ]] \
      && ps -p "$HANDSHAKE_LOCAL_TCPDUMP_PID" >/dev/null 2>&1; then
    echo "WARNING: local root tcpdump (sudo PID $HANDSHAKE_LOCAL_TCPDUMP_PID) is still capturing" >&2
  fi
  if [[ -n "$HANDSHAKE_REMOTE_TCPDUMP_PID" ]] \
      && pup_ssh "ps -p '$HANDSHAKE_REMOTE_TCPDUMP_PID' >/dev/null 2>&1"; then
    echo "WARNING: pup root tcpdump (sudo PID $HANDSHAKE_REMOTE_TCPDUMP_PID) is still capturing" >&2
  fi
  netstat -s -p udp > "$OUT_DIR/$run_id-client-udp-after.txt"
  sudo -n tcpdump -nn -tttt -vv \
    -r "$OUT_DIR/$run_id-client.pcap" "udp port $BENCH_PORT" \
    > "$OUT_DIR/$run_id-client-packets.txt" 2>/dev/null || true
  for file in host.pcap host-tcpdump.stderr; do
    pup_rsync -a "$PUP:/tmp/$run_id-$file" "$OUT_DIR/$run_id-$file" \
      2>/dev/null || true
  done
  tcpdump -nn -tttt -vv -r "$OUT_DIR/$run_id-host.pcap" \
    "udp port $BENCH_PORT" > "$OUT_DIR/$run_id-host-packets.txt" \
    2>/dev/null || true
  # tcpdump ran as root on pup; its capture is root-owned.
  pup_ssh "sudo -n rm -f '/tmp/$run_id-host.pcap' \
'/tmp/$run_id-host-tcpdump.stderr'" || true
  pup_run lyte_host_snapshot > "$OUT_DIR/$run_id-host-after.txt" || true
  shasum -a 256 "$OUT_DIR/$run_id"* \
    > "$OUT_DIR/$run_id-handshake-artifacts.sha256" 2>/dev/null || true
  HANDSHAKE_RUN_ID=""
  HANDSHAKE_LOCAL_TCPDUMP_PID=""
  HANDSHAKE_REMOTE_TCPDUMP_PID=""
}

start_fresh_host() {
  local run_id="$1" restart_result before_pid after_pid
  # Only a service that was running is restarted, or restored by cleanup.
  pup_run lyte_host_main_pid >/dev/null || {
    echo "handshake-only requires active lyte-host.service" >&2
    return 1
  }
  FRESH_HOST_PROTECTED_STATE="$(pup_run lyte_protected_state_fingerprint)"
  FRESH_HOST_JOURNAL_SINCE="$(date -u +%FT%TZ)"
  FRESH_HOST_LOG_OFFSET="$(pup_ssh \
    "stat -c %s ~/.local/state/lyte/host.log 2>/dev/null || echo 0")"
  FRESH_HOST_RECOVERY_NEEDED=1
  restart_result="$(pup_run "lyte_restart_host $BENCH_PORT")"
  read -r before_pid after_pid <<< "$restart_result"
  [[ "$before_pid" =~ ^[0-9]+$ && "$after_pid" =~ ^[0-9]+$ \
      && "$before_pid" != "$after_pid" ]] || {
    echo "lyte-host.service restart did not produce a fresh process" >&2
    return 1
  }
  FRESH_HOST_RECOVERY_NEEDED=0

  [[ "$(pup_run lyte_protected_state_fingerprint)" \
      == "$FRESH_HOST_PROTECTED_STATE" ]] || {
    echo "lyte-host.service restart changed protected host state" >&2
    return 1
  }
  printf '%s %s\n' "$before_pid" "$after_pid" \
    > "$OUT_DIR/$run_id.fresh-host.pids"
}

finish_fresh_host() {
  local run_id="$1"
  pup_ssh \
    "sudo -n journalctl -u lyte-host \
--since '$FRESH_HOST_JOURNAL_SINCE' --no-pager" > "$OUT_DIR/$run_id-host.log"
  # The host's own output since the restart. A start that rotated the log
  # leaves a file shorter than the recorded offset: take all of it.
  pup_ssh "log=~/.local/state/lyte/host.log; offset=$FRESH_HOST_LOG_OFFSET; \
size=\$(stat -c %s \"\$log\" 2>/dev/null || echo 0); \
[ \"\$size\" -ge \"\$offset\" ] || offset=0; \
tail -c +\$((offset + 1)) \"\$log\"" > "$OUT_DIR/$run_id-host-output.log" || true
  pup_ssh \
    "systemctl is-active --quiet lyte-host" || {
    echo "lyte-host.service is not active after handshake-only" >&2
    return 1
  }
  [[ "$(pup_run lyte_protected_state_fingerprint)" \
      == "$FRESH_HOST_PROTECTED_STATE" ]] || {
    echo "handshake-only changed protected host state" >&2
    return 1
  }
  FRESH_HOST_PROTECTED_STATE=""
  FRESH_HOST_JOURNAL_SINCE=""
  FRESH_HOST_LOG_OFFSET=0
}

# recover_fresh_host: the exit path of a leg that may have died between
# start_fresh_host and finish_fresh_host. Starts a service the restart left
# down, then proves the protected state still matches its fingerprint from
# before the restart; a change or an unreadable file fails loudly.
recover_fresh_host() {
  if (( FRESH_HOST_RECOVERY_NEEDED )); then
    pup_ssh \
      "sudo -n systemctl start lyte-host; \
systemctl is-active --quiet lyte-host" || {
      echo "WARNING: failed to restore lyte-host.service" >&2
    }
    FRESH_HOST_RECOVERY_NEEDED=0
  fi
  [[ -n "$FRESH_HOST_PROTECTED_STATE" ]] || return 0
  local expected="$FRESH_HOST_PROTECTED_STATE"
  FRESH_HOST_PROTECTED_STATE=""
  [[ "$(pup_run lyte_protected_state_fingerprint)" == "$expected" ]] \
    && return 0
  cat >&2 <<EOF
ERROR: ============================================================
ERROR: PROTECTED HOST STATE CHANGED OR UNREADABLE on $PUP after the
ERROR: handshake leg restarted lyte-host.service. Check the identity
ERROR: (~/.config/lyte/noise_static.key, paired_clients) and host.conf
ERROR: against their known SHA-256 before trusting the host.
ERROR: ============================================================
EOF
  return 1
}
