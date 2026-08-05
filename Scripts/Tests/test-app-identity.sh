#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
next_version="$repo_root/Scripts/next-bundle-version.sh"
launch_app="$repo_root/Scripts/launch-app.sh"
make_app="$repo_root/Scripts/make-app.sh"

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

grep -Fq 'Scripts/next-bundle-version.sh' "$make_app"
grep -Fq 'pgrep -x Lyte' "$make_app"
first_guard_line="$(grep -n 'RUNNING_PIDS=.*pgrep -x Lyte' "$make_app" \
    | head -n 1 | cut -d: -f1)"
first_build_line="$(grep -n '^swift build' "$make_app" \
    | head -n 1 | cut -d: -f1)"
[[ "$first_guard_line" -lt "$first_build_line" ]]
grep -Fq 'LaunchServices.framework/Support/lsregister' "$launch_app"
grep -Fq '"$LSREGISTER" -f "$APP"' "$launch_app"
grep -Fq 'open -F "$APP"' "$launch_app"
grep -Fq 'pgrep -x Lyte' "$launch_app"

if grep -Fq 'tccutil' "$launch_app"; then
    echo "launcher attempts an unsupported Local Network privacy reset" >&2
    exit 1
fi

sh -n "$next_version" "$launch_app" "$make_app"
echo "app identity tests PASSED"
