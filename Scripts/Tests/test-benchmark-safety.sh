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
# repository root (its Scripts/ is this checkout's, its .build bundle a
# fixture, its Git history one empty commit): codesign, ssh, rsync, swift
# and the benchmark's make-app are fakes that stop the run, and the pup
# destination cannot resolve, so a reordered preflight can never reach pup,
# a compiler, the owner's app or the owner's artifact lock.
fake_root="$test_root/repo"
mkdir -p "$fake_root/.build" "$test_root/bin"
ln -s "$repo_root/Scripts" "$fake_root/Scripts"
git -C "$fake_root" init -q
git -C "$fake_root" -c user.name=fixture -c user.email=fixture@invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m fixture
for tool in ssh rsync swift; do
    printf '#!/bin/sh\necho "fake %s reached: $*" >&2\nexit 73\n' "$tool" \
        > "$test_root/bin/$tool"
    chmod +x "$test_root/bin/$tool"
done
# codesign stops the run; with FAKE_CODESIGN_HANG it waits there instead
# (recording its PID) so a test can interrupt a run that built the app.
cat > "$test_root/bin/codesign" <<'EOF'
#!/bin/sh
echo "fake codesign reached: $*" >&2
if [ -n "${FAKE_CODESIGN_HANG:-}" ]; then
    echo $$ > "$FAKE_CODESIGN_HANG"
    while :; do sleep 0.05; done
fi
exit 73
EOF
chmod +x "$test_root/bin/codesign"
everyday_app="$fake_root/.build/Lyte.app"
# The benchmark's make-app: logs its arguments, requires the default
# destination and a free app-artifact lock (the real one does both), then
# publishes a plain or diagnostic fixture at .build/Lyte.app. A plain build
# fails when FAKE_RESTORE=fail.
make_app_log="$test_root/make-app.log"
: > "$make_app_log"
fake_make_app="$test_root/fake-make-app"
cat > "$fake_make_app" <<'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$FAKE_MAKE_APP_LOG"
[[ -z "${LYTE_APP_DESTINATION:-}" ]] || { echo "destination set" >&2; exit 76; }
exec 8>"$PWD/.build/.lyte-app-artifact.lock"
lockf -s -t 0 8 || { echo lock-held >> "$FAKE_MAKE_APP_LOG"; exit 75; }
key=""
if [[ "$1" == --diagnostics ]]; then
    key='<key>LyteDiagnosticEntryPoints</key><true/>'
elif [[ "${FAKE_RESTORE:-ok}" == fail ]]; then
    echo "fake make-app: plain build failed" >&2
    exit 1
fi
app="$PWD/.build/Lyte.app"
mkdir -p "$app/Contents/MacOS"
printf '#!/bin/sh\n' > "$app/Contents/MacOS/Lyte"
chmod +x "$app/Contents/MacOS/Lyte"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' "$key" '</dict></plist>' \
    > "$app/Contents/Info.plist"
EOF
chmod +x "$fake_make_app"
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
        LYTE_MAKE_APP="$fake_make_app" FAKE_MAKE_APP_LOG="$make_app_log" \
        "$fake_root/Scripts/benchmark-app.sh" --no-build \
        --out "$test_root/$name-output" "$@" \
        >"$test_root/$name.stdout" 2>"$test_root/$name.stderr"
}
# fixture_app DIAGNOSTICS [APP]: a bundle (default: the everyday
# .build/Lyte.app) whose Info.plist enables the diagnostic entry points when
# DIAGNOSTICS=1.
fixture_app() {
    local app="${2:-$everyday_app}" key=""
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
grep -Fq 'missing signed app' "$test_root/missing.stderr"

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

# Nothing above built, so nothing was restored.
[[ ! -s "$make_app_log" ]] || fail "a --no-build run ran make-app"

# plist_is_diagnostic APP: the bundle enables the diagnostic entry points.
plist_is_diagnostic() {
    local value
    value="$(plutil -extract LyteDiagnosticEntryPoints raw \
        -o - "$1/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$value" == true ]] || return 1
}
# build_benchmark NAME [VAR=VALUE...]: one building run (fake make-app) that
# stops at codesign, or waits there under FAKE_CODESIGN_HANG.
build_benchmark() {
    local name="$1"
    shift
    : > "$make_app_log"
    env -u PUP -u LYTE_BENCHMARK_PUP -u LYTE_APP_DESTINATION \
        PATH="$test_root/bin:$PATH" LYTE_PUP_HOST=fake-pup.invalid \
        LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=empty \
        LYTE_MAKE_APP="$fake_make_app" FAKE_MAKE_APP_LOG="$make_app_log" \
        "$@" "$fake_root/Scripts/benchmark-app.sh" \
        --out "$test_root/$name-output" handshake-only \
        >"$test_root/$name.stdout" 2>"$test_root/$name.stderr"
}

# A building run makes the one .build/Lyte.app a diagnostic build, and its
# exit restores the plain build — after releasing the artifact lock it took.
fixture_app 0
if build_benchmark restored; then
    fail "benchmark passed a fake-signed app"
fi
grep -Fq 'fake codesign reached' "$test_root/restored.stderr"
[[ "$(<"$make_app_log")" == $'--diagnostics release\nrelease' ]] \
    || fail "make-app ran as: $(<"$make_app_log")"
refute plist_is_diagnostic "$everyday_app"
grep -Fq 'restoring the everyday app' "$test_root/restored.stderr"
refute grep -Fq 'WARNING' "$test_root/restored.stderr"

# An interrupted run restores too, and still exits 128+signal.
rm -f "$test_root/codesign.pid"
: > "$make_app_log"
# Backgrounded directly (not through the function) so $! is the benchmark.
env -u PUP -u LYTE_BENCHMARK_PUP -u LYTE_APP_DESTINATION \
    PATH="$test_root/bin:$PATH" LYTE_PUP_HOST=fake-pup.invalid \
    LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=empty \
    LYTE_MAKE_APP="$fake_make_app" FAKE_MAKE_APP_LOG="$make_app_log" \
    FAKE_CODESIGN_HANG="$test_root/codesign.pid" \
    "$fake_root/Scripts/benchmark-app.sh" \
    --out "$test_root/interrupted-output" handshake-only \
    >"$test_root/interrupted.stdout" 2>"$test_root/interrupted.stderr" &
benchmark_pid=$!
for _ in {1..200}; do
    [[ -s "$test_root/codesign.pid" ]] && break
    sleep 0.05
done
[[ -s "$test_root/codesign.pid" ]] || fail "the interrupted run never built"
plist_is_diagnostic "$everyday_app" \
    || fail "the running benchmark's app is not a diagnostic build"
kill -TERM "$benchmark_pid"
kill "$(<"$test_root/codesign.pid")"
benchmark_status=0
wait "$benchmark_pid" || benchmark_status=$?
[[ "$benchmark_status" -eq 143 ]] \
    || fail "an interrupted benchmark exited $benchmark_status; want 143"
[[ "$(<"$make_app_log")" == $'--diagnostics release\nrelease' ]] \
    || fail "an interrupted run's make-app ran as: $(<"$make_app_log")"
refute plist_is_diagnostic "$everyday_app"

# A restore that fails says so loudly, with the command that fixes it.
if build_benchmark unrestored FAKE_RESTORE=fail; then
    fail "benchmark passed a fake-signed app"
fi
plist_is_diagnostic "$everyday_app" || fail "the fake restore did not fail"
grep -Fq '.build/Lyte.app is STILL A DIAGNOSTIC BUILD' \
    "$test_root/unrestored.stderr"
grep -Fq 'Scripts/make-app.sh release' "$test_root/unrestored.stderr"
fixture_app 0

# make_app NAME [VAR=VALUE...] -- ARG...: one real make-app.sh run in the
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

# The diagnostic build publishes at the everyday .build/Lyte.app, the one
# physical copy: make-app proceeds to the compiler.
if make_app diagnostic-live -- --diagnostics release; then
    fail "make-app finished without a compiler"
fi
grep -Fq 'fake swift reached' "$test_root/diagnostic-live.stderr"

# An exported LYTE_APP_DIAGNOSTICS=1 (the owner's shell, the macOS gate)
# selects nothing, and says so.
if make_app inherited LYTE_APP_DIAGNOSTICS=1 -- release; then
    fail "make-app finished without a compiler"
fi
grep -Fq 'ignores LYTE_APP_DIAGNOSTICS' "$test_root/inherited.stderr"
grep -Fq 'fake swift reached' "$test_root/inherited.stderr"

if make_app bad-flag -- --diagnostic release; then
    fail "make-app accepted an unknown flag"
fi
grep -Fq 'usage: Scripts/make-app.sh' "$test_root/bad-flag.stderr"

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

for changed in owned-changed owned-without-netem; do
    "$netem" apply en-test0 10.0.0.44 41151 20 10 1 >/dev/null
    printf '%s\n' "$changed" > "$LYTE_FAKE_TC_STATE"
    if "$netem" remove en-test0 >/dev/null 2>&1; then
        fail "changed owned topology ($changed) was removed"
    fi
    printf '%s\n' owned > "$LYTE_FAKE_TC_STATE"
    "$netem" remove en-test0 >/dev/null
done

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

# benchmark-netem and the handshake leg run against a simulated pup: ssh
# executes the remote command locally, with tc/ip/systemctl/ss/sudo and the
# rest replaced by fakes, and the real port-netem.sh driving the fake tc.
# Nothing leaves this machine. The caller's benchmark environment is cleared
# so a unit test can never reach a real host.
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
printf '%s\n' "$*" >> "${FAKE_RSYNC_LOG:-/dev/null}"
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
# The service's MainPID is 4242, or $FAKE_PUP_STATE/pid; a restart moves it
# on and runs $FAKE_RESTART_HOOK.
cat > "$fake_pup/systemctl" <<'EOF'
#!/bin/sh
pid_file="${FAKE_PUP_STATE:-/nonexistent}/pid"
case "$1" in
    is-active) exit 0 ;;
    show) cat "$pid_file" 2>/dev/null || echo 4242 ;;
    restart)
        echo $(( $(cat "$pid_file") + 1 )) > "$pid_file"
        sh -c "${FAKE_RESTART_HOOK:-:}"
        ;;
esac
EOF
cat > "$fake_pup/ss" <<'EOF'
#!/bin/sh
pid=$(cat "${FAKE_PUP_STATE:-/nonexistent}/pid" 2>/dev/null || echo 4242)
case "$*" in
    *":$FAKE_OWNED_PORT") echo "UNCONN 0 0 *:$FAKE_OWNED_PORT *:* users:((\"lyte-host\",pid=$pid,fd=3))" ;;
esac
EOF
# /proc/PID/exe is whatever ~/.local/bin/lyte-host names; stat takes GNU -c.
cat > "$fake_pup/sha256sum" <<'EOF'
#!/bin/sh
[ $# -gt 0 ] || exec shasum -a 256
for file; do
    case "$file" in /proc/*/exe) file="$HOME/.local/bin/lyte-host" ;; esac
    shasum -a 256 "$file" || exit 1
done
EOF
cat > "$fake_pup/stat" <<'EOF'
#!/bin/sh
[ "$1" = -c ] || exec /usr/bin/stat "$@"
format=$(printf '%s' "$2" | sed 's/%n/%N/g; s/%a/%Lp/g; s/%U/%Su/g; s/%G/%Sg/g; s/%s/%z/g')
shift 2
exec /usr/bin/stat -f "$format" "$@"
EOF
# A capture logs its arguments and runs until killed; a read prints nothing.
cat > "$fake_pup/tcpdump" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_TCPDUMP_LOG:-/dev/null}"
case "$*" in *" -w "*) exec sleep 30 ;; esac
EOF
cat > "$fake_pup/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
printf '#!/bin/sh\necho "fake journal"\n' > "$fake_pup/journalctl"
chmod +x "$fake_pup"/*

# benchmark-netem runs from a private root whose impaired leg and analyzer
# are fakes: the leg writes a motion JSONL, the witnesses beside it, and the
# line naming the JSONL; the analyzer prints its arguments.
netem_root="$test_root/netem-repo"
mkdir -p "$netem_root/Scripts"
ln -s "$repo_root/Scripts/lib" "$repo_root/Scripts/netem" "$benchmark_netem" \
    "$netem_root/Scripts/"
cat > "$netem_root/Scripts/benchmark-app.sh" <<'EOF'
#!/bin/sh
out="$3"
for suffix in "" -client-handshake -client-pipeline-witness -motion-source; do
    : > "$out/motion-fake$suffix.jsonl"
done
echo "benchmark JSONL: $out/motion-fake.jsonl"
EOF
printf '%s\n' 'import json, sys' 'print(json.dumps(sys.argv[1:]))' \
    > "$netem_root/Scripts/analyze-app-benchmark.py"
chmod +x "$netem_root/Scripts/benchmark-app.sh"

refute_logged() {
    if grep -Fq -- "$1" "$test_root/ssh.log"; then
        fail "benchmark-netem unexpectedly ran: $1"
    fi
}
run_netem() {
    : > "$test_root/ssh.log"
    : > "$test_root/rsync.log"
    "${netem_env[@]}" PATH="$fake_pup:$PATH" \
        FAKE_SSH_LOG="$test_root/ssh.log" \
        FAKE_RSYNC_LOG="$test_root/rsync.log" \
        FAKE_SSH_HANG_PID="$test_root/ssh.pid" \
        FAKE_OWNED_PORT="${FAKE_OWNED_PORT:-41151}" \
        LYTE_BENCHMARK_OUT_DIR="$test_root/netem-runs" \
        "$@" "$netem_root/Scripts/benchmark-netem.sh" moderate \
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

# The handshake leg's host side against the simulated pup, whose HOME holds
# the protected state: the XDG and pre-XDG identity and the deployed link.
pup_home="$test_root/pup-home"
mkdir -p "$pup_home/.config/lyte" "$pup_home/.config/lyte-host" \
    "$pup_home/.local/bin" "$test_root/pup-state"
for file in lyte/noise_static.key lyte/paired_clients lyte/host.conf \
    lyte-host/noise_static.key lyte-host/paired_clients
do
    printf '%s\n' "$file" > "$pup_home/.config/$file"
done
printf 'deployed host\n' > "$test_root/lyte-host"
ln -s "$test_root/lyte-host" "$pup_home/.local/bin/lyte-host"
cat > "$test_root/handshake-leg.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$REPO_ROOT/Scripts/lib/pup.sh"
source "$REPO_ROOT/Scripts/lib/benchmark-handshake.sh"
PUP=fake-pup.invalid HOST=10.0.0.232 BENCH_PORT=41151 BENCH_SECONDS=1
OUT_DIR="$1"
trap collect_handshake_evidence EXIT
start_handshake_evidence "$2"
start_fresh_host "$2"
collect_handshake_evidence
finish_fresh_host "$2"
EOF
# run_handshake NAME [VAR=VALUE...]: one leg with its evidence under NAME.
run_handshake() {
    local name="$1"
    shift
    mkdir -p "$test_root/$name"
    printf '4242\n' > "$test_root/pup-state/pid"
    "${netem_env[@]}" HOME="$pup_home" PATH="$fake_pup:$PATH" \
        REPO_ROOT="$repo_root" FAKE_PUP_STATE="$test_root/pup-state" \
        FAKE_SSH_LOG="$test_root/ssh.log" FAKE_OWNED_PORT=41151 \
        FAKE_TCPDUMP_LOG="$test_root/$name/tcpdump.log" \
        "$@" "$BASH" "$test_root/handshake-leg.sh" "$test_root/$name" \
        "lyte-test-$$-$name" \
        >"$test_root/$name.stdout" 2>"$test_root/$name.stderr"
}

# The client capture listens on the interface that routes to the host, and
# the restart yields a fresh service process.
run_handshake handshake \
    || fail "the handshake leg failed: $(<"$test_root/handshake.stderr")"
grep -Fq -- '-i en-fake ' "$test_root/handshake/tcpdump.log" \
    || fail "the client capture ignored the route's interface"
pids="$(<"$test_root/handshake/lyte-test-$$-handshake.fresh-host.pids")"
[[ "$pids" == "4242 4243" ]] || fail "the restart recorded $pids"

# A restart that rewrites the pre-XDG identity copy fails the leg.
if run_handshake legacy-rewrite \
    FAKE_RESTART_HOOK='echo adopted >> "$HOME/.config/lyte-host/paired_clients"'
then
    fail "the handshake leg missed a changed pre-XDG identity copy"
fi
grep -Fq 'restart changed protected host state' \
    "$test_root/legacy-rewrite.stderr"

echo "benchmark safety tests PASSED"
