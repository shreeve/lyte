#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
netem="$repo_root/Scripts/netem/port-netem.sh"
benchmark="$repo_root/Scripts/benchmark-app.sh"
benchmark_process="$repo_root/Scripts/lib/benchmark-process.sh"
benchmark_netem="$repo_root/Scripts/benchmark-netem.sh"
build_cli="$repo_root/Scripts/build-cli.sh"
make_app="$repo_root/Scripts/make-app.sh"
macos_gate="$repo_root/Scripts/CI/test-all-macos.sh"
pup_gate="$repo_root/Scripts/CI/test-all-pup.sh"
vscode_launch="$repo_root/.vscode/launch.json"
vscode_tasks="$repo_root/.vscode/tasks.json"
fake_tc="$repo_root/Scripts/Tests/Fixtures/fake-tc.sh"
test_root="$(mktemp -d)"
ordinary_pid=""
claimed_pid=""
cleanup() {
    [[ -z "$ordinary_pid" ]] || kill "$ordinary_pid" 2>/dev/null || true
    [[ -z "$claimed_pid" ]] || kill "$claimed_pid" 2>/dev/null || true
    rm -rf "$test_root"
}
trap cleanup EXIT

source "$benchmark_process"

# The owner guard runs before output creation, builds, or any pup operation,
# and an unreadable process table fails closed.
fake_pgrep="$test_root/fake-pgrep"
cat > "$fake_pgrep" <<'EOF'
#!/bin/sh
case "${LYTE_FAKE_PGREP_RESULT:-match}" in
  match) printf '%s\n' 4242; exit 0 ;;
  empty) exit 1 ;;
  error) exit 2 ;;
esac
exit 2
EOF
chmod +x "$fake_pgrep"
blocked_out="$test_root/blocked-output"
if LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=match \
    "$benchmark" --no-build --out "$blocked_out" handshake-only \
    >"$test_root/blocked.stdout" 2>"$test_root/blocked.stderr"
then
    echo "benchmark ignored an active Lyte process" >&2
    exit 1
fi
[[ ! -e "$blocked_out" ]]
grep -Fq 'PID(s): 4242' "$test_root/blocked.stderr"

error_out="$test_root/error-output"
if LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=error \
    "$benchmark" --no-build --out "$error_out" handshake-only \
    >"$test_root/error.stdout" 2>"$test_root/error.stderr"
then
    echo "benchmark trusted an unreadable process table" >&2
    exit 1
fi
[[ ! -e "$error_out" ]]
grep -Fq 'cannot inspect running Lyte processes' "$test_root/error.stderr"

allowed_out="$test_root/allowed-output"
mkdir -p "$test_root/bin"
cat > "$test_root/bin/codesign" <<'EOF'
#!/bin/sh
echo "fake codesign reached" >&2
exit 73
EOF
chmod +x "$test_root/bin/codesign"
if PATH="$test_root/bin:$PATH" \
    LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=empty \
    "$benchmark" --no-build --out "$allowed_out" handshake-only \
    >"$test_root/allowed.stdout" 2>"$test_root/allowed.stderr"
then
    echo "benchmark unexpectedly passed without a built app" >&2
    exit 1
fi
[[ -d "$allowed_out" ]]
if ! grep -Fq 'fake codesign reached' "$test_root/allowed.stderr" \
    && ! grep -Fq 'missing signed app' "$test_root/allowed.stderr"
then
    echo "benchmark did not progress beyond an empty owner preflight" >&2
    exit 1
fi

export LYTE_TC="$fake_tc"
export LYTE_FAKE_TC_LOG="$test_root/tc.log"
export LYTE_FAKE_TC_STATE="$test_root/tc.state"
export LYTE_NETEM_STATE_DIR="$test_root/netem-state"
touch "$LYTE_FAKE_TC_LOG"
printf '%s\n' default > "$LYTE_FAKE_TC_STATE"

"$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null
[[ "$(<"$LYTE_FAKE_TC_STATE")" == owned ]]
grep -Fq "qdisc replace dev en-test0 root handle 1a7e: prio" \
    "$LYTE_FAKE_TC_LOG"
grep -Fq "parent 1a7e:1 handle 1a70: fq_codel" "$LYTE_FAKE_TC_LOG"
grep -Fq "match ip sport 41151 0xffff" "$LYTE_FAKE_TC_LOG"
grep -Fq "match ip dst 10.0.0.44/32" "$LYTE_FAKE_TC_LOG"

"$netem" remove en-test0 >/dev/null
[[ "$(<"$LYTE_FAKE_TC_STATE")" == default ]]
"$netem" remove en-test0 >/dev/null

"$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null
printf '%s\n' owned-changed > "$LYTE_FAKE_TC_STATE"
if "$netem" remove en-test0 >/dev/null 2>&1; then
    echo "changed owned topology was removed" >&2
    exit 1
fi
printf '%s\n' owned > "$LYTE_FAKE_TC_STATE"
"$netem" remove en-test0 >/dev/null

printf '%s\n' foreign > "$LYTE_FAKE_TC_STATE"
if "$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null 2>&1; then
    echo "foreign qdisc was not refused" >&2
    exit 1
fi
[[ "$(<"$LYTE_FAKE_TC_STATE")" == foreign ]]

printf '%s\n' default > "$LYTE_FAKE_TC_STATE"
export LYTE_FAKE_TC_FAIL_CONTAINS="filter add dev"
if "$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null 2>&1; then
    echo "injected partial-apply failure was ignored" >&2
    exit 1
fi
unset LYTE_FAKE_TC_FAIL_CONTAINS
[[ "$(<"$LYTE_FAKE_TC_STATE")" == default ]]

if "$netem" apply 'en0;touch-bad' 10.0.0.44 41151 20 10 1 \
    >/dev/null 2>&1
then
    echo "invalid interface was accepted" >&2
    exit 1
fi
if "$netem" apply en-test0 10.0.0.999 41151 20 10 1 \
    >/dev/null 2>&1
then
    echo "invalid IPv4 address was accepted" >&2
    exit 1
fi
if "$netem" apply en-test0 10.0.0.44 70000 20 10 1 \
    >/dev/null 2>&1
then
    echo "invalid source port was accepted" >&2
    exit 1
fi

bash -n "$benchmark" "$benchmark_netem" "$pup_gate"
sh -n "$benchmark_process"
sh -n "$netem" "$build_cli" "$make_app"

# User-facing artifacts stay in the repository-root .build directory. The
# deterministic test gate deliberately does not: SwiftPM `clean` owns its
# whole scratch root, while `.build/Lyte.app` may be the owner's live app.
grep -Fq -- '--package-path Client' "$build_cli"
grep -Fq -- '--scratch-path .build' "$build_cli"
grep -Fq -- '--package-path Client' "$make_app"
grep -Fq -- '--scratch-path .build' "$make_app"
grep -Fq 'Client/Package.swift Client/Package.resolved Client/Sources' \
    "$make_app"
grep -Fq 'Client/Package.swift Client/Package.resolved Client/Sources' \
    "$benchmark"
grep -Fq 'run_package_tests "client" "$repo_root/Client" "$repo_root/Client/.build"' \
    "$macos_gate"
if grep -Fq 'case .notRegistered, .notFound:' \
    "$repo_root/Client/Sources/Lyte/HelperClient.swift"
then
    echo "missing helper regained unsafe SMAppService registration" >&2
    exit 1
fi
[[ "$(grep -Fc 'registerIfNeeded()' \
    "$repo_root/Client/Sources/Lyte/HelperClient.swift")" -eq 1 ]]
grep -Fq '"SystemTests" "$repo_root/SystemTests" "$repo_root/SystemTests/.build"' \
    "$macos_gate"
grep -Fq 'rsync -a --delete --exclude .build Client/' "$pup_gate"
grep -Fq 'SystemTests/ "$pup:$pup_gate_root/SystemTests/"' "$pup_gate"
grep -Fq 'command -v findmnt' "$pup_gate"
grep -Fq 'refuse_mounts_below "$namespace"' "$pup_gate"
grep -Fq 'find "$directory" -xdev -depth -delete' "$pup_gate"
if grep -Fq 'rm -rf -- "$gate_root/Sources"' "$pup_gate"; then
    echo "pup gate regained an unconstrained recursive delete" >&2
    exit 1
fi
grep -Fq 'Scripts/build-cli.sh debug' "$vscode_tasks"
grep -Fq 'Scripts/build-cli.sh release' "$vscode_tasks"
grep -Fq 'Scripts/make-app.sh debug' "$vscode_tasks"
grep -Fq 'Scripts/make-app.sh release' "$vscode_tasks"
grep -Fq '.build/Lyte.app/Contents/MacOS/Lyte' "$vscode_launch"
grep -Fq '.build/Lyte.app/Contents/MacOS/lyte-helperd' "$vscode_launch"

if grep -Fq 'lyte-loop.sh' "$benchmark" \
    || grep -Eq 'kill -(STOP|CONT)|kill -9.*standing' "$benchmark"
then
    echo "handshake-only regained retired process supervision" >&2
    exit 1
fi
grep -Fq 'refuse_if_lyte_is_running' "$benchmark"
if grep -Eq 'FALLBACK_APP_PID|pgrep -n' "$benchmark"; then
    echo "benchmark regained fallback PID guessing" >&2
    exit 1
fi
if grep -Fq 'trap cleanup EXIT INT TERM' "$benchmark"; then
    echo "benchmark regained a reentrant signal trap" >&2
    exit 1
fi
grep -Fq 'trap cleanup EXIT' "$benchmark"
grep -Fq "trap 'handle_signal 130' INT" "$benchmark"
grep -Fq "trap 'handle_signal 143' TERM" "$benchmark"
grep -Fq 'DiagnosticRunIdentity.publishIfRequested()' \
    "$repo_root/Client/Sources/Lyte/LyteApp.swift"
grep -Fq 'guard !DiagnosticRunIdentity.isRequested else { return }' \
    "$repo_root/Client/Sources/Lyte/LyteApp.swift"
grep -Fq 'registration: helperRegistration' \
    "$repo_root/Client/Sources/Lyte/AgentMenu.swift"
grep -Fq 'registration: self.helperRegistration' \
    "$repo_root/Client/Sources/Lyte/AgentMenu.swift"
grep -Fq 'case existingOnly' \
    "$repo_root/Client/Sources/Lyte/HelperClient.swift"
if grep -Fq 'LYTE_BENCHMARK_PIDFILE' \
    "$repo_root/Client/Sources/Lyte/DiagnosticBenchmark.swift"
then
    echo "benchmark driver regained late PID publication" >&2
    exit 1
fi

# Exercise the exact signal edge with real processes. A stale or forged PID
# must survive; only a process whose executable and run argument both match
# may be terminated.
fake_app="$test_root/Lyte.app/Contents/MacOS/Lyte"
mkdir -p "$(dirname "$fake_app")"
cat > "$test_root/stay.c" <<'EOF'
#include <signal.h>
#include <unistd.h>
int main(void) {
    for (;;) pause();
}
EOF
cc "$test_root/stay.c" -o "$fake_app"
"$fake_app" ordinary >/dev/null &
ordinary_pid=$!
"$fake_app" --lyte-benchmark-run-id exact-run >/dev/null &
claimed_pid=$!

for _ in {1..100}; do
    kill -0 "$ordinary_pid" 2>/dev/null \
        && kill -0 "$claimed_pid" 2>/dev/null && break
    sleep 0.01
done
! lyte_benchmark_claim_matches "$ordinary_pid" "$fake_app" exact-run
claim_file="$test_root/benchmark.pid"
printf '%s %s\n' "$ordinary_pid" exact-run > "$claim_file"
! lyte_benchmark_terminate_claimed \
    "$claim_file" "$ordinary_pid" "$fake_app" exact-run
kill -0 "$ordinary_pid"
printf '%s %s\n' 999999 exact-run > "$claim_file"
! lyte_benchmark_terminate_claimed \
    "$claim_file" 999999 "$fake_app" exact-run
lyte_benchmark_claim_matches "$claimed_pid" "$fake_app" exact-run
printf '%s %s %s\n' "$claimed_pid" exact-run forged > "$claim_file"
! lyte_benchmark_terminate_claimed \
    "$claim_file" "$claimed_pid" "$fake_app" exact-run
kill -0 "$claimed_pid"
printf '%s %s\n' "$claimed_pid" wrong-run > "$claim_file"
! lyte_benchmark_terminate_claimed \
    "$claim_file" "$claimed_pid" "$fake_app" exact-run
kill -0 "$claimed_pid"
printf '%s %s\n' "$claimed_pid" exact-run > "$claim_file"
lyte_benchmark_terminate_claimed \
    "$claim_file" "$claimed_pid" "$fake_app" exact-run
wait "$claimed_pid" 2>/dev/null || true
! kill -0 "$claimed_pid" 2>/dev/null
claimed_pid=""
kill "$ordinary_pid"
wait "$ordinary_pid" 2>/dev/null || true
ordinary_pid=""
grep -Fq 'systemctl restart lyte-host' "$benchmark"
grep -Fq 'systemctl show lyte-host --property MainPID --value' "$benchmark"

if grep -Fq 'motion-pipeline' "$benchmark_netem" \
    || grep -Eq 'qdisc (add|replace).* root netem' "$benchmark_netem"
then
    echo "benchmark netem regained its stale or unscoped path" >&2
    exit 1
fi
grep -Fq -- '--no-build --out "$RUN_DIR" motion' "$benchmark_netem"
grep -Fq "match ip sport" "$netem"
grep -Fq "match ip dst" "$netem"

echo "benchmark safety tests PASSED"
