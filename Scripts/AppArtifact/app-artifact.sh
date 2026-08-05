#!/bin/sh

# Shared process and serialization policy for Lyte.app assembly/publication.
# Callers remain responsible for choosing whether a destination is the owner's
# live bundle or an isolated validation artifact.

lyte_acquire_app_artifact_lock() {
  lock_file="${LYTE_APP_LOCK_FILE:-$ROOT/.build/.lyte-app-artifact.lock}"
  mkdir -p "$(dirname "$lock_file")"
  exec 9>"$lock_file"
  if ! "${LYTE_LOCKF:-lockf}" -s -t 0 9; then
    echo "error: another Lyte app assembly or launch is in progress" >&2
    return 1
  fi
}

# Print "name<TAB>pid" for every matching owner-app/helper process.
# Status 0 means at least one match, 1 means quiescent, and 2 means the process
# table could not be inspected. That distinction is security-relevant.
lyte_app_processes() {
  process_name=""
  process_pids=""
  process_status=0
  found_process=1

  for process_name in Lyte lyte-helperd; do
    if process_pids="$("${LYTE_PGREP:-pgrep}" -x "$process_name" 2>/dev/null)"; then
      found_process=0
      while IFS= read -r process_pid; do
        case "$process_pid" in
          ''|*[!0-9]*) return 2 ;;
        esac
        printf '%s\t%s\n' "$process_name" "$process_pid"
      done <<EOF
$process_pids
EOF
    else
      process_status=$?
      [ "$process_status" -eq 1 ] || return 2
    fi
  done
  return "$found_process"
}

lyte_require_app_quiescent() {
  operation="$1"
  if active_processes="$(lyte_app_processes)"; then
    echo "error: $operation refused while Lyte code is running" >&2
    printf '%s\n' "$active_processes" \
      | awk -F '\t' '{ printf "       %s PID %s\n", $1, $2 }' >&2
    return 1
  else
    process_status=$?
  fi
  if [ "$process_status" -ne 1 ]; then
    echo "error: $operation cannot inspect Lyte process state" >&2
    return 1
  fi
}

lyte_wait_for_exact_app() {
  expected_executable="$1"
  attempts="${2:-50}"
  attempt=0

  while [ "$attempt" -lt "$attempts" ]; do
    if active_processes="$(lyte_app_processes)"; then
      while IFS="$(printf '\t')" read -r process_name process_pid; do
        [ "$process_name" = Lyte ] || continue
        process_command="$(
          "${LYTE_PS:-ps}" -ww -p "$process_pid" -o command= 2>/dev/null
        )" || {
          echo "error: launched Lyte process identity is unreadable" >&2
          return 1
        }
        case "$process_command" in
          "$expected_executable"|"$expected_executable "*)
            printf '%s\n' "$process_pid"
            return 0
            ;;
        esac
      done <<EOF
$active_processes
EOF
    else
      process_status=$?
      if [ "$process_status" -ne 1 ]; then
        echo "error: launch cannot inspect Lyte process state" >&2
        return 1
      fi
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done

  echo "error: LaunchServices did not start the registered Lyte artifact" >&2
  return 1
}
