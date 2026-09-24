#!/bin/bash
# Forbidden-token scans for the host's release posture: owner-facing recipes
# never drift back to SwiftPM's unoptimized debug artifact (debug remains
# correct for tests and development harnesses), the installed service never
# names a checkout path, and the retired portal token stays gone.
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

echo "host release posture tests PASSED"
