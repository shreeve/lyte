#!/bin/bash
# Forbidden-token scans for the host's release posture and the owner's rig:
# owner-facing recipes never drift back to SwiftPM's unoptimized debug
# artifact (debug remains correct for tests and development harnesses), the
# installed service never names a checkout path, the retired portal token
# stays gone, and the scripts that touch the rig keep their safety rules.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source Scripts/lib/assert.sh

# forbid MESSAGE PATTERN PATH...: fails when PATTERN (ERE) occurs under PATH.
# Build trees, dated history and this file are out of scope.
forbid() {
    local message="$1" pattern="$2" status=0
    shift 2
    grep -rnE --exclude-dir=.build --exclude-dir=history \
        --exclude="${0##*/}" -- "$pattern" "$@" || status=$?
    case "$status" in
        0) fail "$message" ;;
        1) ;;
        *) fail "cannot scan $*" ;;
    esac
}

forbid "owner-facing debug host path returned" \
    '\.build/debug/lyte-host' AGENTS.md README.md docs Host Scripts
forbid "installed service regained a checkout path" \
    'LYTE_HOST_BIN|\.build/(debug|release)/lyte-host|/home/CHANGE_ME' \
    Host/Systemd Host/Scripts/install-host.sh
forbid "the retired portal token returned" \
    'portal_token' Host/Sources Host/Scripts Host/Systemd Scripts

# Owner-rig safety: app publication never deletes the destination bundle in
# place (it swaps a staged one in), benchmarks never freeze, force-kill or
# guess at a process they did not start, netem never impairs a whole
# interface, and the pup gate deletes only through its mount-safe find.
forbid "make-app deletes the app bundle in place" \
    'rm -rf "\$APP"' Scripts/make-app.sh
forbid "a benchmark signals a process it does not own" \
    'kill -(STOP|CONT)|kill -9.*standing' \
    Scripts/benchmark-app.sh Scripts/benchmark-netem.sh Scripts/lib Scripts/netem
forbid "a benchmark guesses the app process" \
    'FALLBACK_APP_PID|pgrep -n' \
    Scripts/benchmark-app.sh Scripts/benchmark-netem.sh Scripts/lib
forbid "netem impairs a whole interface" \
    'qdisc (add|replace).* root netem' \
    Scripts/benchmark-netem.sh Scripts/netem
forbid "the pup gate deletes its mirror with rm -rf" \
    'rm -rf.*gate_root' Scripts/CI/test-all-pup.sh

echo "host release posture tests PASSED"
