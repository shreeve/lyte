#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
next_version="$repo_root/Scripts/next-bundle-version.sh"
launch_app="$repo_root/Scripts/launch-app.sh"
make_app="$repo_root/Scripts/make-app.sh"
app_artifact="$repo_root/Scripts/AppArtifact/app-artifact.sh"
test_root="$(mktemp -d)"
test_root="$(cd "$test_root" && pwd -P)"
lock_holder=""
bad_app_root=""
cleanup() {
    [[ -z "$lock_holder" ]] || kill "$lock_holder" 2>/dev/null || true
    [[ -z "$bad_app_root" ]] || rm -rf -- "$bad_app_root"
    rm -rf -- "$test_root"
}
trap cleanup EXIT

[[ "$(LYTE_BUILD_EPOCH=1000 "$next_version" 999 20)" == 1000 ]]
[[ "$(LYTE_BUILD_EPOCH=1000 "$next_version" 1000 20)" == 1001 ]]
[[ "$(LYTE_BUILD_EPOCH=1000 "$next_version" 1001 20)" == 1002 ]]
[[ "$(LYTE_BUILD_EPOCH=1000 "$next_version" 999 2000)" == 2000 ]]

if LYTE_BUILD_EPOCH=invalid "$next_version" 0 0 >/dev/null 2>&1; then
    echo "bundle version accepted a non-numeric clock" >&2
    exit 1
fi
if LYTE_BUILD_EPOCH=1000 "$next_version" previous 0 >/dev/null 2>&1; then
    echo "bundle version accepted a non-numeric predecessor" >&2
    exit 1
fi

fake_pgrep="$test_root/fake-pgrep"
cat > "$fake_pgrep" <<'EOF'
#!/bin/sh
name="$2"
case "${LYTE_FAKE_PGREP_RESULT:-empty}" in
  empty) exit 1 ;;
  error) exit 2 ;;
  app) [ "$name" != Lyte ] || { echo 4242; exit 0; }; exit 1 ;;
  helper) [ "$name" != lyte-helperd ] || { echo 4343; exit 0; }; exit 1 ;;
  after-open)
    [ "$name" = Lyte ] && [ -e "$LYTE_FAKE_OPEN_STATE" ] \
      && { echo 4242; exit 0; }
    exit 1
    ;;
esac
exit 2
EOF
chmod +x "$fake_pgrep"

ROOT="$repo_root"
source "$app_artifact"

if LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=empty \
    lyte_app_processes >/dev/null
then
    echo "empty process table reported a Lyte process" >&2
    exit 1
else
    [[ "$?" -eq 1 ]]
fi
[[ "$(LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=app \
    lyte_app_processes)" == $'Lyte\t4242' ]]
[[ "$(LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=helper \
    lyte_app_processes)" == $'lyte-helperd\t4343' ]]
if LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=error \
    lyte_app_processes >/dev/null
then
    echo "process inspection error reported quiescence" >&2
    exit 1
else
    [[ "$?" -eq 2 ]]
fi

# App publication refuses app matches, helper matches, and unreadable process
# state before invoking the compiler.
mkdir -p "$test_root/bin"
fake_swift_log="$test_root/swift.log"
cat > "$test_root/bin/swift" <<'EOF'
#!/bin/sh
echo reached >> "$LYTE_FAKE_SWIFT_LOG"
exit 73
EOF
chmod +x "$test_root/bin/swift"
for result in app helper error; do
    if PATH="$test_root/bin:$PATH" \
        LYTE_APP_LOCK_FILE="$test_root/make-$result.lock" \
        LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT="$result" \
        LYTE_FAKE_SWIFT_LOG="$fake_swift_log" \
        "$make_app" >"$test_root/make-$result.stdout" \
        2>"$test_root/make-$result.stderr"
    then
        echo "make-app accepted process state: $result" >&2
        exit 1
    fi
    [[ ! -e "$fake_swift_log" ]]
done
grep -Fq 'Lyte PID 4242' "$test_root/make-app.stderr"
grep -Fq 'lyte-helperd PID 4343' "$test_root/make-helper.stderr"
grep -Fq 'cannot inspect Lyte process state' "$test_root/make-error.stderr"

# The artifact lock serializes version allocation, publication, registration,
# and launch. A second owner must fail rather than wait behind stale inputs.
shared_lock="$test_root/shared.lock"
lock_ready="$test_root/lock-ready"
(
    exec 8>"$shared_lock"
    lockf -s -t 0 8
    touch "$lock_ready"
    sleep 2
) &
lock_holder=$!
for _ in {1..20}; do
    [[ ! -e "$lock_ready" ]] || break
    sleep 0.05
done
[[ -e "$lock_ready" ]]
if (LYTE_APP_LOCK_FILE="$shared_lock"; lyte_acquire_app_artifact_lock) \
    2>"$test_root/lock.stderr"
then
    echo "artifact lock admitted a concurrent owner" >&2
    exit 1
fi
grep -Fq 'another Lyte app assembly or launch is in progress' \
    "$test_root/lock.stderr"
wait "$lock_holder"
lock_holder=""

bad_app_root="$(mktemp -d \
    "$repo_root/.build/.lyte-test-bad-version.XXXXXX")"
bad_app="$bad_app_root/Lyte.app"
mkdir -p "$bad_app/Contents"
cat > "$bad_app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>
EOF
if PATH="$test_root/bin:$PATH" \
    LYTE_APP_DESTINATION="$bad_app" \
    LYTE_APP_LOCK_FILE="$test_root/bad-version.lock" \
    LYTE_FAKE_SWIFT_LOG="$fake_swift_log" \
    "$make_app" >"$test_root/bad-version.stdout" \
    2>"$test_root/bad-version.stderr"
then
    echo "make-app accepted an unreadable prior bundle version" >&2
    exit 1
fi
[[ ! -e "$fake_swift_log" ]]
grep -Fq 'has no readable CFBundleVersion' \
    "$test_root/bad-version.stderr"

# An isolated build may never hide inside the live bundle and thereby bypass
# live-process policy. The rejection happens before the compiler or mutation.
if PATH="$test_root/bin:$PATH" \
    LYTE_APP_DESTINATION="$repo_root/.build/Lyte.app/Nested.app" \
    LYTE_APP_LOCK_FILE="$test_root/nested.lock" \
    LYTE_FAKE_SWIFT_LOG="$fake_swift_log" \
    "$make_app" >"$test_root/nested.stdout" \
    2>"$test_root/nested.stderr"
then
    echo "make-app accepted a destination inside the live bundle" >&2
    exit 1
fi
[[ ! -e "$fake_swift_log" ]]
grep -Fq 'isolated app destination cannot be inside' \
    "$test_root/nested.stderr"
[[ ! -e "$repo_root/.build/Lyte.app/Nested.app" ]]

# A fake launch proves verify -> identity read -> register -> open -> exact-path
# process observation while the shared lock remains held.
fake_app="$test_root/Lyte.app"
mkdir -p "$fake_app/Contents/MacOS"
touch "$fake_app/Contents/MacOS/Lyte"
chmod +x "$fake_app/Contents/MacOS/Lyte"
launch_log="$test_root/launch.log"
open_state="$test_root/opened"
cat > "$test_root/bin/codesign" <<'EOF'
#!/bin/sh
echo codesign >> "$LYTE_FAKE_LAUNCH_LOG"
if [ "$1" = -d ]; then
    echo 'Identifier=dev.shreeve.lyte' >&2
fi
EOF
cat > "$test_root/bin/lsregister" <<'EOF'
#!/bin/sh
exec 8>"$LYTE_APP_LOCK_FILE"
if lockf -s -t 0 8; then exit 72; fi
echo register >> "$LYTE_FAKE_LAUNCH_LOG"
EOF
cat > "$test_root/bin/open" <<'EOF'
#!/bin/sh
exec 8>"$LYTE_APP_LOCK_FILE"
if lockf -s -t 0 8; then exit 72; fi
echo open >> "$LYTE_FAKE_LAUNCH_LOG"
touch "$LYTE_FAKE_OPEN_STATE"
EOF
cat > "$test_root/bin/ps" <<'EOF'
#!/bin/sh
exec 8>"$LYTE_APP_LOCK_FILE"
if lockf -s -t 0 8; then exit 72; fi
echo observe >> "$LYTE_FAKE_LAUNCH_LOG"
echo "$LYTE_FAKE_APP_EXECUTABLE"
EOF
chmod +x "$test_root/bin/codesign" "$test_root/bin/lsregister" \
    "$test_root/bin/open" "$test_root/bin/ps"
LYTE_APP_LOCK_FILE="$test_root/launch.lock" \
LYTE_PGREP="$fake_pgrep" LYTE_FAKE_PGREP_RESULT=after-open \
LYTE_FAKE_OPEN_STATE="$open_state" \
LYTE_FAKE_LAUNCH_LOG="$launch_log" \
LYTE_FAKE_APP_EXECUTABLE="$fake_app/Contents/MacOS/Lyte" \
LYTE_CODESIGN="$test_root/bin/codesign" \
LYTE_LSREGISTER="$test_root/bin/lsregister" \
LYTE_OPEN="$test_root/bin/open" LYTE_PS="$test_root/bin/ps" \
    "$launch_app" "$fake_app" >/dev/null
[[ "$(tr '\n' ' ' < "$launch_log")" \
    == 'codesign codesign register open observe ' ]]

grep -Fq 'Scripts/next-bundle-version.sh' "$make_app"
[[ "$(grep -Fc 'lyte_require_app_quiescent "live app publication"' \
    "$make_app")" -eq 2 ]]
first_build_line="$(grep -n '^swift build' "$make_app" \
    | head -n 1 | cut -d: -f1)"
first_guard_line="$(grep -n 'lyte_require_app_quiescent' "$make_app" \
    | head -n 1 | cut -d: -f1)"
last_guard_line="$(grep -n 'lyte_require_app_quiescent' "$make_app" \
    | tail -n 1 | cut -d: -f1)"
assembly_check_line="$(grep -n 'test-hermetic-linkage.sh' "$make_app" \
    | tail -n 1 | cut -d: -f1)"
[[ "$first_guard_line" -lt "$first_build_line" ]]
[[ "$last_guard_line" -gt "$assembly_check_line" ]]
grep -Fq 'LYTE_APP_DESTINATION="$ci_app"' \
    "$repo_root/Scripts/CI/test-all-macos.sh"
grep -Fq 'LaunchServices.framework/Support/lsregister' "$launch_app"
grep -Fq '"$LSREGISTER" -f "$APP"' "$launch_app"
grep -Fq '"${LYTE_OPEN:-open}" -F "$APP"' "$launch_app"
grep -Fq 'lyte_wait_for_exact_app "$APP_EXECUTABLE"' "$launch_app"

if grep -Fq 'tccutil' "$launch_app"; then
    echo "launcher attempts an unsupported Local Network privacy reset" >&2
    exit 1
fi

sh -n "$next_version" "$launch_app" "$make_app" "$app_artifact"
echo "app identity tests PASSED"
