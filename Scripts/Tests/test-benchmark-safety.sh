#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
netem="$repo_root/Scripts/netem/port-netem.sh"
benchmark_netem="$repo_root/Scripts/benchmark-netem.sh"
fake_tc="$repo_root/Scripts/Tests/Fixtures/fake-tc.sh"
test_root="$(mktemp -d)"
# Physical, as make-app.sh canonicalizes its destination with pwd -P.
test_root="$(cd "$test_root" && pwd -P)"
ordinary_pid=""
claimed_pid=""
cleanup() {
    [[ -z "$ordinary_pid" ]] || kill "$ordinary_pid" 2>/dev/null || true
    [[ -z "$claimed_pid" ]] || kill "$claimed_pid" 2>/dev/null || true
    rm -rf "$test_root"
}
trap cleanup EXIT

source "$repo_root/Scripts/lib/assert.sh"
source "$repo_root/Scripts/lib/benchmark-process.sh"

# benchmark-app.sh and make-app.sh run hermetically from a private
# repository root (its Scripts/ is this checkout's, its .build bundles are
# fixtures, its Git history one empty commit): codesign, ssh, rsync and
# swift are fakes that stop the run and the pup destination cannot resolve,
# so a reordered preflight can never reach pup, a compiler, the owner's app
# or the owner's artifact lock.
fake_root="$test_root/repo"
mkdir -p "$fake_root/.build" "$test_root/bin"
ln -s "$repo_root/Scripts" "$fake_root/Scripts"
git -C "$fake_root" init -q
git -C "$fake_root" -c user.name=fixture -c user.email=fixture@invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m fixture
for tool in codesign ssh rsync swift; do
    printf '#!/bin/sh\necho "fake %s reached: $*" >&2\nexit 73\n' "$tool" \
        > "$test_root/bin/$tool"
    chmod +x "$test_root/bin/$tool"
done
everyday_app="$fake_root/.build/Lyte.app"
diagnostic_app="$fake_root/.build/Lyte-diagnostic.app"
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
# run_benchmark NAME ARG...: one --no-build run with output under NAME.
run_benchmark() {
    local name="$1"
    shift
    env -u PUP -u LYTE_BENCHMARK_PUP \
        PATH="$test_root/bin:$PATH" \
        LYTE_PUP_HOST=fake-pup.invalid \
        LYTE_PGREP="$fake_pgrep" \
        "$fake_root/Scripts/benchmark-app.sh" --no-build \
        --out "$test_root/$name-output" "$@" \
        >"$test_root/$name.stdout" 2>"$test_root/$name.stderr"
}
# fixture_app DIAGNOSTICS [APP]: a bundle (default: the benchmark's
# diagnostic path) whose Info.plist enables the diagnostic entry points when
# DIAGNOSTICS=1.
fixture_app() {
    local app="${2:-$diagnostic_app}" key=""
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    printf '#!/bin/sh\n' > "$app/Contents/MacOS/Lyte"
    printf '#!/bin/sh\n' > "$app/Contents/MacOS/lyte-helperd"
    chmod +x "$app/Contents/MacOS/Lyte" "$app/Contents/MacOS/lyte-helperd"
    if [[ "$1" == 1 ]]; then
        key='<key>LyteDiagnosticEntryPoints</key><true/>'
    fi
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<plist version="1.0"><dict>' \
        '<key>CFBundleVersion</key><string>1</string>' "$key" \
        '</dict></plist>' \
        > "$app/Contents/Info.plist"
}

# The owner guard runs before output creation, builds, or any pup operation,
# and an unreadable process table fails closed.
if LYTE_FAKE_PGREP_RESULT=match run_benchmark blocked handshake-only; then
    fail "benchmark ignored an active Lyte process"
fi
[[ ! -e "$test_root/blocked-output" ]] \
    || fail "a refused benchmark created its output"
grep -Fq 'PID(s): 4242' "$test_root/blocked.stderr"

if LYTE_FAKE_PGREP_RESULT=error run_benchmark error handshake-only; then
    fail "benchmark trusted an unreadable process table"
fi
[[ ! -e "$test_root/error-output" ]] \
    || fail "a refused benchmark created its output"
grep -Fq 'cannot inspect running Lyte processes' "$test_root/error.stderr"

# An empty process table admits the run; without an app it stops there.
if LYTE_FAKE_PGREP_RESULT=empty run_benchmark missing handshake-only; then
    fail "benchmark passed without a built app"
fi
[[ -d "$test_root/missing-output" ]] \
    || fail "an admitted benchmark created no output"
grep -Fq 'missing signed diagnostic app' "$test_root/missing.stderr"

# A bundle without the diagnostic entry points would ignore the benchmark
# environment: refused before signing checks, the lock or pup.
fixture_app 0
if LYTE_FAKE_PGREP_RESULT=empty run_benchmark plain handshake-only; then
    fail "benchmark accepted a non-diagnostic app"
fi
grep -Fq 'is not a diagnostic build' "$test_root/plain.stderr"
refute grep -Fq 'fake codesign reached' "$test_root/plain.stderr"

# A diagnostic bundle proceeds to its signature check.
fixture_app 1
if LYTE_FAKE_PGREP_RESULT=empty run_benchmark diagnostic handshake-only; then
    fail "benchmark passed a fake-signed app"
fi
grep -Fq 'fake codesign reached' "$test_root/diagnostic.stderr"

# The everyday bundle is never the benchmark's, even when it is a
# diagnostic build: without the benchmark's own bundle the run stops.
rm -rf "$diagnostic_app"
fixture_app 1 "$everyday_app"
if LYTE_FAKE_PGREP_RESULT=empty run_benchmark everyday handshake-only; then
    fail "benchmark ran the everyday app"
fi
grep -Fq 'missing signed diagnostic app' "$test_root/everyday.stderr"
refute grep -Fq 'fake codesign reached' "$test_root/everyday.stderr"

# make_app NAME [VAR=VALUE...] -- ARG...: one make-app.sh run in the
# private root; the fake swift ends it at the first compile.
make_app() {
    local name="$1"
    shift
    local assignments=()
    while [[ "$1" != -- ]]; do assignments+=("$1"); shift; done
    shift
    env -u LYTE_APP_DESTINATION -u LYTE_APP_DIAGNOSTICS \
        PATH="$test_root/bin:$PATH" LYTE_PGREP="$fake_pgrep" \
        LYTE_FAKE_PGREP_RESULT=empty ${assignments[@]+"${assignments[@]}"} \
        "$fake_root/Scripts/make-app.sh" "$@" \
        >"$test_root/$name.stdout" 2>"$test_root/$name.stderr"
}
fixture_app 0 "$everyday_app"
everyday_plist="$(shasum -a 256 "$everyday_app/Contents/Info.plist")"

# A diagnostic build aimed at the everyday bundle is refused before any
# compile, and the everyday bundle is untouched.
if make_app diagnostic-live -- --diagnostics release; then
    fail "make-app built a diagnostic bundle at .build/Lyte.app"
fi
grep -Fq 'a diagnostic bundle is never published at' \
    "$test_root/diagnostic-live.stderr"
refute grep -Fq 'fake swift reached' "$test_root/diagnostic-live.stderr"

# An exported LYTE_APP_DIAGNOSTICS=1 (the owner's shell, the macOS gate)
# selects nothing: the everyday build proceeds as a plain build.
if make_app inherited LYTE_APP_DIAGNOSTICS=1 -- release; then
    fail "make-app finished without a compiler"
fi
refute grep -Fq 'never published at' "$test_root/inherited.stderr"
grep -Fq 'ignores LYTE_APP_DIAGNOSTICS' "$test_root/inherited.stderr"
grep -Fq 'fake swift reached' "$test_root/inherited.stderr"

if make_app bad-flag -- --diagnostic release; then
    fail "make-app accepted an unknown flag"
fi
grep -Fq 'usage: Scripts/make-app.sh' "$test_root/bad-flag.stderr"

# The benchmark builds its own bundle: make-app accepts its destination
# (it would refuse the everyday one) and reaches the compiler.
rm -rf "$diagnostic_app"
if env -u PUP -u LYTE_BENCHMARK_PUP -u LYTE_APP_DESTINATION \
    PATH="$test_root/bin:$PATH" LYTE_PUP_HOST=fake-pup.invalid \
    LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=empty \
    "$fake_root/Scripts/benchmark-app.sh" --out "$test_root/build-output" \
    handshake-only >"$test_root/build.stdout" 2>"$test_root/build.stderr"
then
    fail "benchmark finished without a compiler"
fi
refute grep -Fq 'never published at' "$test_root/build.stderr"
grep -Fq 'fake swift reached' "$test_root/build.stderr"
[[ "$(shasum -a 256 "$everyday_app/Contents/Info.plist")" == "$everyday_plist" ]] \
    || fail "a diagnostic build rewrote the everyday bundle"

# The packaging gate knows which kind of app it checks: the gate's plain
# app with diagnostic entry points fails, and so does a diagnostic app
# without them. A matching fixture passes that check and stops later, at
# its missing license resources.
packaging="$repo_root/Scripts/Tests/test-app-packaging.sh"
fixture_app 1 "$test_root/plain-with-key.app"
if "$packaging" "$test_root/plain-with-key.app" \
    >/dev/null 2>"$test_root/packaging-key.stderr"; then
    fail "the packaging gate passed a plain app with diagnostic entry points"
fi
grep -Fq 'a plain app carries LyteDiagnosticEntryPoints' \
    "$test_root/packaging-key.stderr"
fixture_app 0 "$test_root/diagnostic-without-key.app"
if "$packaging" --diagnostics "$test_root/diagnostic-without-key.app" \
    >/dev/null 2>"$test_root/packaging-nokey.stderr"; then
    fail "the packaging gate passed a diagnostic app without its entry points"
fi
grep -Fq 'a diagnostic app lacks LyteDiagnosticEntryPoints' \
    "$test_root/packaging-nokey.stderr"
if "$packaging" --plain "$test_root/diagnostic-without-key.app" \
    >/dev/null 2>"$test_root/packaging-plain.stderr"; then
    fail "the packaging gate passed an unpackaged fixture"
fi
grep -Fq 'missing Opus-COPYING.txt' "$test_root/packaging-plain.stderr"

export LYTE_TC="$fake_tc"
export LYTE_FAKE_TC_LOG="$test_root/tc.log"
export LYTE_FAKE_TC_STATE="$test_root/tc.state"
export LYTE_NETEM_STATE_DIR="$test_root/netem-state"
touch "$LYTE_FAKE_TC_LOG"
printf '%s\n' default > "$LYTE_FAKE_TC_STATE"
# expect_tc STATE: the fake qdisc topology is STATE.
expect_tc() {
    [[ "$(<"$LYTE_FAKE_TC_STATE")" == "$1" ]] \
        || fail "qdisc state is $(<"$LYTE_FAKE_TC_STATE"); want $1"
}

"$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null
expect_tc owned
grep -Fq "qdisc replace dev en-test0 root handle 1a7e: prio" \
    "$LYTE_FAKE_TC_LOG"
grep -Fq "parent 1a7e:1 handle 1a70: fq_codel" "$LYTE_FAKE_TC_LOG"
grep -Fq "match ip sport 41151 0xffff" "$LYTE_FAKE_TC_LOG"
grep -Fq "match ip dst 10.0.0.44/32" "$LYTE_FAKE_TC_LOG"

"$netem" remove en-test0 >/dev/null
expect_tc default
"$netem" remove en-test0 >/dev/null

"$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null
printf '%s\n' owned-changed > "$LYTE_FAKE_TC_STATE"
if "$netem" remove en-test0 >/dev/null 2>&1; then
    fail "changed owned topology was removed"
fi
printf '%s\n' owned > "$LYTE_FAKE_TC_STATE"
"$netem" remove en-test0 >/dev/null

printf '%s\n' foreign > "$LYTE_FAKE_TC_STATE"
if "$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null 2>&1; then
    fail "foreign qdisc was not refused"
fi
expect_tc foreign

printf '%s\n' default > "$LYTE_FAKE_TC_STATE"
export LYTE_FAKE_TC_FAIL_CONTAINS="filter add dev"
if "$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null 2>&1; then
    fail "injected partial-apply failure was ignored"
fi
unset LYTE_FAKE_TC_FAIL_CONTAINS
expect_tc default

if "$netem" apply 'en0;touch-bad' 10.0.0.44 41151 20 10 1 \
    >/dev/null 2>&1
then
    fail "invalid interface was accepted"
fi
if "$netem" apply en-test0 10.0.0.999 41151 20 10 1 \
    >/dev/null 2>&1
then
    fail "invalid IPv4 address was accepted"
fi
if "$netem" apply en-test0 10.0.0.44 70000 20 10 1 \
    >/dev/null 2>&1
then
    fail "invalid source port was accepted"
fi

# Exercise the exact signal edge with real processes. A stale or forged PID
# must survive; only a process whose executable and run argument both match
# may be terminated. The fakes are orphaned so launchd reaps them: a killed
# child of this shell would linger as a zombie and still answer `kill -0`.
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
ordinary_pid="$("$fake_app" ordinary >/dev/null 2>&1 & echo $!)"
claimed_pid="$(
    "$fake_app" --lyte-benchmark-run-id exact-run >/dev/null 2>&1 & echo $!
)"
# survives PID: PID is still running 200 ms from now.
survives() {
    local _
    for _ in {1..20}; do
        kill -0 "$1" 2>/dev/null || fail "PID $1 was terminated"
        sleep 0.01
    done
}
# ends PID: PID exits within 2 s.
ends() {
    local _
    for _ in {1..200}; do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 0.01
    done
    fail "PID $1 survived its termination"
}
for _ in {1..100}; do
    kill -0 "$ordinary_pid" 2>/dev/null \
        && kill -0 "$claimed_pid" 2>/dev/null && break
    sleep 0.01
done
refute lyte_benchmark_claim_matches "$ordinary_pid" "$fake_app" exact-run
claim_file="$test_root/benchmark.pid"
printf '%s %s\n' "$ordinary_pid" exact-run > "$claim_file"
refute lyte_benchmark_terminate_claimed \
    "$claim_file" "$ordinary_pid" "$fake_app" exact-run
survives "$ordinary_pid"
printf '%s %s\n' 999999 exact-run > "$claim_file"
refute lyte_benchmark_terminate_claimed \
    "$claim_file" 999999 "$fake_app" exact-run
lyte_benchmark_claim_matches "$claimed_pid" "$fake_app" exact-run
printf '%s %s %s\n' "$claimed_pid" exact-run forged > "$claim_file"
refute lyte_benchmark_terminate_claimed \
    "$claim_file" "$claimed_pid" "$fake_app" exact-run
survives "$claimed_pid"
printf '%s %s\n' "$claimed_pid" wrong-run > "$claim_file"
refute lyte_benchmark_terminate_claimed \
    "$claim_file" "$claimed_pid" "$fake_app" exact-run
survives "$claimed_pid"
printf '%s %s\n' "$claimed_pid" exact-run > "$claim_file"
lyte_benchmark_terminate_claimed \
    "$claim_file" "$claimed_pid" "$fake_app" exact-run
ends "$claimed_pid"
claimed_pid=""
kill "$ordinary_pid"
ends "$ordinary_pid"
ordinary_pid=""

# benchmark-netem runs against a simulated pup: ssh executes the remote
# command locally, with tc/ip/systemctl/ss/sudo replaced by fakes, and the
# real port-netem.sh driving the fake tc. Nothing leaves this machine. The
# caller's benchmark environment is cleared so a unit test can never reach a
# real host.
netem_env=(env -u LYTE_BENCHMARK_PORT -u LYTE_BENCHMARK_ALLOW_STANDING_PORT
    -u PUP -u LYTE_BENCHMARK_PUP -u LYTE_BENCHMARK_HOST
    LYTE_PUP_HOST=fake-pup.invalid)
fake_pup="$test_root/fake-pup"
mkdir -p "$fake_pup"
ln -s "$fake_tc" "$fake_pup/tc"
cat > "$fake_pup/ssh" <<'EOF'
#!/bin/bash
# Simulated pup: drop ssh options and the destination, run the command here.
while [[ "$1" == -o ]]; do shift 2; done
shift
command="$*"
printf '%s\n' "$command" >> "$FAKE_SSH_LOG"
if [[ "$command" == *" apply "* ]]; then
    sh -c "$command"
    status=$?
    case "${FAKE_SSH_AFTER_APPLY:-ok}" in
        drop) exit 255 ;;
        hang) echo $$ > "$FAKE_SSH_HANG_PID"; while :; do sleep 0.05; done ;;
    esac
    exit "$status"
fi
exec sh -c "$command"
EOF
cat > "$fake_pup/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -n ] && shift
exec "$@"
EOF
cat > "$fake_pup/rsync" <<'EOF'
#!/bin/sh
eval "last=\${$#}"
cp "$(eval "echo \${$(($# - 1))}")" "${last#*:}"
EOF
cat > "$fake_pup/route" <<'EOF'
#!/bin/sh
echo "  interface: en-fake"
EOF
cat > "$fake_pup/ipconfig" <<'EOF'
#!/bin/sh
echo 10.0.0.44
EOF
cat > "$fake_pup/ip" <<'EOF'
#!/bin/sh
echo "10.0.0.44 dev en-test0 src 10.0.0.232 uid 1000"
EOF
cat > "$fake_pup/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
    is-active) exit 0 ;;
    show) echo 4242 ;;
esac
EOF
cat > "$fake_pup/ss" <<'EOF'
#!/bin/sh
case "$*" in
    *":$FAKE_OWNED_PORT'"*|*":$FAKE_OWNED_PORT") echo "UNCONN 0 0 *:$FAKE_OWNED_PORT *:* users:((\"lyte-host\",pid=4242,fd=3))" ;;
esac
EOF
chmod +x "$fake_pup"/*

refute_logged() {
    if grep -Fq -- "$1" "$test_root/ssh.log"; then
        fail "benchmark-netem unexpectedly ran: $1"
    fi
}
run_netem() {
    : > "$test_root/ssh.log"
    "${netem_env[@]}" PATH="$fake_pup:$PATH" \
        FAKE_SSH_LOG="$test_root/ssh.log" \
        FAKE_SSH_HANG_PID="$test_root/ssh.pid" \
        FAKE_OWNED_PORT="${FAKE_OWNED_PORT:-41151}" \
        LYTE_BENCHMARK_OUT_DIR="$test_root/netem-runs" \
        "$@" "$benchmark_netem" moderate \
        >"$test_root/netem.stdout" 2>"$test_root/netem.stderr"
}
printf '%s\n' default > "$LYTE_FAKE_TC_STATE"
: > "$LYTE_FAKE_TC_LOG"

if run_netem; then
    fail "benchmark-netem accepted a missing LYTE_BENCHMARK_PORT"
fi
if run_netem LYTE_BENCHMARK_PORT=41151; then
    fail "benchmark-netem accepted standing 41151 without allow flag"
fi
if run_netem PUP=elsewhere LYTE_BENCHMARK_PORT=41151 \
    LYTE_BENCHMARK_ALLOW_STANDING_PORT=1
then
    fail "benchmark-netem accepted a retired pup variable"
fi
grep -Fq 'set LYTE_PUP_HOST instead' "$test_root/netem.stderr"

# A port the standing service does not own would be impaired while the
# benchmark measured clean air: refused before any qdisc change.
if FAKE_OWNED_PORT=41151 run_netem LYTE_BENCHMARK_PORT=41999; then
    fail "benchmark-netem impaired a port lyte-host does not own"
fi
grep -Fq 'does not own UDP 41999' "$test_root/netem.stderr"
refute_logged ' apply '
expect_tc default

# The ssh link drops after pup applied the qdisc: cleanup still removes it.
if run_netem LYTE_BENCHMARK_PORT=41151 LYTE_BENCHMARK_ALLOW_STANDING_PORT=1 \
    FAKE_SSH_AFTER_APPLY=drop
then
    fail "benchmark-netem ignored a failed apply"
fi
grep -Fq "apply 'en-test0' '10.0.0.44' '41151' '20' '10' '1'" "$test_root/ssh.log"
grep -Fq "remove 'en-test0'" "$test_root/ssh.log"
expect_tc default

# A signal during the run removes the qdisc and exits 128+signal.
rm -f "$test_root/ssh.pid"
run_netem LYTE_BENCHMARK_PORT=41151 LYTE_BENCHMARK_ALLOW_STANDING_PORT=1 \
    FAKE_SSH_AFTER_APPLY=hang &
netem_pid=$!
for _ in {1..200}; do
    [[ -s "$test_root/ssh.pid" ]] && break
    sleep 0.05
done
[[ -s "$test_root/ssh.pid" ]] || fail "the simulated apply never started"
expect_tc owned
netem_script_pid="$(pgrep -P "$netem_pid" -f benchmark-netem.sh || echo "$netem_pid")"
kill -TERM "$netem_script_pid"
kill "$(<"$test_root/ssh.pid")"
netem_status=0
wait "$netem_pid" || netem_status=$?
[[ "$netem_status" -eq 143 ]] \
    || fail "benchmark-netem exited $netem_status on TERM; want 143"
grep -Fq "remove 'en-test0'" "$test_root/ssh.log"
expect_tc default

# A stranded helper qdisc from an earlier run is never adopted or stacked.
printf '%s\n' owned > "$LYTE_FAKE_TC_STATE"
if run_netem LYTE_BENCHMARK_PORT=41151 LYTE_BENCHMARK_ALLOW_STANDING_PORT=1; then
    fail "benchmark-netem ran over an existing port-netem qdisc"
fi
refute_logged ' apply '
refute_logged ' remove '
printf '%s\n' default > "$LYTE_FAKE_TC_STATE"

echo "benchmark safety tests PASSED"
