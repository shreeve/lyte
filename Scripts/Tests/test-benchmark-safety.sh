#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
netem="$repo_root/Scripts/netem/port-netem.sh"
benchmark="$repo_root/Scripts/benchmark-app.sh"
benchmark_netem="$repo_root/Scripts/benchmark-netem.sh"
build_cli="$repo_root/Scripts/build-cli.sh"
make_app="$repo_root/Scripts/make-app.sh"
macos_gate="$repo_root/Scripts/CI/test-all-macos.sh"
pup_gate="$repo_root/Scripts/CI/test-all-pup.sh"
vscode_launch="$repo_root/.vscode/launch.json"
vscode_tasks="$repo_root/.vscode/tasks.json"
fake_tc="$repo_root/Scripts/Tests/Fixtures/fake-tc.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

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

bash -n "$benchmark" "$benchmark_netem"
sh -n "$netem" "$build_cli" "$make_app"

# The Client package lives under Client/, but every user-facing artifact stays
# in the repository-root .build directory. Keep build, provenance, and both
# deterministic gates on that same contract.
grep -Fq -- '--package-path Client' "$build_cli"
grep -Fq -- '--scratch-path .build' "$build_cli"
grep -Fq -- '--package-path Client' "$make_app"
grep -Fq -- '--scratch-path .build' "$make_app"
grep -Fq 'Client/Package.swift Client/Package.resolved Client/Sources' \
    "$make_app"
grep -Fq 'Client/Package.swift Client/Package.resolved Client/Sources' \
    "$benchmark"
grep -Fq 'run_package_tests "client" "$repo_root/Client" "$repo_root/.build"' \
    "$macos_gate"
grep -Fq 'rsync -a --delete --exclude .build Client/' "$pup_gate"
grep -Fq 'refuse_mounts_below' "$pup_gate"
grep -Fq 'findmnt -rn -o TARGET' "$pup_gate"
grep -Fq 'find "$directory" -xdev -depth -delete' "$pup_gate"
if grep -Fq 'rm -rf -- "$gate_root/Sources"' "$pup_gate"; then
    echo "pup gate regained an unbounded root-client deletion" >&2
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
