#!/usr/bin/env bash

# Process-identity helpers for benchmark-app.sh. This is a side-effect-free
# library so its signal edge can be tested without running a benchmark or
# touching the reference host.

lyte_benchmark_app_pids() {
  "${LYTE_PGREP:-pgrep}" -x Lyte
}

lyte_benchmark_claim_matches() {
  local pid="$1"
  local executable="$2"
  local run_id="$3"
  local command_line remainder

  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
  [[ "$run_id" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  command_line="$(ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ "$command_line" == "$executable"* ]] || return 1
  remainder="${command_line#"$executable"}"
  [[ -z "$remainder" || "$remainder" == " "* ]] || return 1
  [[ " $remainder " == *" --lyte-benchmark-run-id $run_id "* ]]
}

lyte_benchmark_claim_file_matches() {
  local claim_file="$1"
  local expected_pid="$2"
  local expected_run_id="$3"
  local claimed_pid="" claimed_run_id="" extra=""

  [[ -s "$claim_file" ]] || return 1
  read -r claimed_pid claimed_run_id extra < "$claim_file" || return 1
  [[ -z "$extra" && "$claimed_pid" == "$expected_pid" \
      && "$claimed_run_id" == "$expected_run_id" ]]
}

lyte_benchmark_terminate_claimed() {
  local claim_file="$1"
  local pid="$2"
  local executable="$3"
  local run_id="$4"

  lyte_benchmark_claim_file_matches "$claim_file" "$pid" "$run_id" \
    || return 1
  lyte_benchmark_claim_matches "$pid" "$executable" "$run_id" || return 1
  kill "$pid"
}
